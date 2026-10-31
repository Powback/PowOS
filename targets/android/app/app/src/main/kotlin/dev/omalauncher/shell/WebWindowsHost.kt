package dev.omalauncher.shell

import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper

/**
 * The web windows' display maker (docs/WEB_WINDOWS.md S1), run as the shell user with app_process from this APK
 * ([WebWindows] starts it: `su 2000 -c "CLASSPATH=<apk> app_process /system/bin dev.omalauncher.shell.WebWindowsHost"`),
 * talking line by line over its stdin/stdout:
 *
 *   create <tag> <w> <h> <dpi> [selftest]   -> "display <tag> <displayId>" | "error <tag> <why>"
 *                                   selftest (tools/phone/verify/window-render.sh --hidden, run from adb, never by the
 *                                   app): also its own display group, focus and lock state ([SELFTEST_FLAGS]), so the
 *                                   check's display stays on with the screen off or locked and never takes the
 *                                   user's focus; refused -> the window flags
 *   resize <displayId> <w> <h> <dpi>      (no display frame FrozenWatch.FROZEN_MS after it -> "quiet <id> <ms> <rebinds>")
 *   rebind <displayId>                    -> the display's surface off and on (its frozen app draws again)
 *   release <displayId>
 *   touch <displayId> <action> <downTime> <id>,<x>,<y> ...   -> an injected touch on that display, every finger down
 *                                                            now ("log touch ..." for downs/ups); also <x> <y> (one)
 *   (stdin closed: the app is gone - every display released, then exit)
 *
 * Why it exists: a window's display must be TRUSTED, else the app's own launches leave it. Measured 2026-10-30
 * (spikes/webwindows-s1/P1.java, isActivityStartAllowedOnDisplay = ActivityStarter's canPlaceEntityOnDisplay): on an
 * untrusted VD that PowOS owns, PowOS may start any activity there, but Chrome's uid may not start its own
 * (ChromeLauncherActivity's trampoline to ChromeTabbedActivity), so WM moves that launch to display 0 - the user's
 * screen. On a TRUSTED VD Chrome may. TRUSTED needs ADD_TRUSTED_DISPLAY: signature|role on the phone, PowOS (uid
 * 10359) is refused ("Requires ADD_TRUSTED_DISPLAY permission to create a trusted virtual display"), the shell user
 * holds it. Only TRUSTED is added (no OWN_DISPLAY_GROUP: the window's display follows the phone's screen off/on, as
 * any app does).
 *
 * Each display's output is a 1x1 ImageReader read and dropped here: the display stays ON (a null surface turns it OFF
 * and the app STOPS within ~40 ms, S0), the app draws at its full rate, and SurfaceFlinger's composition into it is 1
 * pixel. What the user sees is not this output but the display's mirror under home ([WebWindows]).
 *
 * The dpi PowOS sends is the window's ([WindowDpi], fixed for its life) and the display is made and resized AT it: on
 * the unfolded screen the desktop density (2/3 of the screen's), so a window of desktop size is >= 600 dp and its app
 * takes its large-screen layout (Chrome's tab strip, 10-31 "Why isn't Chrome in desktop mode anymore?"); folded, the
 * screen's. 83fcef17 had made every window the screen's density (Chrome at 1135 px = 411 dp: the phone toolbar)
 * because the sw600 rule of 5e74d81c recomputed the density on every resize and Discord, which keeps its start
 * density, drew mixed and cut: now the density never changes while the app is in its window, and Discord keeps the
 * screen's ([WindowDpi.SCREEN_DENSITY_APPS]).
 *
 * HACK: a root-spawned shell-uid helper because an app can't hold ADD_TRUSTED_DISPLAY. Real fix: the displays made
 * from the platform-signed side (PowOS's system module) or a role that grants it; the S4 input injector will be the
 * same kind of process, and then both live in one helper.
 */
object WebWindowsHost {
    private val FLAGS =
        DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC or DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY or
            (1 shl 6) or // SUPPORTS_TOUCH: touch = TOUCH_VIRTUAL, so input has a viewport for it ([Touch])
            (1 shl 8) or // DESTROY_CONTENT_ON_REMOVAL: the window's activities finish with it
            (1 shl 10) // TRUSTED

    /**
     * The device window check's display (`create ... selftest`): OWN_DISPLAY_GROUP (1 shl 11: its own power state, awake
     * while the phone's screen is off), ALWAYS_UNLOCKED (1 shl 12: no keyguard on it), OWN_FOCUS (1 shl 14: launching
     * Calculator there doesn't move the user's focus off their screen).
     */
    private val SELFTEST_FLAGS = FLAGS or (1 shl 11) or (1 shl 12) or (1 shl 14)

    private const val SHELL_UID = 2000


    private class Vd(val display: VirtualDisplay, var reader: ImageReader, val touch: Touch?) {
        /** The frozen-app watch ([FrozenWatch]), on the frames thread only. */
        val freeze = FrozenWatch()

        /** RS1's settle watch ([Host.settle]): its start, its last display frame (uptime ms), what to log with it. */
        var settleFrom = 0L
        var lastFrame = 0L
        var counts: String? = null
    }

    /** A display that composed nothing new for this long after a resize has settled (its app drew at the size). */
    private const val SETTLE_QUIET_MS = 150L
    private const val SETTLE_MAX_MS = 3000L

    /** A rebind's display stays off this long: the app sees it stop (S0: ~40 ms), then start. */
    private const val REBIND_OFF_MS = 120L

    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        val frames = HandlerThread("ww-frames").apply { start() }
        val dm = DisplayManager::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(shellContext())
        val host = Host(dm, Handler(frames.looper))
        say("hello")
        val input = System.`in`.bufferedReader()
        while (true) {
            val line = input.readLine() ?: break
            try {
                host.command(line.trim().split(' '))
            } catch (e: RuntimeException) {
                say("log $line: $e")
            }
        }
        host.releaseAll()
        System.exit(0)
    }

    private fun say(line: String) =
        synchronized(System.out) {
            System.out.println(line)
            System.out.flush()
        }

    private class Host(
        private val dm: DisplayManager,
        private val frames: Handler,
    ) {
        private val vds = HashMap<Int, Vd>()
        fun command(a: List<String>) {
            when (a[0]) {
                "create" -> create(a)
                "resize" -> resize(a[1].toInt(), a[2].toInt(), a[3].toInt(), a[4].toInt())
                "rebind" -> rebind(a[1].toInt())
                "release" -> vds.remove(a[1].toInt())?.let(::release)
                "settle" -> settle(a[1].toInt(), a.drop(2).joinToString(" "))
                "touch" -> Inject.touch(a)
            }
        }

        /** `create <tag> <w> <h> <dpi> [selftest]` (the command's words). */
        private fun create(a: List<String>) {
            val tag = a[1]
            val w = a[2].toInt()
            val h = a[3].toInt()
            val dpi = a[4].toInt()
            val selftest = a.getOrNull(5) == "selftest"
            val r = ImageReader.newInstance(1, 1, PixelFormat.RGBA_8888, 2)
            var made: Vd? = null
            r.setOnImageAvailableListener({ made?.let(::framed) ?: it.acquireLatestImage()?.close() }, frames)
            val vd =
                try {
                    val own =
                        if (!selftest) null
                        else runCatching { dm.createVirtualDisplay("powos-ww-$tag", w, h, dpi, r.surface, SELFTEST_FLAGS) }
                            .onFailure { say("log display $tag: selftest flags refused (${it.toString().replace('\n', ' ')}): window flags") }
                            .getOrNull()
                    own ?: dm.createVirtualDisplay("powos-ww-$tag", w, h, dpi, r.surface, FLAGS)
                } catch (e: RuntimeException) {
                    null.also { say("error $tag ${e.toString().replace('\n', ' ')}") }
                }
            if (vd == null) {
                r.close()
                return
            }
            val touch = Touch.attach(vd.display)
            made = Vd(vd, r, touch)
            vds[vd.display.displayId] = made
            say("display $tag ${vd.display.displayId}")
            say("log display ${vd.display.displayId} ${w}x$h dpi $dpi: sw ${minOf(w, h) * 160 / dpi}dp")
        }

        private fun resize(
            id: Int,
            w: Int,
            h: Int,
            dpi: Int,
        ) {
            val v = vds[id] ?: return
            v.display.resize(w, h, dpi)
            frames.post { v.freeze.resized(android.os.SystemClock.uptimeMillis()) }
            frames.postDelayed({ freezeCheck(id, v) }, FrozenWatch.FROZEN_MS + 50)
        }

        /** On [frames]: [v]'s display composed a frame. */
        private fun framed(v: Vd) {
            v.reader.acquireLatestImage()?.close()
            val now = android.os.SystemClock.uptimeMillis()
            v.lastFrame = now
            v.freeze.frame(now)
        }

        /** On [frames]: no frame since [v]'s last resize/rebind for [FrozenWatch.FROZEN_MS] -> "quiet <id> <ms> <rebinds>". */
        private fun freezeCheck(
            id: Int,
            v: Vd,
        ) {
            if (vds[id] !== v) return
            val quiet = v.freeze.step(android.os.SystemClock.uptimeMillis())
            if (quiet > 0) say("quiet $id $quiet ${v.freeze.rebinds}")
        }

        /**
         * `rebind <displayId>`: the display's output surface off and on (a new reader): the display turns OFF (its app
         * stops, S0) and ON again (it starts and draws a frame at the display's size) - a frozen app unstuck in place.
         */
        private fun rebind(id: Int) {
            val v = vds[id] ?: return
            v.display.surface = null
            frames.postDelayed({
                if (vds[id] !== v) return@postDelayed
                val r = ImageReader.newInstance(1, 1, PixelFormat.RGBA_8888, 2)
                r.setOnImageAvailableListener({ framed(v) }, frames)
                val old = v.reader
                v.reader = r
                v.display.surface = r.surface
                old.close()
                v.freeze.rebound(android.os.SystemClock.uptimeMillis())
                frames.postDelayed({ freezeCheck(id, v) }, FrozenWatch.FROZEN_MS + 50)
                say("log display $id: surface re-bound (rebind ${v.freeze.rebinds})")
            }, REBIND_OFF_MS)
        }

        /**
         * RS1: display [id] was given its final size (just before this, in order): its frames watched until it's quiet
         * for [SETTLE_QUIET_MS] - "log <counts>, settled X ms after release (its last frame)".
         */
        fun settle(
            id: Int,
            counts: String,
        ) {
            val v = vds[id] ?: return
            v.settleFrom = android.os.SystemClock.uptimeMillis()
            v.lastFrame = 0L
            v.counts = counts
            frames.postDelayed({ settleCheck(id, v) }, SETTLE_QUIET_MS)
        }

        private fun settleCheck(
            id: Int,
            v: Vd,
        ) {
            val counts = v.counts ?: return
            val now = android.os.SystemClock.uptimeMillis()
            val last = maxOf(v.lastFrame, v.settleFrom)
            if (now - last < SETTLE_QUIET_MS && now - v.settleFrom < SETTLE_MAX_MS) {
                frames.postDelayed({ settleCheck(id, v) }, SETTLE_QUIET_MS - (now - last))
                return
            }
            v.counts = null
            val info = v.display.display
            val settled = if (v.lastFrame > 0) "${v.lastFrame - v.settleFrom} ms" else "no frame"
            say("log $counts, settled $settled after release (display $id ${info.mode.physicalWidth}x${info.mode.physicalHeight})")
        }

        private fun release(v: Vd) {
            v.touch?.detach()
            v.display.release()
            v.reader.close()
        }

        fun releaseAll() = vds.values.forEach { runCatching { release(it) } }
    }

    /**
     * A window's display reports a touchscreen (Configuration.touchscreen FINGER, as the phone's screen), not NOTOUCH.
     * WM sets a display's touchscreen from the input devices that can dispatch to it (DisplayContent
     * computeScreenConfiguration: a non-virtual TOUCHSCREEN device whose associated display is this one); the phone's
     * panels are associated with its own screens, so a bare VD said "-touch" and apps chose their non-touch (TV /
     * desktop-like) layouts - YouTube's feed rows split, small thumbnails, gaps, no top bar (10-30: "The YouTube app
     * also looks fucked"). So each display gets its own idle touchscreen: a uinput device (the platform's
     * /system/bin/uinput; the helper runs with group uhid for it) whose port is associated with the display's unique id
     * (IInputManager.addUniqueIdAssociationByPort: ASSOCIATE_INPUT_DEVICE_TO_DISPLAY, held by shell), the display made
     * with SUPPORTS_TOUCH so input has a VIRTUAL viewport for it. The device never sends an event: the app's input
     * still comes from PowOS's injector. Measured 2026-10-30 (spikes/webwindows-touch/T1.java, a 1298x1761 442 dpi
     * trusted VD): bare "-touch"; with SUPPORTS_TOUCH alone "-touch"; with SUPPORTS_TOUCH + this device "finger".
     *
     * HACK: a placeholder input device per window only to make the display count as touch. Real fix: the display made
     * from the platform side with its DisplayDeviceInfo touch honoured by WM (or the injector itself becoming this
     * uinput touchscreen, S4), so the device that says "touch" is the one that delivers it.
     */
    private class Touch(
        private val proc: Process,
        private val port: String,
    ) {
        fun detach() {
            runCatching { associate("removeUniqueIdAssociationByPort", "removeUniqueIdAssociation", port) }
            runCatching { proc.outputStream.close() }
            proc.destroy()
        }

        companion object {
            private const val WAIT_MS = 1500L

            fun attach(d: android.view.Display): Touch? {
                val port = "powos-ww-${d.displayId}"
                val unique =
                    runCatching { android.view.Display::class.java.getMethod("getUniqueId").invoke(d) as String? }.getOrNull()
                if (unique.isNullOrEmpty()) return null.also { say("log display ${d.displayId}: no unique id, no touch") }
                val name = "PowOS window touch ${d.displayId}"
                // The association first (so the device is never the phone screen's, even for a moment), then the
                // device, then a wait for it: WM recomputes the display's configuration when input devices change,
                // before the app starts on it.
                val ok = runCatching { associate("addUniqueIdAssociationByPort", "addUniqueIdAssociation", port, unique) }
                if (ok.isFailure) say("log display ${d.displayId}: touch association failed: ${ok.exceptionOrNull()}")
                val p = register(d.displayId, name, port) ?: return null
                val seen = waitFor(name)
                say("log display ${d.displayId}: touch device ${if (seen) "up" else "NOT seen in $WAIT_MS ms"} (port $port -> $unique)")
                return Touch(p, port)
            }

            /** /system/bin/uinput registering an idle multi-touch screen [name] on [port] (alive while its stdin is). */
            private fun register(
                id: Int,
                name: String,
                port: String,
            ): Process? {
                val json =
                    """{"id":1,"command":"register","name":"$name","vid":6353,"pid":${0x7700 + (id and 0xff)},"bus":"virtual","port":"$port",""" +
                        """"configuration":[{"type":100,"data":[1,3]},{"type":101,"data":[330]},{"type":103,"data":[47,53,54,57]},{"type":110,"data":[1]}],""" +
                        """"abs_info":[${abs(47, 9)},${abs(53, 4095)},${abs(54, 4095)},${abs(57, 65535)}]}"""
                return try {
                    val p = ProcessBuilder("/system/bin/uinput", "-").redirectErrorStream(true).start()
                    // Drain its output (a full pipe would block it).
                    Thread({ runCatching { p.inputStream.copyTo(java.io.OutputStream.nullOutputStream()) } }, "ww-uinput").apply { isDaemon = true }.start()
                    p.outputStream.write((json + "\n").toByteArray())
                    p.outputStream.flush()
                    p
                } catch (e: java.io.IOException) {
                    null.also { say("log display $id: uinput touch not registered: $e") }
                }
            }

            private fun abs(
                code: Int,
                max: Int,
            ) = """{"code":$code,"info":{"value":0,"minimum":0,"maximum":$max,"fuzz":0,"flat":0,"resolution":0}}"""

            /** True once input lists a device named [name] (at most [WAIT_MS]). */
            private fun waitFor(name: String): Boolean {
                val g = runCatching { Class.forName("android.hardware.input.InputManagerGlobal").getMethod("getInstance").invoke(null) }.getOrNull() ?: return false
                val ids = g.javaClass.getMethod("getInputDeviceIds")
                val dev = g.javaClass.getMethod("getInputDevice", Int::class.javaPrimitiveType)
                val until = android.os.SystemClock.uptimeMillis() + WAIT_MS
                while (android.os.SystemClock.uptimeMillis() < until) {
                    val found = runCatching { (ids.invoke(g) as IntArray).any { (dev.invoke(g, it) as android.view.InputDevice?)?.name == name } }.getOrDefault(false)
                    if (found) return true
                    Thread.sleep(20)
                }
                return false
            }

            /** IInputManager's [name] (Android 15+), else [old] (14), with [args]. */
            private fun associate(
                name: String,
                old: String,
                vararg args: String,
            ) {
                val b = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, "input") as android.os.IBinder
                val svc = Class.forName("android.hardware.input.IInputManager\$Stub").getMethod("asInterface", android.os.IBinder::class.java).invoke(null, b)!!
                val types = Array(args.size) { String::class.java }
                val m = runCatching { svc.javaClass.getMethod(name, *types) }.getOrElse { svc.javaClass.getMethod(old, *types) }
                m.invoke(svc, *args)
            }
        }
    }

    /**
     * The web windows' Android input: a body touch the page forwarded, injected on the window's display from this
     * long-lived shell-uid process (shell holds INJECT_EVENTS; PowOS's uid doesn't, so its own injectInputEvent is
     * refused). Before this, every event was a root `input -d <id> touchscreen motionevent ...` - a new app_process
     * per touch (logcat's "app_process: Opened libinputextensionsimpl.so" on every tap, 10-31 01:11), ~0.3-1 s each, a
     * DOWN and its UP raced as separate processes, and taps on window bodies did nothing (the user, 10-31 01:11:
     * "I can't interact with Android windows").
     */
    private object Inject {
        private val im by lazy {
            val b = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, "input") as android.os.IBinder
            Class.forName("android.hardware.input.IInputManager\$Stub").getMethod("asInterface", android.os.IBinder::class.java).invoke(null, b)!!
        }
        private val inject by lazy { im.javaClass.getMethod("injectInputEvent", android.view.InputEvent::class.java, Int::class.javaPrimitiveType) }
        private val setDisplayId by lazy { android.view.MotionEvent::class.java.getMethod("setDisplayId", Int::class.javaPrimitiveType) }
        /**
         * "touch <displayId> <action> <downTime> <id>,<x>,<y> ..." (device px on that display): PZ1, every finger on the
         * body (by id; [action] carries the pointer index of a POINTER_DOWN/UP), so a pinch is one multi-touch gesture.
         * The older "... <x> <y>" is finger 0 alone.
         */
        fun touch(a: List<String>) {
            val displayId = a[1].toInt()
            val action = a[2].toInt()
            val downTime = a[3].toLong()
            val fingers = if (a.size == 6 && ',' !in a[4]) listOf("0,${a[4]},${a[5]}") else a.drop(4)
            val props = Array(fingers.size) { android.view.MotionEvent.PointerProperties() }
            val coords = Array(fingers.size) { android.view.MotionEvent.PointerCoords() }
            fingers.forEachIndexed { i, f ->
                val (id, fx, fy) = f.split(',')
                props[i].id = id.toInt()
                props[i].toolType = android.view.MotionEvent.TOOL_TYPE_FINGER
                coords[i].x = fx.toFloat()
                coords[i].y = fy.toFloat()
                coords[i].pressure = 1f
                coords[i].size = 1f
            }
            val (x, y) = coords[0].x to coords[0].y
            val now = android.os.SystemClock.uptimeMillis()
            val ev =
                android.view.MotionEvent.obtain(
                    downTime, now, action, fingers.size, props, coords, 0, 0, 1f, 1f, VIRTUAL_DEVICE, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0,
                )
            val result =
                try {
                    setDisplayId.invoke(ev, displayId)
                    // INJECT_INPUT_EVENT_MODE_ASYNC: never blocks the next line on the app's handling.
                    if (inject.invoke(im, ev, 0) as? Boolean == true) "ok" else "REFUSED"
                } catch (e: Exception) {
                    "FAILED ${(e.cause ?: e)}"
                } finally {
                    ev.recycle()
                }
            if (action != android.view.MotionEvent.ACTION_MOVE || result != "ok") {
                say("log touch display $displayId action $action fingers ${fingers.size} at ${x.toInt()},${y.toInt()}: $result")
            }
        }

        /** KeyCharacterMap.VIRTUAL_KEYBOARD: the id the platform's own `input` command injects as. */
        private const val VIRTUAL_DEVICE = -1
    }

    /** The system context under the shell package's name (the uid this runs as), as scrcpy's server does. */
    private fun shellContext(): Context {
        val at = Class.forName("android.app.ActivityThread")
        val thread = at.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        at.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, thread)
        at.getDeclaredField("mSystemThread").apply { isAccessible = true }.setBoolean(thread, true)
        val system = at.getMethod("getSystemContext").invoke(thread) as Context
        return object : ContextWrapper(system) {
            override fun getPackageName() = "com.android.shell"

            override fun getOpPackageName() = "com.android.shell"

            override fun getAttributionSource(): AttributionSource = AttributionSource.Builder(SHELL_UID).setPackageName("com.android.shell").build()

            override fun getApplicationContext(): Context = this
        }
    }
}
