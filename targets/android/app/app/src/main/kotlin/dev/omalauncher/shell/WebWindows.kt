package dev.omalauncher.shell

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.InputDevice
import android.view.InputEvent
import android.view.MotionEvent
import android.view.SurfaceControl
import android.webkit.WebView
import dev.omalauncher.system.HiddenApi
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter

/**
 * Web windows: an Android app's window as an element of PowOS home (unfolded, `Settings.Global powos_web_windows` = 1;
 * off by default). docs/WEB_WINDOWS.md, steps S1-S3.
 *
 * Why - the user, 2026-10-29: "its because we arent doing it natively inside powos. like the powos home typescript
 * should deal with the windows and their content", "it should be pinned to a page properly natively", "idk why you do
 * this overlay shit". So the window is home's: its position, size, page, z-order and title bar are DOM and state in the
 * page (shell/ui/webwindows.tsx); only its content is the app's.
 *
 * How:
 * - One TRUSTED VirtualDisplay per window, made by [WebWindowsHost] (a shell-uid helper: an app may not create a
 *   trusted display, and on an untrusted one the app's own launches escape to the user's screen - see there). Its
 *   output is a 1x1 ImageReader in the helper: the display stays on, the app runs at its full rate.
 * - The content is the display's MIRROR (IWindowManager.mirrorDisplay, READ_FRAME_BUFFER - the recents role): a layer
 *   tree showing the app's own buffers, so SurfaceFlinger composites the app at the element in the same frame the app
 *   commits (S0: the copy path is a frame later and applies night light twice).
 * - Surfaces: one container layer per window (powos-ww-<id>) under one "powos-webwindows" layer that is a child of
 *   home's own window surface (AttachedSurfaceControl.buildReparentTransaction) BELOW home's buffer (layer -1, as a
 *   SurfaceView): whatever the page paints over a window's body (the drawer, a panel, another window's title bar)
 *   covers it; the body itself is an unpainted hole. The container is cropped to the window's frame with its corner
 *   radius; the mirror sits in it at the body's offset, cropped to the body. Z-order = DOM order (setLayer); every
 *   window is under home's own pixels and so under every PowOS system UI window.
 * - Geometry: the page sends "w.f <frame> ..." over its native port every frame a window's rect, visibility or order
 *   changed; it goes on the draw that shows that page frame ([FrameSync], the glass's binding), so the content and
 *   the DOM chrome move in the same composited frame. A window off its page or out of sight: its layer hidden, never
 *   its display's surface (that would STOP the app within ~40 ms, S0). A new body size resizes the display
 *   (VirtualDisplay.resize in the helper): the app lays out at its real pixel size.
 * - Mirrored and launched only once WM knows the display (mirrorDisplay says false for its first ~100 ms).
 * - Closed: the display's tasks removed (DESTROY_CONTENT_ON_REMOVAL alone leaves the task in recents), then the display.
 *
 * Input (v0, until S4): the page forwards touches on the body ("webwindows.input"); they are injected on the window's
 * display - InputManager.injectInputEvent through reflection with MotionEvent.setDisplayId, else root
 * `input -d <id> motionevent`. Keyboard: the display's IME policy is the default display's.
 *
 * HACK: the root `input` fallback spawns a process per event (moves coalesced): taps work, drags are coarse. Real fix:
 * S4's injector (a persistent shell-uid helper holding INJECT_EVENTS - [WebWindowsHost] grows it).
 * HACK: IWindowManager.mirrorDisplay, the SurfaceControl() out-constructor, Transaction.setCornerRadius and the task
 * calls are hidden, reflected ([HiddenApi]). Real fix: none public for an app (a platform-signed system module).
 * Not yet: the app finishing its task on the display does not emit "webwindows.closed" (only close(), the display or
 * the helper gone do) - real fix: a TaskStackListener watching the windows' display ids.
 *
 * Doesn't touch the freeform windows (system/WindowFrames.kt): with the setting off nothing here runs.
 */
class WebWindows(
    private val context: Context,
    private val web: WebView,
    private val emit: (String, Any?) -> Unit,
    /** The shown bodies changed ([bodies]): the glass's blur regions leave them out (they'd blur over the app). */
    private val bodiesChanged: () -> Unit = {},
) {
    private val main = Handler(Looper.getMainLooper())
    private val dm = context.getSystemService(DisplayManager::class.java)
    private val wins = LinkedHashMap<Int, Win>()
    private var nextId = 1
    private val io by lazy { Handler(HandlerThread("powos-webwindows").apply { start() }.looper) }
    private val sync = FrameSync(web, "ww")
    private val helper = Helper()

    /** Off unless `settings put global powos_web_windows 1`. */
    fun enabled(): Boolean = on(context)

    private val displayListener =
        object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {}

            override fun onDisplayChanged(displayId: Int) {}

            override fun onDisplayRemoved(displayId: Int) {
                wins.values.firstOrNull { it.displayId == displayId }?.let { w ->
                    Log.i(TAG, "display $displayId removed: window ${w.id} closed")
                    drop(w, released = true)
                }
            }
        }

    init {
        runCatching { dm.registerDisplayListener(displayListener, main) }
    }

    private fun density() = context.resources.displayMetrics.density

    private val dpi get() = context.resources.displayMetrics.densityDpi

    /** One window: its container layer, its display (-1 until the helper made it), its mirror (once WM knows the display). */
    private class Win(
        val id: Int,
        val component: ComponentName,
        val container: SurfaceControl,
        /** The display's size, px (what it was made or last resized to). */
        var w: Int,
        var h: Int,
    ) {
        @Volatile var displayId = -1
        var mirror: SurfaceControl? = null

        /** The last geometry the page gave it (main thread): applied again when the mirror arrives. */
        var geo: Geo? = null
        var downAt = 0L

        @Volatile var closed = false
    }

    /** A window's frame and body, in home's window surface px; z: its place in DOM order (0 = bottom). */
    private class Geo(
        val id: Int,
        val frame: Rect,
        val body: Rect,
        val radius: Float,
        val visible: Boolean,
        val z: Int,
    )

    /** The layer all windows hang under: home's window surface, under its own buffer. Made on first use (main thread). */
    private var root: SurfaceControl? = null

    private fun root(): SurfaceControl? {
        root?.takeIf { it.isValid }?.let { return it }
        val attached = web.rootSurfaceControl ?: return null.also { Log.w(TAG, "home's window has no surface yet") }
        val sc = SurfaceControl.Builder().setName("powos-webwindows").build()
        val t = attached.buildReparentTransaction(sc) ?: return null.also { sc.release(); Log.w(TAG, "home's surface refused a child") }
        // Below home's own buffer, as a SurfaceView (-1: its media overlay level; the page's surface tiles are -2).
        t.setLayer(sc, -1).setVisibility(sc, true).apply()
        root = sc
        return sc
    }

    /** A window for [component], its body at [rect] (CSS px): its id, or -1 (setting off, no surface to host it). */
    fun open(
        component: ComponentName,
        rect: JSONObject,
    ): Int {
        if (!enabled()) return -1.also { Log.w(TAG, "open ${component.packageName}: $SETTING is off") }
        val parent = root() ?: return -1
        val id = nextId++
        val d = density()
        val w = (rect.optDouble("width") * d).toInt().coerceAtLeast(1)
        val h = (rect.optDouble("height") * d).toInt().coerceAtLeast(1)
        // Hidden until the page's first "w.f" places it.
        val container = SurfaceControl.Builder().setName("powos-ww-$id").setParent(parent).setHidden(true).build()
        val win = Win(id, component, container, w, h)
        wins[id] = win
        helper.create(id, w, h) { displayId, error ->
            if (displayId < 0) {
                Log.w(TAG, "window $id (${component.packageName}): no display: $error")
                main.post { drop(win, released = true) }
                return@create
            }
            win.displayId = displayId
            // Closed while its display was being made: the display goes too.
            if (win.closed) return@create helper.release(displayId)
            Log.i(TAG, "window $id: trusted display $displayId ${w}x$h dpi $dpi (${component.packageName})")
            io.post { mirrorWhenKnown(win, SystemClock.uptimeMillis()) }
        }
        return id
    }

    /**
     * On [io]: the display mirrored as soon as WM knows it (mirrorDisplay says false before - S0: ~100 ms), then the
     * app launched onto it (not before either: a launch on a display WM doesn't have yet goes elsewhere).
     */
    private fun mirrorWhenKnown(
        win: Win,
        since: Long,
    ) {
        if (win.closed) return
        val out =
            try {
                mirror(win.displayId)
            } catch (e: Exception) {
                // S1's open question (docs/WEB_WINDOWS.md): mirrorDisplay from PowOS's own uid. Logged when refused.
                Log.w(TAG, "mirrorDisplay(${win.displayId}) refused for PowOS's uid: ${e.cause ?: e}")
                main.post { drop(win) }
                return
            }
        val waited = SystemClock.uptimeMillis() - since
        when {
            out != null -> {
                Log.i(TAG, "window ${win.id}: display ${win.displayId} mirrored after $waited ms (PowOS uid)")
                main.post { attach(win, out) }
            }
            waited > MIRROR_WAIT_MS -> {
                Log.w(TAG, "window ${win.id}: display ${win.displayId} not known to WM after $waited ms")
                main.post { drop(win) }
            }
            else -> io.postDelayed({ mirrorWhenKnown(win, since) }, 16)
        }
    }

    /** The display's mirror (a new layer tree showing its content), or null: WM doesn't know the display yet. Throws: refused. */
    private fun mirror(displayId: Int): SurfaceControl? {
        val m = mirrors ?: error("no IWindowManager.mirrorDisplay")
        val out = m.newSurfaceControl.newInstance()
        if (m.mirrorDisplay.invoke(m.wm, displayId, out) as Boolean && out.isValid) return out
        out.release()
        return null
    }

    /** On the main thread: [out] shown in [win]'s container, then the app launched onto its display. */
    private fun attach(
        win: Win,
        out: SurfaceControl,
    ) {
        if (win.closed || !win.container.isValid) {
            out.release()
            return
        }
        win.mirror = out
        val t = SurfaceControl.Transaction().reparent(out, win.container).setLayer(out, 0).setVisibility(out, true)
        // Boundless until cropped: nothing of it shows until the page's geometry says where the body is.
        t.setCrop(out, Rect(0, 0, 0, 0))
        win.geo?.let { place(t, win, it) }
        t.apply()
        imePolicy(win.displayId)
        launch(win)
    }

    // ---- geometry ------------------------------------------------------------------------------------------------------

    /**
     * "w.f <frame> <dpr> <n> [<id> <fx> <fy> <fw> <fh> <bx> <by> <bw> <bh> <radius> <visible>] * n" (CSS px of the
     * page's viewport; bottom window first: its index is its z), on the port's thread. Every window the page shows is
     * in it; one that isn't is hidden. Applied on the draw that shows page frame <frame> ([FrameSync]).
     */
    fun frameCommand(rest: String) {
        val (frame, geos) = parse(rest) ?: return
        val cookie = sync.receive(frame)
        main.post { sync.bind(frame, cookie) { apply(geos) } }
    }

    private fun parse(rest: String): Pair<Long, List<Geo>>? =
        try {
            val t = rest.trim().split(' ')
            val frame = t[0].toLong()
            val dpr = t[1].toFloat()
            val n = t[2].toInt()
            var i = 3
            // The WebView's place in its window (none for home: full screen): geometry is in the window surface's space.
            val at = IntArray(2).also(web::getLocationInWindow)

            fun px(
                v: String,
                o: Int,
            ) = Math.round(v.toFloat() * dpr) + o
            frame to
                List(n) { z ->
                    val id = t[i++].toInt()
                    val fx = px(t[i++], at[0])
                    val fy = px(t[i++], at[1])
                    val frameRect = Rect(fx, fy, fx + px(t[i++], 0), fy + px(t[i++], 0))
                    val bx = px(t[i++], at[0])
                    val by = px(t[i++], at[1])
                    val body = Rect(bx, by, bx + px(t[i++], 0), by + px(t[i++], 0))
                    val radius = t[i++].toFloat() * dpr
                    val visible = t[i++] == "1"
                    Geo(id, frameRect, body, radius, visible, z)
                }
        } catch (e: RuntimeException) {
            Log.w(TAG, "w.f: bad geometry ($e)")
            null
        }

    /** On the main thread, on the draw that shows the page frame the geometry was measured on. */
    private fun apply(geos: List<Geo>) {
        val t = SurfaceControl.Transaction()
        val shown = HashSet<Int>()
        for (g in geos) {
            val win = wins[g.id] ?: continue
            shown += g.id
            win.geo = g
            place(t, win, g)
        }
        for (win in wins.values) if (win.id !in shown && win.container.isValid) t.setVisibility(win.container, false)
        val now = geos.filter { it.visible && wins[it.id]?.mirror != null }.map { android.graphics.RectF(it.body) }
        if (now != shownBodies) {
            shownBodies = now
            bodiesChanged()
        }
        val attached = web.rootSurfaceControl
        if (attached == null) {
            t.apply()
        } else {
            attached.applyTransactionOnDraw(t)
            web.invalidate()
        }
        logFrame(geos)
    }

    /** At most one line a second (a drag sends one a frame). */
    private fun logFrame(geos: List<Geo>) {
        val now = SystemClock.uptimeMillis()
        if (now - lastPlaceLog < PLACE_LOG_MS || geos.isEmpty()) return
        lastPlaceLog = now
        Log.i(TAG, "w.f: " + geos.joinToString { "${it.id}@${it.body.toShortString()} z${it.z} ${if (it.visible) "shown" else "hidden"}" })
    }

    private var lastPlaceLog = 0L

    /** The bodies shown now, window px (main thread writes; the glass reads on the main thread). */
    @Volatile private var shownBodies: List<android.graphics.RectF> = emptyList()

    fun bodies(): List<android.graphics.RectF> = shownBodies

    /** [g] into [t]: the container at the frame (cropped, rounded, ordered, shown), the mirror at the body. */
    private fun place(
        t: SurfaceControl.Transaction,
        win: Win,
        g: Geo,
    ) {
        val c = win.container
        if (!c.isValid) return
        t.setPosition(c, g.frame.left.toFloat(), g.frame.top.toFloat())
        t.setCrop(c, Rect(0, 0, g.frame.width(), g.frame.height()))
        cornerRadius(t, c, g.radius)
        t.setLayer(c, g.z)
        // Hidden is the layer, never the display's surface (a null surface stops the app).
        t.setVisibility(c, g.visible && win.mirror != null)
        win.mirror?.takeIf { it.isValid }?.let { m ->
            t.setPosition(m, (g.body.left - g.frame.left).toFloat(), (g.body.top - g.frame.top).toFloat())
            t.setCrop(m, Rect(0, 0, g.body.width(), g.body.height()))
        }
        val bw = g.body.width().coerceAtLeast(1)
        val bh = g.body.height().coerceAtLeast(1)
        if (win.displayId >= 0 && (bw != win.w || bh != win.h)) {
            win.w = bw
            win.h = bh
            // The app lays out at the body's real size; the crop already follows the DOM (its last frame shows anchored
            // top-left until it draws at the new size).
            helper.resize(win.displayId, bw, bh, dpi)
        }
    }

    private val setCornerRadius by lazy {
        runCatching {
            HiddenApi.allow()
            SurfaceControl.Transaction::class.java.getMethod("setCornerRadius", SurfaceControl::class.java, Float::class.javaPrimitiveType)
        }.onFailure { Log.w(TAG, "no setCornerRadius: square windows", it) }.getOrNull()
    }

    private fun cornerRadius(
        t: SurfaceControl.Transaction,
        sc: SurfaceControl,
        r: Float,
    ) {
        runCatching { setCornerRadius?.invoke(t, sc, r) }
    }

    // ---- input (v0, until S4) ------------------------------------------------------------------------------------------

    /** A touch on the element's body (CSS px from its top-left): injected on its display. */
    fun input(
        id: Int,
        action: String,
        x: Double,
        y: Double,
    ): Boolean {
        val w = wins[id] ?: return false
        if (w.displayId < 0) return false
        val act = ACTIONS[action] ?: MotionEvent.ACTION_CANCEL
        val now = SystemClock.uptimeMillis()
        if (act == MotionEvent.ACTION_DOWN) w.downAt = now
        val ev = MotionEvent.obtain(w.downAt, now, act, (x * density()).toFloat(), (y * density()).toFloat(), 0)
        try {
            if (injectWorks != false && injectReflect(w.displayId, ev)) {
                if (injectWorks == null) Log.i(TAG, "input path: InputManager.injectInputEvent (reflection, setDisplayId)")
                injectWorks = true
                return true
            }
            if (injectWorks != false) Log.i(TAG, "input path: root `input -d <id> motionevent` (reflection refused)")
            injectWorks = false
            injectRoot(w.displayId, ev)
        } finally {
            ev.recycle()
        }
        return true
    }

    // ---- closing -------------------------------------------------------------------------------------------------------

    /** Gone: its tasks removed, its display released, "webwindows.closed" for the page. */
    fun close(id: Int): Boolean {
        val w = wins[id] ?: return false
        drop(w)
        return true
    }

    fun closeAll() {
        wins.values.toList().forEach { drop(it) }
        runCatching { dm.unregisterDisplayListener(displayListener) }
        helper.stop()
        root?.let { r ->
            if (r.isValid) SurfaceControl.Transaction().reparent(r, null).apply()
            r.release()
        }
        root = null
    }

    /** On the main thread. [released]: the display is already gone (removed, or never made). */
    private fun drop(
        w: Win,
        released: Boolean = false,
    ) {
        if (wins.remove(w.id) == null) return
        w.closed = true
        val t = SurfaceControl.Transaction()
        w.mirror?.let { if (it.isValid) t.reparent(it, null) }
        if (w.container.isValid) t.reparent(w.container, null)
        t.apply()
        w.mirror?.release()
        w.container.release()
        val displayId = w.displayId
        if (displayId >= 0 && !released) {
            io.post {
                // DESTROY_CONTENT_ON_REMOVAL finishes the activities but leaves the task in recents (S0): removed first.
                removeTasks(displayId)
                helper.release(displayId)
            }
        }
        Log.i(TAG, "closed window ${w.id} (display $displayId, ${w.component.packageName})")
        emit("webwindows.closed", w.id)
    }

    /** Every task on [displayId] removed (MANAGE_ACTIVITY_TASKS / REMOVE_TASKS, held as the recents provider). */
    private fun removeTasks(displayId: Int) {
        runCatching {
            HiddenApi.allow()
            val atm = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
            val roots = atm.javaClass.getMethod("getAllRootTaskInfosOnDisplay", Int::class.javaPrimitiveType).invoke(atm, displayId) as List<*>
            val ids = LinkedHashSet<Int>()
            for (r in roots) {
                if (r == null) continue
                runCatching { r.javaClass.getField("childTaskIds").get(r) as IntArray }.getOrNull()?.forEach { ids += it }
                ids += android.app.TaskInfo::class.java.getField("taskId").getInt(r)
            }
            val remove = atm.javaClass.getMethod("removeTask", Int::class.javaPrimitiveType)
            for (id in ids) {
                val ok = runCatching { remove.invoke(atm, id) as Boolean }.getOrDefault(false)
                Log.i(TAG, "display $displayId: task $id removed=$ok")
            }
        }.onFailure { Log.w(TAG, "display $displayId: its tasks not removed (they stay in recents)", it) }
    }

    // ---- launch, IME -----------------------------------------------------------------------------------------------------

    private fun launch(w: Win) {
        val intent =
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setComponent(w.component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            val opts = ActivityOptions.makeBasic().setLaunchDisplayId(w.displayId)
            context.startActivity(intent, opts.toBundle())
            Log.i(TAG, "launched ${w.component.flattenToShortString()} on display ${w.displayId} (ActivityOptions)")
        } catch (e: Exception) {
            Log.w(TAG, "ActivityOptions launch on display ${w.displayId} refused: ${e.message}; trying root am start")
            io.post {
                val r = runCatching { andro.marchy.RootShell.run("am start --display ${w.displayId} -f 0x10000000 -n ${w.component.flattenToShortString()}") }.getOrNull()
                Log.i(TAG, "launched ${w.component.flattenToShortString()} on display ${w.displayId} (root am start): code ${r?.code} ${r?.output?.take(200)}")
            }
        }
    }

    /** The keyboard for this display shows on the default display (DISPLAY_IME_POLICY_FALLBACK_DISPLAY). */
    private fun imePolicy(displayId: Int) {
        val result =
            runCatching {
                val wms = Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null)!!
                wms.javaClass.getMethod("setDisplayImePolicy", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).invoke(wms, displayId, IME_POLICY_FALLBACK_DISPLAY)
            }
        if (result.isSuccess) Log.i(TAG, "IME policy of display $displayId: fallback to default display (ok)")
        else Log.w(TAG, "IME policy of display $displayId not set: ${result.exceptionOrNull()?.let { it.cause ?: it }}")
    }

    // ---- the helper (WebWindowsHost, shell uid) ------------------------------------------------------------------------

    /**
     * [WebWindowsHost] in its own long-lived `su 2000` (one superuser request when it starts, as RootShell's note asks
     * of long-lived root processes), started at the first window. Its stdin closing (this process gone) releases every
     * display it made; it dying drops every window. All calls but [read] on [io].
     */
    private inner class Helper {
        private var process: Process? = null
        private var writer: BufferedWriter? = null
        private val waiting = HashMap<String, (Int, String?) -> Unit>()

        /** Running, or null (logged). */
        private fun ensure(): BufferedWriter? {
            writer?.let { if (process?.isAlive == true) return it }
            val apk = context.applicationInfo.sourceDir
            val cmd = "CLASSPATH='$apk' exec app_process /system/bin ${WebWindowsHost::class.java.name}"
            return try {
                val p = ProcessBuilder("su", "2000", "-c", cmd).redirectErrorStream(true).start()
                process = p
                writer = BufferedWriter(OutputStreamWriter(p.outputStream))
                Thread({ read(p) }, "powos-ww-helper").apply { isDaemon = true }.start()
                Log.i(TAG, "display helper started (shell uid, app_process)")
                writer
            } catch (e: Exception) {
                Log.w(TAG, "display helper not started", e)
                null
            }
        }

        /** Its own thread: the helper's answers. */
        private fun read(p: Process) {
            val r = BufferedReader(InputStreamReader(p.inputStream))
            while (true) answer(runCatching { r.readLine() }.getOrNull() ?: break)
            Log.w(TAG, "display helper gone (exit ${runCatching { p.waitFor() }.getOrNull()}): its windows close")
            val left = synchronized(waiting) { waiting.values.toList().also { waiting.clear() } }
            left.forEach { it(-1, "helper gone") }
            main.post { wins.values.filter { it.displayId >= 0 }.toList().forEach { drop(it, released = true) } }
        }

        private fun answer(line: String) {
            val a = line.split(' ', limit = 3)
            val waiter = if (a.size >= 2 && (a[0] == "display" || a[0] == "error")) synchronized(waiting) { waiting.remove(a[1]) } else null
            when {
                a[0] == "hello" -> Log.i(TAG, "display helper ready")
                a[0] == "display" -> waiter?.invoke(a.getOrNull(2)?.trim()?.toIntOrNull() ?: -1, "bad answer: $line")
                a[0] == "error" -> waiter?.invoke(-1, a.getOrNull(2))
                else -> Log.i(TAG, "display helper: $line")
            }
        }

        private fun send(line: String): Boolean {
            val w = ensure() ?: return false
            return try {
                w.write(line)
                w.newLine()
                w.flush()
                true
            } catch (e: java.io.IOException) {
                Log.w(TAG, "display helper: '$line' not sent", e)
                false
            }
        }

        /** A display of [w] x [h] px at the device's dpi; [done] hears its id (or -1 and why) on the helper's thread. */
        fun create(
            id: Int,
            w: Int,
            h: Int,
            done: (Int, String?) -> Unit,
        ) = io.post {
            synchronized(waiting) { waiting["$id"] = done }
            if (!send("create $id $w $h $dpi")) synchronized(waiting) { waiting.remove("$id") }?.invoke(-1, "no helper")
        }

        /** Coalesced: only the newest size per display goes out (a drag resizes every frame). */
        private val sizes = HashMap<Int, String>()

        fun resize(
            displayId: Int,
            w: Int,
            h: Int,
            dpi: Int,
        ) {
            val first = synchronized(sizes) { (displayId !in sizes).also { sizes[displayId] = "resize $displayId $w $h $dpi" } }
            if (first) io.post { synchronized(sizes) { sizes.remove(displayId) }?.let { send(it) } }
        }

        fun release(displayId: Int) {
            io.post { send("release $displayId") }
        }

        fun stop() =
            io.post {
                runCatching { writer?.close() }
                writer = null
                process = null
            }
    }

    private class Mirrors(
        val wm: Any,
        val mirrorDisplay: java.lang.reflect.Method,
        val newSurfaceControl: java.lang.reflect.Constructor<SurfaceControl>,
    )

    private val mirrors: Mirrors? by lazy {
        runCatching {
            HiddenApi.allow()
            val wm = Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null) ?: error("no window manager")
            Mirrors(
                wm,
                Class.forName("android.view.IWindowManager").getMethod("mirrorDisplay", Int::class.javaPrimitiveType, SurfaceControl::class.java),
                SurfaceControl::class.java.getDeclaredConstructor().apply { isAccessible = true },
            )
        }.onFailure { Log.w(TAG, "no IWindowManager.mirrorDisplay: no web windows", it) }.getOrNull()
    }

    // null: not tried yet; false: refused once, root from then on.
    private var injectWorks: Boolean? = null
    private val injectMethod by lazy {
        runCatching { android.hardware.input.InputManager::class.java.getMethod("injectInputEvent", InputEvent::class.java, Int::class.javaPrimitiveType) }.getOrNull()
    }
    private val setDisplayId by lazy { runCatching { MotionEvent::class.java.getMethod("setDisplayId", Int::class.javaPrimitiveType) }.getOrNull() }

    private fun injectReflect(
        displayId: Int,
        ev: MotionEvent,
    ): Boolean {
        val inject = injectMethod ?: return false
        val setId = setDisplayId ?: return false
        return try {
            ev.source = InputDevice.SOURCE_TOUCHSCREEN
            setId.invoke(ev, displayId)
            val im = context.getSystemService(android.hardware.input.InputManager::class.java)
            inject.invoke(im, ev, 0) as? Boolean ?: false // INJECT_INPUT_EVENT_MODE_ASYNC
        } catch (e: Exception) {
            Log.w(TAG, "injectInputEvent refused: ${(e.cause ?: e)}")
            false
        }
    }

    // Root fallback: moves coalesced to the latest, downs and ups in order.
    private val moveLock = Any()
    private var pendingMove: String? = null

    private fun injectRoot(
        displayId: Int,
        ev: MotionEvent,
    ) {
        val verb = VERBS[ev.actionMasked] ?: "CANCEL"
        val cmd = "input -d $displayId touchscreen motionevent $verb ${ev.x.toInt()} ${ev.y.toInt()}"
        if (ev.actionMasked != MotionEvent.ACTION_MOVE) {
            io.post { runCatching { andro.marchy.RootShell.run(cmd) }.onFailure { Log.w(TAG, "root input failed", it) } }
            return
        }
        val queued = synchronized(moveLock) { (pendingMove != null).also { pendingMove = cmd } }
        if (queued) return
        io.post {
            val c = synchronized(moveLock) { pendingMove.also { pendingMove = null } }
            if (c != null) runCatching { andro.marchy.RootShell.run(c) }
        }
    }

    companion object {
        private const val TAG = "PowosWebWindows"
        const val SETTING = "powos_web_windows"

        /**
         * After PowOS's process came back (an APK update, a crash) with web windows on: home started again if nothing
         * did it within [HOME_GRACE_MS]. Seen 2026-10-30 15:45:59 (d41c991b rolled back): the update killed home while
         * a web window's app (Calculator, display 37) had the phone's top focus - "Changing focus from
         * Window{... Calculator} to null,diplayid=37" - its display went with the old process's helper, and Android
         * never ran startHomeOnDisplay for display 0 again (none until the rollback 2.5 min later): no home, the boot
         * check failed. A touch on a web window's display takes the global focus (S0 (c)), so this can follow any
         * restart. Off the main thread, after a grace, only when no home task runs: never a second home.
         * HACK: a self-heal. Real fix: S5 hands the top focus back to display 0 whenever a web window's display goes
         * (and the system restarting home on its own display regardless of focus).
         */
        fun homeAfterRestart(context: Context) {
            if (!on(context)) return
            val app = context.applicationContext
            Thread({
                runCatching { Thread.sleep(HOME_GRACE_MS) }
                if (dev.omalauncher.system.FreeformTasks.homeTaskId(app) != null) return@Thread
                val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).setPackage(app.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                runCatching { app.startActivity(home, ActivityOptions.makeBasic().setLaunchDisplayId(android.view.Display.DEFAULT_DISPLAY).toBundle()) }
                    .onSuccess { Log.w(TAG, "no home ${HOME_GRACE_MS} ms after PowOS came back (web windows on): started it on display 0") }
                    .onFailure { Log.w(TAG, "no home after PowOS came back, and starting it failed", it) }
            }, "powos-ww-home").start()
        }

        private const val HOME_GRACE_MS = 4000L

        /** Windows are web windows: home's page owns them, the old floating-window path stands down (AppWindows.floating). */
        fun on(context: Context): Boolean = runCatching { Settings.Global.getInt(context.contentResolver, SETTING, 0) == 1 }.getOrDefault(false)
        private const val PLACE_LOG_MS = 1000L
        private const val MIRROR_WAIT_MS = 2000L
        private const val IME_POLICY_FALLBACK_DISPLAY = 1
        private val ACTIONS = mapOf("down" to MotionEvent.ACTION_DOWN, "move" to MotionEvent.ACTION_MOVE, "up" to MotionEvent.ACTION_UP)
        private val VERBS = mapOf(MotionEvent.ACTION_DOWN to "DOWN", MotionEvent.ACTION_MOVE to "MOVE", MotionEvent.ACTION_UP to "UP")
    }
}
