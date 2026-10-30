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
import android.view.WindowManager
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
 * - The window is an ELEMENT of home's page (docs/WEB_WINDOWS.md "Element model"; the user, 2026-10-30: "the whole way
 *   we integrate windows is still hacky, it needs to be handled properly fully inside the powos web ui"). Its title
 *   bar, buttons, edges, tile menu and dividers are DOM (shell/ui/webwindows.tsx). Only its CONTENT is native: one
 *   container layer per window (powos-ww-<id>) under one "powos-webwindows" layer, a child of home's own window
 *   surface BELOW home's buffer (layer -1, as a SurfaceView): the page is transparent exactly over the window's body,
 *   and every DOM element above the window (menus, popovers, other windows' bars, the dock) paints over it by DOM
 *   order. Every other window (launcher overlay, shade, PowOS AI, status bar, IME) is above home's whole tree.
 * - Geometry: each frame the page measures each window's body (after transforms: page swipes, the drawer's zoom),
 *   clipped by its ancestors and the screen, its visibility (off page, under an overlay, faded) and its DOM order, and
 *   sends "w.f" over its native port; it goes on the draw that shows that page frame ([FrameSync], the glass's
 *   binding), so the layer and the page's pixels change in one draw. Hidden: the layer, never its display's surface
 *   (that would STOP the app within ~40 ms, S0). A new body size resizes the display (VirtualDisplay.resize in the
 *   helper): the app lays out at its real pixel size.
 * - Input: the page's DOM hit test decides; a press on a body is forwarded ([forward]): Android injected on its
 *   display (v0), Linux the whole native gesture to KWin ([linuxClaim]).
 * - Mirrored and launched only once WM knows the display (mirrorDisplay says false for its first ~100 ms).
 * - Closed: the display's tasks removed (DESTROY_CONTENT_ON_REMOVAL alone leaves the task in recents), then the display.
 *
 * Android input (v0, until S4): the page forwards touches on the body ("webwindows.input"); they are injected on the
 * window's display - InputManager.injectInputEvent through reflection with MotionEvent.setDisplayId, else root
 * `input -d <id> motionevent`. Keyboard: the display's IME policy is the default display's.
 *
 * HACK: the root `input` fallback spawns a process per event (moves coalesced): taps work, drags are coarse. Real fix:
 * S4's injector (a persistent shell-uid helper holding INJECT_EVENTS - [WebWindowsHost] grows it).
 * HACK: IWindowManager.mirrorDisplay, the SurfaceControl() out-constructor, Transaction.setCornerRadius and the task
 * calls are hidden, reflected ([HiddenApi]). Real fix: none public for an app (a platform-signed system module).
 * Task reconcile ([reconcile]): a task stack listener (FreeformTasks.listen) re-checks every Android window's display
 * on each task change; a window whose display had its app and is empty now (the app finished, its task moved to another
 * display or was re-parented - OnePlus' Open Canvas took Chrome off its display into com.oplus.pscanvas, then removed
 * it, 2026-10-30) is closed the bar's way ("webwindows.closed"), so no empty frame stays and the next launch of the app
 * makes a new window instead of raising the orphan.
 *
 * Linux windows (S6): KWin's "open" comes here instead of a PowosWindowActivity task ([linuxOpened], through
 * andro.marchy.WebWindowSource and ShellBridge's host); the window is the same container, frame, geometry and touches as
 * an Android app's, with KWin's per-window buffers drawn by the consumer into a layer of its own ([LinuxSource]) in the
 * mirror's place. Body touches go natively to KWin ([linuxInput]); the body size is KWin's window size ("size"); close
 * is KWin's quit. Not yet: popups as their own surfaces (S7), the switcher card, the keyboard (SystemIME), title updates.
 *
 * Doesn't touch the freeform windows (system/WindowFrames.kt): with the setting off nothing here runs.
 */
class WebWindows(
    private val context: Context,
    private val web: WebView,
    private val emit: (String, Any?) -> Unit,
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

    private val reconcileRun = Runnable { reconcile() }

    /** Stops the task stack listener ([reconcile]); null where it can't be registered. */
    private val stopTasks: (() -> Unit)? = dev.omalauncher.system.FreeformTasks.listen { main.post { scheduleReconcile() } }

    /** A task changed (main thread): one [reconcile] [RECONCILE_MS] after the last change of a burst. */
    private fun scheduleReconcile() {
        if (wins.isEmpty()) return
        main.removeCallbacks(reconcileRun)
        main.postDelayed(reconcileRun, RECONCILE_MS)
    }

    /**
     * Main thread: each Android window's display read on [io]; one that had its app and is empty now is checked again
     * [RECONCILE_MS] later (a trampoline activity, a move in progress) and, still [orphaned], closed - the frame never
     * outlives its task.
     */
    private fun reconcile() {
        val ws = wins.values.filter { it.linux == null && !it.closed && it.displayId >= 0 }
        if (ws.isNotEmpty()) io.post { ws.forEach(::checkOrphan) }
    }

    /** On [io]: [w]'s display read; empty after it had its app: read again [RECONCILE_MS] later ([confirmOrphan]). */
    private fun checkOrphan(w: Win) {
        val n = tasksOn(w.displayId)
        if (n != null && n > 0) w.landed = true
        if (gone(w, n)) io.postDelayed({ confirmOrphan(w) }, RECONCILE_MS)
    }

    /** On [io]: [w]'s display still empty - the window closed the bar's way (main thread). */
    private fun confirmOrphan(w: Win) {
        val again = tasksOn(w.displayId)
        if (!gone(w, again)) return
        main.post {
            if (!gone(w, again)) return@post
            Log.i(TAG, "window ${w.id} (${w.component.packageName}): its app's task left display ${w.displayId} (finished, moved to another display or re-parented): window closed")
            drop(w)
        }
    }

    private fun gone(
        w: Win,
        tasks: Int?,
    ): Boolean {
        val held = w.full || w.adopt >= 0 || (w.taskId >= 0 && WebWindowDisplays.fullScreenWindow(w.taskId) == w.id)
        return orphaned(w.closed, w.landed, held, tasks)
    }

    init {
        current = this
        runCatching { dm.registerDisplayListener(displayListener, main) }
        // Every touch on home, watched (never taken): a Linux body the page pressed gets the whole gesture natively.
        (web as? HomeWebView)?.touchHook = ::onTouch
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

        /** Its app's content shows: the page dropped the placeholder ([liveWhenDrawn]). */
        var live = false

        /** In the page's last "w.f" and visible (main thread): only those take touches ([hit]). */
        var shown = false

        /** Its app's task (learned from its display when first needed; kept while it's a full-screen app). */
        @Volatile var taskId = -1

        /** A running task to move onto its display instead of a launch (ShellBridge.toWebWindow: an app made a window), or -1. */
        @Volatile var adopt = -1

        /** Its app is a full-screen app on display 0 now ([fullScreen]): the window is hidden, its display empty. */
        @Volatile var full = false

        @Volatile var closed = false

        /** Its display has had its app's task (seen by [checkLanded] / [reconcile]); false again on each [launch]. */
        @Volatile var landed = false

        /** A Linux (KWin) window's source instead of a display ([LinuxSource]; docs/WEB_WINDOWS.md S6), else null. */
        var linux: LinuxSource? = null

        /** Its Linux window is full screen ([linuxFullScreen], kwin 0043): the whole screen, no bar, the page's place kept. */
        var linuxFull = false
    }

    /**
     * A Linux window's content: KWin's per-window buffers (the display daemon's surface [kwin], kwin 0013) drawn by the
     * consumer (native_consumer.c, as PowosWindowActivity's SurfaceView) into [content], a buffer layer in the window's
     * container that takes the mirror's place (Win.mirror = content: geometry, crop, hit test and visibility are the
     * same code for both sources). Buffers are the screen's size; the window's body size is their crop and the size
     * KWin lays the window out at ("size"), so a resize allocates nothing and the content is shown 1:1 from the top
     * left: never stretched, never offset.
     */
    private class LinuxSource(
        val kwin: Int,
        val offer: LinuxOffer,
        val content: SurfaceControl,
        val surface: android.view.Surface,
    ) {
        /** The consumer (0 until it started, and after it stopped). */
        @Volatile var handle = 0L

        /** KWin closed the window itself: nothing to tell it on the way out. */
        var kwinClosed = false
    }

    /** A KWin window for a web window: its app id and caption (KWin's), its name and icon (PowOS's, for the bar). */
    class LinuxOffer(
        val appId: String,
        val title: String,
        val label: String,
        val icon: android.graphics.drawable.Drawable?,
    ) {
        /** Its app's drawer key ("l:<desktop id>", [linuxOpened]): the app menu's close and its switcher card find it. */
        var key = ""
    }

    /** KWin windows on their way to a web window: offered to the page ("webwindows.adopt"), not opened yet (main thread). */
    private val pendingLinux = HashMap<Int, LinuxOffer>()

    /** The consumers' starts and stops: one at a time, in order, never on main (a stop joins its render thread). */
    private val consumers by lazy { java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "powos-ww-linux") } }

    /**
     * One window as the page measured it this frame, in home's window surface px, after transforms: [frame] the
     * element (its bar's place for the status bar), [body] the app's place on screen (scaled), [clip] what of the body
     * its ancestors and the screen let show, [bw]x[bh] the body's own (unscaled) px - the app's display size. z: its
     * DOM order (0 = bottom).
     */
    private class Geo(
        val id: Int,
        val z: Int,
    ) {
        var frame = Rect()
        var body = Rect()
        var clip = Rect()
        var bw = 1
        var bh = 1
        var radius = 0f
        var visible = false
        var alpha = 1f
        var scale = 1f
        var maximised = false

        /** Maximised (the bar merges with the status bar): where its title ends and its controls start, else -1. */
        var titleEnd = -1
        var controls = -1
    }

    /** The layer all windows hang under: home's window surface, under its own buffer. Made on first use (main thread). */
    private var root: SurfaceControl? = null

    private fun root(): SurfaceControl? {
        root?.takeIf { it.isValid }?.let { return it }
        val attached = web.rootSurfaceControl ?: return null.also { Log.w(TAG, "home's window has no surface yet") }
        val sc = SurfaceControl.Builder().setName("powos-webwindows").build()
        val t = attached.buildReparentTransaction(sc) ?: return null.also { sc.release(); Log.w(TAG, "home's surface refused a child") }
        // BELOW home's own buffer (as a SurfaceView): the window is an element of the page - the page is transparent over
        // its body, and every DOM element above it in the page (menus, popovers, bars, the dock) paints over it.
        t.setLayer(sc, -1).setVisibility(sc, !underSwitcher).apply()
        root = sc
        watchSurface()
        return sc
    }

    /** The switcher is up: every window's layer hidden under it (main thread). */
    private var underSwitcher = false

    /** The windows' root shown ([on]) or hidden, at once (main thread): [switcherOpen]. */
    private fun rootShown(on: Boolean) {
        underSwitcher = !on
        val r = root?.takeIf { it.isValid } ?: return
        SurfaceControl.Transaction().setVisibility(r, on).apply()
        Log.i(TAG, "windows ${if (on) "shown again (switcher down)" else "hidden under the switcher (each is its card)"}: ${wins.size} window(s)")
    }

    /**
     * A window for [component], its body at [rect] (CSS px): its id, or -1 (setting off, no surface to host it). [task]:
     * an app's running task to move into it (ShellBridge.toWebWindow) instead of launching the app afresh.
     */
    fun open(
        component: ComponentName,
        rect: JSONObject,
        task: Int = -1,
    ): Int {
        if (!enabled()) return -1.also { Log.w(TAG, "open ${component.packageName}: $SETTING is off") }
        unresizeable(component)?.let { why ->
            // Fallback: Android's own window (the caller launches it as before; the switcher uses Android's split).
            Log.w(TAG, "fallback: ${component.packageName} keeps Android's own window/split, not a web window: $why")
            return -1
        }
        val parent = root() ?: return -1
        val id = nextId++
        val d = density()
        val w = (rect.optDouble("width") * d).toInt().coerceAtLeast(1)
        val h = (rect.optDouble("height") * d).toInt().coerceAtLeast(1)
        // Hidden until the page's first "w.f" places it.
        val container = SurfaceControl.Builder().setName("powos-ww-$id").setParent(parent).setHidden(true).build()
        val win = Win(id, component, container, w, h)
        win.adopt = task
        wins[id] = win
        helper.create(id, w, h) { displayId, error ->
            if (displayId < 0) {
                Log.w(TAG, "window $id (${component.packageName}): no display: $error")
                main.post { drop(win, released = true) }
                return@create
            }
            win.displayId = displayId
            WebWindowDisplays.add(displayId, id)
            // Closed while its display was being made: the display goes too.
            if (win.closed) return@create helper.release(displayId)
            Log.i(TAG, "window $id: trusted display $displayId ${w}x$h dpi $dpi (${component.packageName})")
            io.post { mirrorWhenKnown(win, SystemClock.uptimeMillis()) }
        }
        return id
    }

    // ---- Linux windows (docs/WEB_WINDOWS.md S6) ------------------------------------------------------------------------

    /**
     * KWin opened window [kwin] ([andro.marchy.WebWindowSource]; main thread): a web window of it on home's page on screen,
     * made when the page takes it ("webwindows.adopt" {kwin, key, label} -> adoptWebWindow -> "webwindows.open" ->
     * [openLinux]) - the page owns its place, page and z as for an Android app. One that is a web window already (KWin
     * shows it again: the launcher, the dock) comes back where it was. No page answer within [LINUX_ADOPT_MS] (no
     * page, a page from before S6): it opens as its own task after all, as without web windows.
     */
    fun linuxOpened(
        kwin: Int,
        key: String,
        offer: LinuxOffer,
    ) {
        wins.values.firstOrNull { it.linux?.kwin == kwin }?.let { w ->
            Log.i(TAG, "KWin window $kwin (${offer.appId}) again: web window ${w.id} shown where it was")
            emit("webwindows.show", w.id)
            return
        }
        if (pendingLinux.containsKey(kwin)) return
        offer.key = key
        pendingLinux[kwin] = offer
        Log.i(TAG, "KWin window $kwin (${offer.appId}, \"${offer.title}\"): offered to the page as $key")
        emit("webwindows.adopt", JSONObject().put("kwin", kwin).put("key", key).put("label", offer.label))
        main.postDelayed({
            pendingLinux.remove(kwin)?.let { p ->
                Log.w(TAG, "fallback: KWin window $kwin (${p.appId}): the page made no web window in $LINUX_ADOPT_MS ms, a task instead")
                andro.marchy.WebWindowSource.fallback(context, kwin, p.appId, p.title)
            }
        }, LINUX_ADOPT_MS)
    }

    /**
     * The page's "webwindows.open" for KWin window [kwin] ([linuxOpened]), its body at [rect] (CSS px): the window's id,
     * or -1. Its container as an Android app's, its native frame (the app's icon and name), and a buffer layer the
     * consumer draws KWin's window into ([LinuxSource]).
     */
    fun openLinux(
        kwin: Int,
        rect: JSONObject,
    ): Int {
        val p = pendingLinux.remove(kwin) ?: return -1.also { Log.w(TAG, "open KWin window $kwin: not offered (or taken already)") }
        val parent = root() ?: return -1.also { andro.marchy.WebWindowSource.fallback(context, kwin, p.appId, p.title) }
        val id = nextId++
        val d = density()
        val w = (rect.optDouble("width") * d).toInt().coerceAtLeast(1)
        val h = (rect.optDouble("height") * d).toInt().coerceAtLeast(1)
        val container = SurfaceControl.Builder().setName("powos-ww-$id").setParent(parent).setHidden(true).build()
        // The screen's size, either way round (a resize or a rotation needs no new buffers): PowosWindowActivity's buffersFor.
        val metrics = context.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds
        val bw = maxOf(metrics.width(), w)
        val bh = maxOf(metrics.height(), h)
        // Its buffer queue's size = the body (the consumer's crop): a queued buffer shows 1:1, as in a SurfaceView.
        val content =
            SurfaceControl.Builder().setName("powos-ww-$id-linux").setParent(container).setBufferSize(w, h)
                .setFormat(android.graphics.PixelFormat.TRANSLUCENT).build()
        val src = LinuxSource(kwin, p, content, android.view.Surface(content))
        val win = Win(id, ComponentName(context.packageName, "kwin:${p.appId}"), container, w, h)
        win.linux = src
        // The content takes the mirror's place: shown under the bar, cropped to the body (nothing until KWin's first frame).
        win.mirror = content
        SurfaceControl.Transaction().setLayer(content, 0).setVisibility(content, true).setCrop(content, Rect(0, 0, 0, 0)).apply()
        wins[id] = win
        val rate = web.display?.refreshRate ?: 0f
        consumers.execute {
            if (win.closed) return@execute
            andro.marchy.WebWindowSource.configure(context)
            val handle = andro.marchy.WebWindowSource.start(src.surface, kwin, bw, bh)
            if (handle == 0L) {
                Log.e(TAG, "window $id (KWin window $kwin): consumer did not start")
                return@execute
            }
            // Published before the crop: a resize placed meanwhile (place() on main) crops this consumer too, and a
            // touch on the body reaches KWin from the first frame (a 0 handle drops both silently).
            src.handle = handle
            // Its own Android keyboard (kwin 0043 window-ime): KWin's show/hide for it and its typed text on this consumer.
            andro.marchy.WebWindowSource.ownKeyboard(kwin, handle)
            andro.marchy.WebWindowSource.crop(handle, win.w, win.h)
            andro.marchy.WebWindowSource.refreshRate(handle, rate)
            if (win.closed) {
                src.handle = 0
                andro.marchy.WebWindowSource.stop(handle)
                return@execute
            }
            Log.i(TAG, "window $id: KWin window $kwin (${p.appId}) consumer up, buffers ${bw}x$bh, body ${win.w}x${win.h}")
            liveWhenDrawn(win)
        }
        andro.marchy.WebWindowSource.size(kwin, w, h)
        // KWin focused the new window (its task's start): a touch back on the window it came from focuses that again.
        linuxFocused = kwin
        Log.i(TAG, "window $id: KWin window $kwin (${p.appId}) as a web window, ${w}x$h")
        return id
    }

    /**
     * The switcher's cards for Linux web windows (they have no Android task): (card id, window id, app key, name), top
     * window first. Card ids are [LINUX_CARD] + the window id, above any task id, so Tasks.remove / tasks.open / the
     * card picture come back here ([closeForTask], [openForTask], [cardShot]). Main thread.
     */
    fun linuxCards(): List<LinuxCard> =
        wins.values.filter { it.linux != null }.sortedByDescending { it.geo?.z ?: -1 }.map { w ->
            val o = w.linux!!.offer
            LinuxCard(LINUX_CARD + w.id, w.id, o.key, o.label)
        }

    class LinuxCard(
        val id: Int,
        val window: Int,
        val key: String,
        val label: String,
    )

    /**
     * Closes every Linux web window of app [key] ("l:<desktop id>"; the app menu's close) as its bar's close does:
     * KWin closes each window, then ends the app if it stays (quit). True if it had one. Main thread.
     */
    fun closeLinuxApp(key: String): Boolean {
        val ws = wins.values.filter { it.linux?.offer?.key == key }
        ws.forEach { w ->
            Log.i(TAG, "window ${w.id}: closed with its app $key (the app menu's close)")
            drop(w)
        }
        return ws.isNotEmpty()
    }

    /** KWin closed window [kwin] (main thread): its web window goes, nothing told back. */
    fun linuxClosed(kwin: Int) {
        pendingLinux.remove(kwin)
        val w = wins.values.firstOrNull { it.linux?.kwin == kwin } ?: return
        w.linux?.kwinClosed = true
        Log.i(TAG, "KWin closed window $kwin: web window ${w.id} goes")
        drop(w)
    }

    /**
     * A Linux window [w] going ([drop]; nothing for an Android one): its touch over, its consumer off (on its thread)
     * and, unless KWin closed it, KWin told: [handBack] = a task again, else quit.
     */
    private fun dropLinux(
        w: Win,
        handBack: Boolean,
    ) {
        if (linuxTouch === w) linuxTouch = null
        val src = w.linux ?: return
        consumers.execute {
            val h = src.handle
            src.handle = 0
            andro.marchy.WebWindowSource.stop(h)
            src.surface.release()
        }
        if (src.kwinClosed) return
        if (handBack) andro.marchy.WebWindowSource.fallback(context, src.kwin, src.offer.appId, src.offer.title)
        else andro.marchy.WebWindowSource.quit(context, src.kwin)
        Log.i(TAG, "close window ${w.id}: KWin window ${src.kwin} ${if (handBack) "handed back as a task" else "quit (KWin closes it, then ends the app)"}")
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
        if (win.adopt >= 0) io.post { adoptNow(win) } else launch(win)
        io.post { liveWhenDrawn(win) }
    }

    /**
     * On [io]: [win]'s app is an app already running (task [Win.adopt]) - the switcher's "PowOS desktop window", the
     * system menu's "Desktop window": that task moved onto the window's display ([moveTask], as the full screen button's
     * way back), never a second launch. Not movable (gone, refused): the app launched there instead.
     */
    private fun adoptNow(win: Win) {
        if (win.closed) return
        val task = win.adopt
        win.adopt = -1
        val ok = moveTask(task, win.displayId)
        Log.i(TAG, "window ${win.id}: app's task $task ${if (ok) "moved onto display ${win.displayId}" else "NOT moved: launched there instead"}")
        if (ok) win.taskId = task else main.post { if (!win.closed) launch(win) }
    }

    // ---- geometry ------------------------------------------------------------------------------------------------------

    /**
     * "w.f <frame> <dpr> <n> [<id> <frame x y w h> <body x y w h> <clip l t r b> <radius> <visible> <alpha> <scale>
     * <maximised> <titleEnd> <controls>] * n" (viewport CSS px, measured after transforms; bottom window first: its index
     * is its z), on the port's thread. Every window the page shows is in it; one that isn't is hidden. Applied on the
     * draw that shows page frame <frame> ([FrameSync]).
     */
    fun frameCommand(rest: String) {
        val (frame, geos) = parse(rest) ?: return
        val cookie = sync.receive(frame)
        main.post { sync.bind(frame, cookie) { apply(frame, geos) } }
    }

    @Volatile private var lastDpr = 1f

    private fun parse(rest: String): Pair<Long, List<Geo>>? =
        try {
            val t = rest.trim().split(' ')
            val dpr = t[1].toFloat()
            lastDpr = dpr
            // The WebView's place in its window (none for home: full screen): geometry is in the window surface's space.
            val c = Cursor(t, 3, dpr, IntArray(2).also(web::getLocationInWindow))
            t[0].toLong() to List(t[2].toInt()) { z -> entry(c, z) }
        } catch (e: RuntimeException) {
            Log.w(TAG, "w.f: bad geometry ($e)")
            null
        }

    /** Reads "w.f"'s words in order: CSS px to window px. */
    private class Cursor(
        val t: List<String>,
        var i: Int,
        val dpr: Float,
        val at: IntArray,
    ) {
        fun word() = t[i++]

        fun px(o: Int) = Math.round(word().toFloat() * dpr) + o

        /** x y w h ([wh]) or l t r b. */
        fun rect(wh: Boolean): Rect {
            val l = px(at[0])
            val top = px(at[1])
            return if (wh) Rect(l, top, l + px(0), top + px(0)) else Rect(l, top, px(at[0]), px(at[1]))
        }

        /** An x, or -1 for a negative (absent) one. */
        fun x(): Int = word().toFloat().let { if (it < 0) -1 else Math.round(it * dpr) + at[0] }
    }

    /** One window's entry (see [frameCommand]). */
    private fun entry(
        c: Cursor,
        z: Int,
    ): Geo =
        Geo(c.word().toInt(), z).apply {
            frame = c.rect(true)
            body = c.rect(true)
            clip = c.rect(false)
            radius = c.word().toFloat() * c.dpr
            visible = c.word() == "1"
            alpha = c.word().toFloat().coerceIn(0f, 1f)
            scale = c.word().toFloat().takeIf { it > MIN_ZOOM } ?: 1f
            maximised = c.word() == "1"
            titleEnd = c.x()
            controls = c.x()
            bw = Math.round(body.width() / scale).coerceAtLeast(1)
            bh = Math.round(body.height() / scale).coerceAtLeast(1)
        }

    /** On the main thread, on the draw that shows the page frame the geometry was measured on. */
    private fun apply(
        frame: Long,
        geos: List<Geo>,
    ) {
        val t = SurfaceControl.Transaction()
        placeAll(t, geos)
        val attached = web.rootSurfaceControl
        if (attached == null) {
            t.apply()
        } else {
            attached.applyTransactionOnDraw(t)
            web.invalidate()
        }
        logFrame(frame, geos)
    }

    /** Every window in [geos] placed into [t]; one the page left out hidden. */
    private fun placeAll(
        t: SurfaceControl.Transaction,
        geos: List<Geo>,
    ) {
        // A full-screen Linux window keeps its own place ([linuxFullScreen]): neither placed nor hidden by the page.
        val shown = wins.values.filter { it.linuxFull }.mapTo(HashSet()) { it.id }
        for (g in geos.filterNot { it.id in shown }) {
            val win = wins[g.id] ?: continue
            shown += g.id
            win.shown = g.visible
            win.geo = g
            place(t, win, g)
        }
        for (win in wins.values) {
            if (win.id in shown || !win.container.isValid) continue
            win.shown = false
            t.setVisibility(win.container, false)
        }
        publishBars()
    }

    /**
     * The status bar's share of the windows (ShadeHost.windowBars, spec G-R): each shown window's title bar on screen -
     * a maximised one's title and controls only, its middle being the status bar's (TB1/TB2) - and the top-most
     * maximised window's merge. Home's surface is at the screen's top left, so window px are display px (main thread).
     */
    private fun publishBars() {
        val bars = ArrayList<Rect>()
        var merge: IntArray? = null
        for (win in wins.values.sortedBy { it.geo?.z ?: -1 }) merge = barsOf(win, bars) ?: merge
        dev.omalauncher.system.ShadeHost.current?.windowBars(bars, merge)
    }

    /** [win]'s bar parts on screen into [out]; maximised, its merge (title end, controls start), else null. */
    private fun barsOf(
        win: Win,
        out: MutableList<Rect>,
    ): IntArray? {
        if (win.linuxFull) return null // full screen: no bar of its own on screen
        val g = win.geo?.takeIf { win.shown && it.visible && win.mirror != null } ?: return null
        val f = g.frame
        // The bar is the element above its body (DOM: ui/webwindows.tsx TitleBar).
        val bottom = g.body.top
        if (!g.maximised || g.titleEnd < 0 || g.controls < 0) {
            out += Rect(f.left, f.top, f.right, bottom)
            return null
        }
        out += Rect(f.left, f.top, g.titleEnd, bottom)
        out += Rect(g.controls, f.top, f.right, bottom)
        return intArrayOf(g.titleEnd, g.controls)
    }

    /**
     * At most one line a second (a page-driven move sends one a frame). "behind": how many newer page frames had already
     * arrived when this one was bound to a draw - the page's DOM on that draw is at least that many frames newer than
     * the geometry, so the content trails the DOM chrome by that much (docs/WEB_WINDOWS.md "Measured lag").
     */
    private fun logFrame(
        frame: Long,
        geos: List<Geo>,
    ) {
        val behind = sync.received - frame
        if (behind > 0) behindFrames++
        appliedFrames++
        val now = SystemClock.uptimeMillis()
        if (now - lastPlaceLog < PLACE_LOG_MS || geos.isEmpty()) return
        lastPlaceLog = now
        Log.i(TAG, "w.f f$frame behind=$behind (${behindFrames}/$appliedFrames applies behind) " + geos.joinToString { "${it.id}@${it.body.toShortString()} clip ${it.clip.toShortString()} z${it.z} ${if (it.visible) "shown" else "hidden"}" })
    }

    private var lastPlaceLog = 0L
    private var behindFrames = 0
    private var appliedFrames = 0

    /** [g] into [t]: the container at the body (cropped to its clip, rounded, ordered, faded, shown), the mirror in it. */
    private fun place(
        t: SurfaceControl.Transaction,
        win: Win,
        g: Geo,
    ) {
        val c = win.container
        if (!c.isValid) return
        frameAt(t, win, g)
        cornerRadius(t, c, g.radius)
        t.setLayer(c, g.z)
        t.setAlpha(c, g.alpha)
        // Hidden is the layer, never the display's surface (a null surface stops the app).
        t.setVisibility(c, g.visible && !g.clip.isEmpty && win.mirror != null)
        resizeContent(win, g.bw, g.bh)
    }

    /** A new body size ([bw]x[bh] px) to [win]'s source: KWin's window size, or its display's (the helper). */
    private fun resizeContent(
        win: Win,
        bw: Int,
        bh: Int,
    ) {
        if (bw == win.w && bh == win.h) return
        val src = win.linux
        if (src != null) {
            linuxResize(win, src, bw, bh)
        } else if (win.displayId >= 0) {
            win.w = bw
            win.h = bh
            // The app lays out at the body's real size; the crop already follows the DOM (its last frame shows anchored
            // top-left until it draws at the new size).
            helper.resize(win.displayId, bw, bh, dpi)
        }
    }

    /** KWin's window [src] of [win] laid out at [bw] x [bh] px, its buffer queue and the consumer's crop the same. */
    private fun linuxResize(
        win: Win,
        src: LinuxSource,
        bw: Int,
        bh: Int,
    ) {
        win.w = bw
        win.h = bh
        // KWin lays the window out at the body's size; the consumer's crop and the buffer queue's size follow in
        // this transaction, so its next frames show 1:1 (one of the old size is dropped by the queue, never stretched).
        // Its own transaction, applied now: a buffer size riding [t] (applyTransactionOnDraw merges it into the
        // view's next frame natively) would skip SurfaceControl's Java-side queue resize - every later frame rejected.
        if (src.content.isValid) SurfaceControl.Transaction().setBufferSize(src.content, bw, bh).apply()
        andro.marchy.WebWindowSource.crop(src.handle, bw, bh)
        andro.marchy.WebWindowSource.size(src.kwin, bw, bh)
    }

    /**
     * The window's layers for [g] into [t]: the container at the body's place on screen, scaled as the element is
     * (a page's zoom, the window's own), cropped to the body's clip in its own px - and [Geo.radius] above it, under
     * the DOM title bar, so the rounded corners round only the body's bottom (its top ones are under the bar, which is
     * DOM over home's buffer and has no content of the window under it). The mirror (or Linux content) at 0,0, cropped
     * to the body's own size.
     */
    private fun frameAt(
        t: SurfaceControl.Transaction,
        win: Win,
        g: Geo,
    ) {
        val c = win.container
        val s = g.scale
        t.setPosition(c, g.body.left.toFloat(), g.body.top.toFloat())
        t.setScale(c, s, s)
        val local = { v: Int, o: Int -> (v - o) / s }
        val r = Math.ceil(g.radius.toDouble()).toInt()
        val top = if (g.clip.top <= g.body.top) -r else Math.floor(local(g.clip.top, g.body.top).toDouble()).toInt()
        val crop =
            Rect(
                Math.floor(local(g.clip.left, g.body.left).toDouble()).toInt().coerceAtLeast(0),
                top,
                Math.ceil(local(g.clip.right, g.body.left).toDouble()).toInt().coerceAtMost(g.bw),
                Math.ceil(local(g.clip.bottom, g.body.top).toDouble()).toInt().coerceAtMost(g.bh),
            )
        if (crop.isEmpty) crop.set(0, 0, 0, 0)
        t.setCrop(c, crop)
        win.mirror?.takeIf { it.isValid }?.let { m ->
            t.setPosition(m, 0f, 0f)
            t.setScale(m, 1f, 1f)
            t.setCrop(m, Rect(0, 0, g.bw, g.bh))
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

    // ---- home's surface recreated (stop/start, screen off/on, fold) --------------------------------------------------------

    /**
     * Home's window surface is destroyed when home stops and made anew when it shows again (WindowManager: "HomeShell
     * ... state from DRAW_PENDING to NO_SURFACE; reason: destroySurface"; VRI "relayoutWindow result ...
     * surfaceControlChanged:true"). [root] was a child of the OLD surface: it stayed a valid handle but an orphan
     * (`dumpsys SurfaceFlinger --list`: "powos-webwindows#5397 z=-1" with no parentId), so every window - and every
     * window opened after (root() reused it) - showed nothing (the user, 2026-10-30: "when I got to the home again the
     * chrome window had no content"). Now the root is re-parented onto each new surface in the transaction that goes
     * with its first frame; containers and mirrors hang under the root and come with it, the apps never relaunch.
     *
     * HACK: ViewRootImpl.addSurfaceChangedCallback / SurfaceChangedCallback are hidden (what SurfaceView uses),
     * reflected through a Proxy. Fallback (public, API 34): window visibility back to VISIBLE -> re-parent on the next
     * pre-draw. Real fix: none public for a child layer of a window's own surface.
     */
    private var surfaceWatched = false

    private fun watchSurface() {
        if (surfaceWatched) return
        val vri = web.rootSurfaceControl ?: return
        surfaceWatched = true
        if (hookSurfaceChanged(vri)) return
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE) reattachWhenVisible()
    }

    /** ViewRootImpl.addSurfaceChangedCallback with a Proxy of its hidden interface; false: refused. */
    private fun hookSurfaceChanged(vri: Any): Boolean =
        runCatching {
            HiddenApi.allow()
            val cb = Class.forName("android.view.ViewRootImpl\$SurfaceChangedCallback")
            val proxy = java.lang.reflect.Proxy.newProxyInstance(cb.classLoader, arrayOf(cb)) { p, m, args -> surfaceCall(p, m.name, args) }
            vri.javaClass.getMethod("addSurfaceChangedCallback", cb).invoke(vri, proxy)
        }.onFailure { Log.w(TAG, "no surface callback: re-attached on window visibility instead", it) }.isSuccess

    /** One call on the surface callback's Proxy (UI thread). */
    private fun surfaceCall(
        proxy: Any,
        name: String,
        args: Array<out Any?>?,
    ): Any? =
        when (name) {
            "surfaceCreated", "surfaceReplaced" -> reattach(args?.getOrNull(0) as? SurfaceControl.Transaction, name).let { null }
            "surfaceDestroyed" -> Log.i(TAG, "home's surface destroyed: ${wins.size} window(s) wait for the next one").let { null }
            "hashCode" -> System.identityHashCode(proxy)
            "equals" -> proxy === args?.getOrNull(0)
            "toString" -> "powos-webwindows surface watch"
            else -> null
        }

    /** The public fallback: window visible again -> re-parent on the next pre-draw (the new surface is made in that traversal). */
    @androidx.annotation.RequiresApi(android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun reattachWhenVisible() {
        web.viewTreeObserver.addOnWindowVisibilityChangeListener { v ->
            if (v != android.view.View.VISIBLE) return@addOnWindowVisibilityChangeListener
            val vto = web.viewTreeObserver
            vto.addOnPreDrawListener(
                object : android.view.ViewTreeObserver.OnPreDrawListener {
                    override fun onPreDraw(): Boolean {
                        if (vto.isAlive) vto.removeOnPreDrawListener(this)
                        reattach(null, "visible")
                        return true
                    }
                },
            )
        }
    }

    /** Main thread: [root] onto home's current surface ([t]: the new surface's first-frame transaction, else applied now); lost mirrors made again. */
    private fun reattach(
        t: SurfaceControl.Transaction?,
        why: String,
    ) {
        val r = root?.takeIf { it.isValid } ?: return
        val re = web.rootSurfaceControl?.buildReparentTransaction(r) ?: run { Log.w(TAG, "home's surface $why: no surface to re-attach to"); return }
        if (t != null) t.merge(re) else re.apply()
        Log.i(TAG, "home's surface $why: windows' root re-attached (${wins.size} window(s): ${wins.values.joinToString { "${it.id}@d${it.displayId}" }})")
        for (w in wins.values) if (w.displayId >= 0 && w.mirror?.isValid == false) io.post { remirror(w) }
    }

    /** On [io]: [w]'s display mirrored again into its container (its mirror lost), the app left running as it is. */
    private fun remirror(w: Win) {
        if (w.closed) return
        val out = runCatching { mirror(w.displayId) }.getOrNull() ?: run { Log.w(TAG, "window ${w.id}: display ${w.displayId} not mirrored again"); return }
        main.post {
            if (w.closed || !w.container.isValid) return@post out.release()
            w.mirror?.release()
            w.mirror = out
            val t = SurfaceControl.Transaction().reparent(out, w.container).setLayer(out, 0).setVisibility(out, true).setCrop(out, Rect(0, 0, 0, 0))
            w.geo?.let { place(t, w, it) }
            t.apply()
            Log.i(TAG, "window ${w.id}: display ${w.displayId} mirrored again")
        }
    }

    // ---- input: the page's DOM decides what a touch is on, the host delivers it (docs "Element model") ---------------

    /**
     * Every touch on home as the WebView gets it ([HomeWebView.touchHook], main thread) - only WATCHED, never taken: the
     * window's frame (bar, buttons, edges, tile menu, dividers) is DOM, and the page's own hit test decides what a press
     * is on, so a menu, a popover or another window's bar over a window gets its touches by DOM order alone. The gesture
     * is kept so that a Linux window the page says was pressed ([forward] "down") gets the WHOLE gesture natively from
     * its first event, every pointer (Z4) - not the page's single pointer.
     */
    private var gesture: MotionEvent? = null

    /** The Linux window the current gesture belongs to (the page pressed its body), else null. */
    private var linuxTouch: Win? = null

    /** The KWin window that last got "focus" from a touch here: told again only when another one is touched. */
    private var linuxFocused = -1

    private fun onTouch(ev: MotionEvent): Boolean {
        val a = ev.actionMasked
        imeGesture(a)
        if (a == MotionEvent.ACTION_DOWN) {
            gesture?.recycle()
            gesture = MotionEvent.obtain(ev)
            linuxTouch = null
            fullEdge = null
            // A full-screen Linux window's top / bottom edge strip stays home's (FL2): the status bar's pull-down and
            // the home gesture reach the page, and pulling in from there leaves full screen.
            fullEdgeAt(ev)?.let { e ->
                fullEdge = e
                return false
            }
        }
        fullEdge?.let { e ->
            edgePull(e, ev)
            return false
        }
        // A full-screen Linux window is over all of home (nothing of the page is on screen): every other touch is its.
        fullLinux()?.let { return linuxInput(it, ev) }
        linuxTouch?.let { linuxInput(it, ev) }
        if (a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_CANCEL) {
            gesture?.recycle()
            gesture = null
        }
        return false
    }

    /** A gesture begun in a full-screen Linux window's edge strip ([fullEdgeAt]): its window, start and side (-1 top, 1 bottom). */
    private class FullEdge(
        val id: Int,
        val y0: Float,
        val side: Int,
    )

    private var fullEdge: FullEdge? = null

    /** [ev]'s first finger's y in home's window px. */
    private fun yOf(ev: MotionEvent): Float = ev.getY(0) + IntArray(2).also(web::getLocationInWindow)[1]

    /** [ev]'s first finger in the edge strip of the full-screen Linux window, if one is full screen; else null. */
    private fun fullEdgeAt(ev: MotionEvent): FullEdge? {
        val w = fullLinux() ?: return null
        val y = yOf(ev)
        val h = context.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds.height()
        val insets = web.rootWindowInsets
        val min = (EDGE_STRIP_DP * density()).toInt()
        val top = maxOf(min, insets?.getInsets(android.view.WindowInsets.Type.statusBars())?.top ?: 0)
        val bottom = maxOf(min, insets?.getInsets(android.view.WindowInsets.Type.systemGestures())?.bottom ?: 0)
        val side = fullScreenEdge(y, h, top, bottom)
        return if (side == 0) null else FullEdge(w.id, y, side)
    }

    /** A pull in from [e]'s edge, past [EDGE_PULL_DP]: the window leaves full screen ([toWindow]). */
    private fun edgePull(
        e: FullEdge,
        ev: MotionEvent,
    ) {
        when (ev.actionMasked) {
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> fullEdge = null
            MotionEvent.ACTION_MOVE -> {
                val dy = yOf(ev) - e.y0
                if (dy * -e.side > EDGE_PULL_DP * density()) {
                    fullEdge = null
                    Log.i(TAG, "window ${e.id}: ${if (e.side < 0) "top" else "bottom"} edge pull: leaves full screen")
                    toWindow(e.id)
                }
            }
        }
    }

    /**
     * Home or Back with a full-screen Linux window (FL3: no app state leaves the user without a way home): it leaves
     * full screen, back in its window. True: one did (ShellActivity's Back then stops there).
     */
    fun leaveFullScreen(why: String): Boolean {
        val w = wins.values.firstOrNull { it.linuxFull } ?: return false
        Log.i(TAG, "window ${w.id}: $why: leaves full screen")
        return toWindow(w.id)
    }

    /** The full-screen Linux window, unless the switcher is up, else null. */
    private fun fullLinux(): Win? = if (underSwitcher) null else wins.values.firstOrNull { it.linuxFull && it.linux != null }

    /**
     * The page pressed [win]'s body ("webwindows.input" "down"): the gesture is the Linux window's from here, its DOWN
     * replayed from [gesture] (the page's answer comes after the WebView saw it).
     * HACK: the moves between the DOWN and the page's answer (one frame, ~8 ms) are not replayed - KWin sees the first
     * move after them as a small jump. Real fix: the page's hit regions on the host side (S4), deciding at the DOWN.
     */
    private fun linuxClaim(win: Win) {
        val src = win.linux ?: return
        linuxTouch = win
        if (linuxFocused != src.kwin) {
            linuxFocused = src.kwin
            andro.marchy.WebWindowSource.focus(src.kwin)
        }
        val g = win.geo
        Log.i(TAG, "window ${win.id}: gesture to KWin window ${src.kwin}${g?.let { " (body ${it.body.toShortString()} x${it.scale})" } ?: ""}${if (src.handle == 0L) ": its consumer isn't up, dropped" else ""}")
        gesture?.let { linuxInput(win, it) }
    }

    /** [ev] to [win]'s KWin window in its body's own px (the body's place and scale on screen, as the page measured it). */
    private fun linuxInput(
        win: Win,
        ev: MotionEvent,
    ): Boolean {
        val a = ev.actionMasked
        if (a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_CANCEL) linuxTouch = null
        val src = win.linux ?: return true
        val at = IntArray(2).also(web::getLocationInWindow)
        if (win.linuxFull) {
            // Full screen: the window is at the screen's top left, 1:1.
            andro.marchy.WebWindowSource.touch(src.handle, ev, at[0].toFloat(), at[1].toFloat(), 1f)
            return true
        }
        val g = win.geo ?: return true
        andro.marchy.WebWindowSource.touch(src.handle, ev, at[0] - g.body.left.toFloat(), at[1] - g.body.top.toFloat(), g.scale)
        return true
    }

    /**
     * The window's app's content shows (the placeholder can go, the manager's LW1): "webwindows.live" to the page once.
     * HACK: there is no "first frame drawn" signal for a mirrored display; a task on it plus [LIVE_AFTER_MS] stands in
     * (Linux: the consumer up plus that). Real fix: a frame callback on the mirror's first buffer (S8).
     */
    private fun liveWhenDrawn(
        w: Win,
        since: Long = SystemClock.uptimeMillis(),
    ) {
        if (w.closed || w.live) return
        val landed = w.linux != null || (tasksOn(w.displayId) ?: 0) > 0
        if (landed || SystemClock.uptimeMillis() - since > ESCAPE_CHECK_MS) io.postDelayed({ main.post { goLive(w) } }, LIVE_AFTER_MS)
        else io.postDelayed({ liveWhenDrawn(w, since) }, 100)
    }

    /** Main thread: [liveWhenDrawn]'s "webwindows.live", once. */
    private fun goLive(w: Win) {
        if (w.closed || w.live) return
        w.live = true
        Log.i(TAG, "window ${w.id}: live (its content shows; the page drops the placeholder)")
        emit("webwindows.live", w.id)
    }

    // ---- input (v0, until S4) ------------------------------------------------------------------------------------------

    /**
     * A touch on the element's body (CSS px from its top-left, unscaled), the page's DOM hit test having said it is the
     * window's - the ONE call site both sources go through ([forward]).
     */
    fun input(
        id: Int,
        action: String,
        x: Double,
        y: Double,
    ): Boolean {
        val w = wins[id] ?: return false
        return forward(w, action, x, y)
    }

    /**
     * A body touch to [w]'s app: Linux - a DOWN claims the native gesture for KWin ([linuxClaim]; its moves and UP
     * come from the gesture itself, every pointer); Android - injected on its display (v0; S4: the injector). Both
     * focus their window: KWin's "focus", or the injected touch moving the top focused display to the window's.
     */
    private fun forward(
        w: Win,
        action: String,
        x: Double,
        y: Double,
    ): Boolean {
        if (w.linux != null) {
            if (action == "down") linuxClaim(w)
            return true
        }
        if (w.displayId < 0) return false
        val act = ACTIONS[action] ?: MotionEvent.ACTION_CANCEL
        val now = SystemClock.uptimeMillis()
        if (act == MotionEvent.ACTION_DOWN) {
            w.downAt = now
            androidGesture = true
            main.post { homeIme(false) }
        }
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

    // ---- the keyboard (K2) ---------------------------------------------------------------------------------------------

    /** The current gesture pressed an Android window's body ([forward] "down"); reset at each DOWN on home. */
    @Volatile private var androidGesture = false

    /** Home's window is the IME target (no FLAG_ALT_FOCUSABLE_IM): what [homeIme] last set. */
    private var homeImeOn = true

    /**
     * Every touch on home ([onTouch]): a gesture that was not an Android window's body (home's own UI, a title bar, a
     * Linux body) gives home the keyboard back at its UP. Posted: the page's "down" for this gesture (bridge thread) is
     * in long before its UP.
     */
    private fun imeGesture(action: Int) {
        if (action == MotionEvent.ACTION_DOWN) androidGesture = false
        if (action == MotionEvent.ACTION_UP) main.post { if (!androidGesture) homeIme(true) }
    }

    /**
     * On main: home's window may (true) or may not (false) take the keyboard. Off from a press on an Android window's
     * body until a gesture on home that is not one, so the app keeps the keyboard and its input connection.
     * Why (measured 2026-10-30 20:46, Discord on trusted display 90, dumpsys input_method): Discord's showSoftInput
     * reached the IME (mSoftInputShowHideHistory SHOW_SOFT_INPUT focused/request = Discord) and failed ("TYPE_SHOW -
     * STATUS_FAIL - com.discord ... PHASE_SERVER_UPDATE_CLIENT_VISIBILITY"), because 2 ms later home's WebView took the
     * IME client back ("StartInput #1210 20:46:00.366 reason=CHECK_FOCUS targetWin=[com.powos.app] targetDisplayId=0")
     * - the real finger is on home's window, which keeps display 0's focus (both displays hold a focused window here).
     * From then on mCurClient / mCurFocusedWindow = HomeShell, the IME's insets control target on display 0 = HomeShell
     * (which asks for no keyboard): none shows, and any later home touch hid it again. With ALT_FOCUSABLE_IM home's
     * window can't be an IME target, so the app's request stands and the keyboard (DISPLAY_IME_POLICY_FALLBACK_DISPLAY,
     * [imePolicy]) shows on display 0 over home; touches on the keyboard go to the IME window, never through home.
     * HACK: a window flag toggled from touches. Real fix: the S4 injector's process takes the real touch for bodies
     * (home never sees it, so never takes the focus or the IME), or the page tells the host which element owns the IME.
     */
    private fun homeIme(on: Boolean) {
        if (on == homeImeOn) return
        val window = activityOf(web.context)?.window ?: return
        homeImeOn = on
        if (on) window.clearFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM) else window.addFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
        Log.i(TAG, "home's window ${if (on) "takes the keyboard again" else "leaves the keyboard to the web window's app"}")
    }

    private fun activityOf(c: Context): android.app.Activity? {
        var x: Context? = c
        while (x != null) {
            if (x is android.app.Activity) return x
            x = (x as? android.content.ContextWrapper)?.baseContext
        }
        return null
    }

    // ---- closing -------------------------------------------------------------------------------------------------------

    /** Gone: its tasks removed, its display released, "webwindows.closed" for the page. */
    fun close(id: Int): Boolean {
        val w = wins[id] ?: return false
        drop(w)
        return true
    }

    fun closeAll() {
        if (current === this) current = null
        (web as? HomeWebView)?.touchHook = null
        homeIme(true)
        gesture?.recycle()
        gesture = null
        // Linux windows keep running as their own tasks (home's page is going: nothing would show them); Android ones
        // close with their displays as before.
        wins.values.toList().forEach { drop(it, handBack = it.linux != null) }
        pendingLinux.keys.toList().forEach { kwin -> pendingLinux.remove(kwin)?.let { andro.marchy.WebWindowSource.fallback(context, kwin, it.appId, it.title) } }
        runCatching { dm.unregisterDisplayListener(displayListener) }
        main.removeCallbacks(reconcileRun)
        stopTasks?.invoke()
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
        handBack: Boolean = false,
    ) {
        if (wins.remove(w.id) == null) return
        w.closed = true
        dropLinux(w, handBack)
        Log.i(TAG, "close window ${w.id} (${w.component.packageName}, display ${w.displayId}, task ${w.taskId}${if (w.full) ", full screen" else ""}): 1/4 layers off")
        releaseLayers(w)
        main.post { publishBars() }
        val displayId = w.displayId
        WebWindowDisplays.remove(displayId)
        WebWindowDisplays.windowGone(w.id)
        // A full-screen app out of this window (its task on display 0 now): it goes with the window.
        val fullTask = w.taskId.takeIf { w.full && it >= 0 }
        if (fullTask != null) io.post { removeTask(fullTask, "full screen app of window ${w.id}") }
        if (displayId >= 0 && !released) {
            io.post {
                // DESTROY_CONTENT_ON_REMOVAL finishes the activities but leaves the task in recents (S0): removed first.
                removeTasks(displayId)
                Log.i(TAG, "close window ${w.id}: 3/4 display $displayId released")
                helper.release(displayId)
            }
        }
        Log.i(TAG, "close window ${w.id}: 2/4 layers gone (container, mirror), page told (webwindows.closed) - 4/4")
        emit("webwindows.closed", w.id)
    }

    /** [w]'s layers (mirror, frame, container) off the screen in one transaction, then released. */
    private fun releaseLayers(w: Win) {
        val t = SurfaceControl.Transaction()
        w.mirror?.let { if (it.isValid) t.reparent(it, null) }
        if (w.container.isValid) t.reparent(w.container, null)
        t.apply()
        w.mirror?.release()
        w.container.release()
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

    private fun removeTask(
        id: Int,
        why: String,
    ) {
        val ok = runCatching { atm().javaClass.getMethod("removeTask", Int::class.javaPrimitiveType).invoke(atm(), id) as Boolean }.getOrDefault(false)
        Log.i(TAG, "task $id removed=$ok ($why)")
    }

    // ---- full screen app, and back to a window ------------------------------------------------------------------------

    /**
     * The bar's full screen button (the manager's rule, 10-29): [win]'s app becomes a real FULL-SCREEN APP - its task
     * moved off its display to display 0, full screen and in front: home gestures, its own switcher card, never a big
     * floating window. The window stays in the page's model, hidden ("webwindows.full" on), with its display (empty
     * meanwhile) and its frame: [toWindow] puts the app back there. On [io]: binder calls.
     */
    private fun fullScreen(win: Win) {
        val src = win.linux
        if (src != null) {
            if (!andro.marchy.WebWindowSource.canFullScreen()) {
                // A KWin before 0043 can't be asked for its F11, but the button is still FULL SCREEN, never the work
                // area's maximise (the user, 10-30 20:15: "When I press maximise, I still mean full screen"; Dolphin
                // under the old KWin got "the work area's maximise"): PowOS puts it over the whole screen itself, no
                // bar, KWin's window at the screen's size. Pinned by WebWindowsBarTest.
                Log.i(TAG, "window ${win.id}: KWin takes no full-screen request: full screen by PowOS alone")
                linuxFullScreen(win, true)
                return
            }
            // KWin puts the window itself full screen (its F11); shown so at once, KWin's "fullscreen <id> 1|0" confirms.
            Log.i(TAG, "window ${win.id}: KWin window ${src.kwin} full screen asked")
            andro.marchy.WebWindowSource.fullScreen(src.kwin, true)
            linuxFullScreen(win, true)
            return
        }
        if (win.displayId < 0 || win.full) return
        // Hidden at once (the page drops it from "w.f" a frame later), as minimise.
        if (win.container.isValid) SurfaceControl.Transaction().setVisibility(win.container, false).apply()
        win.shown = false
        io.post { fullScreenNow(win) }
    }

    /** On [io]: [fullScreen]'s move. */
    private fun fullScreenNow(win: Win) {
        val task = taskOn(win.displayId)
        if (task == null) {
            Log.w(TAG, "window ${win.id}: no task on display ${win.displayId} to make full screen")
            announce(win, false)
            return
        }
        win.taskId = task
        // Known as a full-screen web window BEFORE it lands on display 0: the old path's adopt must never float it.
        WebWindowDisplays.fullScreen(task, win.id, true)
        val ok = moveTask(task, android.view.Display.DEFAULT_DISPLAY)
        if (!ok) WebWindowDisplays.fullScreen(task, win.id, false)
        Log.i(TAG, "window ${win.id}: ${if (ok) "its app (task $task) is a full-screen app on display 0" else "full screen FAILED (task $task stays on display ${win.displayId})"}")
        announce(win, ok)
    }

    /** On the main thread: [win] is a full-screen app ([full]) or a window again - "webwindows.full" to the page. */
    private fun announce(
        win: Win,
        full: Boolean,
    ) = main.post {
        if (win.closed) return@post
        win.full = full
        emit("webwindows.full", mapOf("id" to win.id, "on" to full, "task" to win.taskId))
    }

    /**
     * Linux window [win] full screen ([on]: the container over the whole screen above the other windows, no bar, every
     * touch its; "webwindows.full" lets the page keep its place) or back in its window (the page's next frame places it
     * and KWin's window takes the body's size again). Main thread.
     */
    private fun linuxFullScreen(
        win: Win,
        on: Boolean,
    ) {
        val src = win.linux ?: return
        if (win.closed || win.linuxFull == on) return
        win.linuxFull = on
        // Covers every web window now: a new window of its app opens as a task in front of it (WindowTasks.open).
        andro.marchy.WebWindowSource.shownFullScreen(src.kwin, on)
        val t = SurfaceControl.Transaction()
        if (on) {
            fillScreen(t, win, src)
        } else {
            // Back under home's surface among the page's windows: the page's next frame places it.
            root?.takeIf { it.isValid && win.container.isValid }?.let { t.reparent(win.container, it) }
            t.apply()
        }
        Log.i(TAG, "window ${win.id}: KWin window ${src.kwin} ${if (on) "full screen" else "back in its window"}")
        win.full = on
        emit("webwindows.full", mapOf("id" to win.id, "on" to on))
        publishBars()
    }

    /** [linuxFullScreen]'s on: [win]'s layers over the whole screen at 1:1, KWin's window at the screen's size. */
    private fun fillScreen(
        t: SurfaceControl.Transaction,
        win: Win,
        src: LinuxSource,
    ) {
        if (linuxTouch !== win) linuxTouch = null
        val b = context.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds
        val screen = Rect(0, 0, b.width(), b.height())
        win.container.takeIf { it.isValid }?.let { c ->
            // Full screen is not an element of the page: ABOVE home's buffer (a child of home's surface itself, as the
            // windows' root is), so nothing of the page paints over it; the root's own layer is -1, under home.
            // HACK: home's surface recreated while it is full screen leaves it on the old surface ([reattach] moves only
            // the root); real fix: a second root above home's buffer, re-attached the same way.
            web.rootSurfaceControl?.buildReparentTransaction(c)?.let { t.merge(it) }
            t.setPosition(c, 0f, 0f).setScale(c, 1f, 1f).setCrop(c, screen).setLayer(c, FULL_LAYER).setVisibility(c, true)
            cornerRadius(t, c, 0f)
        }
        src.content.takeIf { it.isValid }?.let { m -> t.setPosition(m, 0f, 0f).setScale(m, 1f, 1f).setCrop(m, screen) }
        t.apply()
        win.shown = true
        linuxResize(win, src, b.width(), b.height())
    }

    /** KWin's "fullscreen <kwin> 1|0" (ShellBridge's host, main thread): the window went full screen or left it. */
    fun linuxFullScreen(
        kwin: Int,
        on: Boolean,
    ) {
        val w = wins.values.firstOrNull { it.linux?.kwin == kwin } ?: return
        linuxFullScreen(w, on)
    }

    /** The page's "webwindows.fullScreen": window [id]'s app full screen ([fullScreen]); false: no such window. */
    fun fullScreen(id: Int): Boolean {
        val w = wins[id] ?: return false
        if (w.linuxFull) return true
        if (w.full) return front(id)
        fullScreen(w)
        return true
    }

    /**
     * Window [id]'s full-screen app back into its window (the switcher card's "Back to window"): its task moved back to
     * the window's display, the window shown where it was ("webwindows.full" off: the page shows it on its page).
     */
    fun toWindow(id: Int): Boolean {
        val w = wins[id] ?: return false
        w.linux?.let { src ->
            // A full-screen Linux window: KWin takes it out of full screen (its "fullscreen 0" confirms), shown back now.
            if (w.linuxFull && andro.marchy.WebWindowSource.canFullScreen()) andro.marchy.WebWindowSource.fullScreen(src.kwin, false)
            if (w.linuxFull) linuxFullScreen(w, false) else emit("webwindows.full", mapOf("id" to w.id, "on" to false))
            return true
        }
        if (!w.full) return true.also { emit("webwindows.full", mapOf("id" to w.id, "on" to false)) }
        io.post { toWindowNow(w) }
        return true
    }

    /** On [io]: [toWindow]'s move. */
    private fun toWindowNow(w: Win) {
        val task = w.taskId
        // Still running: moved back. Gone meanwhile (its app finished): the app launched on its display afresh.
        val alive = taskDisplay(task) != null
        val ok = if (alive) moveTask(task, w.displayId) else true.also { main.post { if (!w.closed) launch(w) } }
        Log.i(TAG, "window ${w.id}: back to a window (task $task ${if (alive) "moved back to display ${w.displayId}: $ok" else "gone: launched again"})")
        if (!ok) return
        WebWindowDisplays.fullScreen(task, w.id, false)
        announce(w, false)
    }

    /** Window [id]'s full-screen app to the front again (a dock tap on it): back on display 0, full screen. */
    private fun front(id: Int): Boolean {
        val w = wins[id] ?: return false
        io.post {
            if (taskDisplay(w.taskId) == null) {
                Log.i(TAG, "window ${w.id}: its full-screen app (task ${w.taskId}) is gone: back to its window")
                main.post { toWindow(id) }
                return@post
            }
            moveTask(w.taskId, android.view.Display.DEFAULT_DISPLAY)
        }
        return true
    }

    /** The window (its id) task [taskId] belongs to while it's a full-screen app out of one ([fullScreen]), or null. */
    fun windowOfFullTask(taskId: Int): Int? = wins.values.firstOrNull { it.full && it.taskId == taskId }?.id

    /** The app's task on [displayId] (its first root task's top leaf), or null. */
    private fun taskOn(displayId: Int): Int? =
        runCatching {
            val roots = atm().javaClass.getMethod("getAllRootTaskInfosOnDisplay", Int::class.javaPrimitiveType).invoke(atm(), displayId) as List<*>
            roots.filterNotNull().firstNotNullOfOrNull { r ->
                val children = runCatching { r.javaClass.getField("childTaskIds").get(r) as IntArray }.getOrNull()
                children?.firstOrNull() ?: android.app.TaskInfo::class.java.getField("taskId").getInt(r)
            }
        }.onFailure { Log.w(TAG, "display $displayId: its tasks unreadable", it) }.getOrNull()

    /** The display task [taskId] runs on, or null (not running). */
    private fun taskDisplay(taskId: Int): Int? {
        if (taskId < 0) return null
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(android.app.ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        return tasks.firstOrNull { it.taskId == taskId }?.let { WebWindowDisplays.displayOf(it) }
    }

    /**
     * Task [taskId] onto display [displayId], full screen and in front: IActivityTaskManager.moveRootTaskToDisplay
     * (MANAGE_ACTIVITY_TASKS, held as the recents provider), then startActivityFromRecents with that display and
     * WINDOWING_MODE_FULLSCREEN (START_TASKS_FROM_RECENTS: in front, focused, its windowing mode set). Still elsewhere:
     * root `cmd activity display move-stack` (shell's own path to the same call). True once the task is there.
     * HACK: the task calls and ActivityOptions.setLaunchWindowingMode are hidden, reflected ([HiddenApi]); root is the
     * last resort. Real fix: none public for an app (a platform-signed system module would call WM directly).
     */
    private fun moveTask(
        taskId: Int,
        displayId: Int,
    ): Boolean {
        HiddenApi.allow()
        val moved =
            runCatching { atm().javaClass.getMethod("moveRootTaskToDisplay", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).invoke(atm(), taskId, displayId) }
                .onFailure { Log.w(TAG, "moveRootTaskToDisplay($taskId, $displayId) refused: ${it.cause ?: it}") }.isSuccess
        val started = fromRecents(taskId, displayId)
        var now = taskDisplay(taskId)
        if (now != displayId) {
            val r = runCatching { andro.marchy.RootShell.run("cmd activity display move-stack $taskId $displayId") }.getOrNull()
            Log.w(TAG, "task $taskId still on display $now: root move-stack -> code ${r?.code} ${r?.output?.take(160)}")
            fromRecents(taskId, displayId)
            now = taskDisplay(taskId)
        }
        Log.i(TAG, "task $taskId to display $displayId: moveRootTaskToDisplay=$moved startActivityFromRecents=$started, now on display $now")
        return now == displayId
    }

    /** startActivityFromRecents([taskId]) on [displayId], full screen: its result >= 0. */
    private fun fromRecents(
        taskId: Int,
        displayId: Int,
    ): Boolean {
        val opts = ActivityOptions.makeBasic().setLaunchDisplayId(displayId)
        runCatching { ActivityOptions::class.java.getMethod("setLaunchWindowingMode", Int::class.javaPrimitiveType).invoke(opts, WINDOWING_MODE_FULLSCREEN) }
        return runCatching {
            (atm().javaClass.getMethod("startActivityFromRecents", Int::class.javaPrimitiveType, android.os.Bundle::class.java).invoke(atm(), taskId, opts.toBundle()) as Int) >= 0
        }.onFailure { Log.w(TAG, "startActivityFromRecents($taskId) on display $displayId refused: ${it.cause ?: it}") }.getOrDefault(false)
    }

    private fun atm(): Any = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!

    // ---- the switcher's card picture ------------------------------------------------------------------------------------

    /**
     * Window [windowId]'s content now (its display's mirror, captured: what the window shows), as a bitmap, or null.
     * The switcher's card for a web window when the system has no task snapshot of it (a task on a display that never
     * leaves the screen is never snapshotted on its own; ShellHost asks takeTaskSnapshot first). HACK: ScreenCapture is
     * hidden, reflected. Real fix: none for an app.
     */
    fun contentShot(windowId: Int): android.graphics.Bitmap? {
        val w = wins[windowId] ?: return null
        val m = w.mirror?.takeIf { it.isValid } ?: return null
        return runCatching {
            HiddenApi.allow()
            val sc = Class.forName("android.window.ScreenCapture")
            val builder = Class.forName("android.window.ScreenCapture\$LayerCaptureArgs\$Builder").getConstructor(SurfaceControl::class.java).newInstance(m)
            builder.javaClass.getMethod("setSourceCrop", Rect::class.java).invoke(builder, Rect(0, 0, w.w, w.h))
            val args = builder.javaClass.getMethod("build").invoke(builder)
            val shot = sc.getMethod("captureLayers", args.javaClass).invoke(null, args) ?: return null
            val hw = shot.javaClass.getMethod("asBitmap").invoke(shot) as android.graphics.Bitmap? ?: return null
            hw.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
        }.onFailure { Log.w(TAG, "window $windowId: its content not captured", it) }.getOrNull()
    }

    // ---- launch, IME -----------------------------------------------------------------------------------------------------

    /**
     * Why [component] can't be a web window (a tile resizes it at will), or null. An activity declaring
     * resizeableActivity=false and targeting below SDK 36 (Android 16 ignores the flag on large screens for 36+) would
     * run letterboxed in size-compat on the display: Android's own window and split handle it better.
     * HACK: ActivityInfo.resizeMode is hidden (reflected). Real fix: none public (isResizeableActivity is the hidden
     * twin).
     */
    private fun unresizeable(component: ComponentName): String? =
        runCatching {
            HiddenApi.allow()
            val info = context.packageManager.getActivityInfo(component, 0)
            val mode = android.content.pm.ActivityInfo::class.java.getField("resizeMode").getInt(info)
            val target = info.applicationInfo.targetSdkVersion
            if (mode == RESIZE_MODE_UNRESIZEABLE && target < 36) "not resizeable (resizeMode 0, targetSdk $target)" else null
        }.getOrNull()

    /**
     * After the launch: the app must have a task on the window's display. None after [ESCAPE_CHECK_MS] (it refused the
     * display, or its launch went to the default display): the window goes and the app opens as Android's own window
     * (fallback, logged).
     */
    private fun checkLanded(w: Win) {
        io.postDelayed({
            if (w.closed) return@postDelayed
            val n = tasksOn(w.displayId)
            if (n != null && n > 0) w.landed = true
            if (n == null || n > 0) return@postDelayed
            Log.w(TAG, "fallback: ${w.component.packageName} has no task on display ${w.displayId} ${ESCAPE_CHECK_MS} ms after its launch: Android's own window instead of web window ${w.id}")
            main.post {
                drop(w)
                runCatching {
                    context.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setComponent(w.component).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }.onFailure { Log.w(TAG, "fallback launch of ${w.component.packageName} failed", it) }
            }
        }, ESCAPE_CHECK_MS)
    }

    /** How many root tasks [displayId] has, or null (unknown: no fallback on a guess). */
    private fun tasksOn(displayId: Int): Int? =
        runCatching {
            HiddenApi.allow()
            val atm = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
            (atm.javaClass.getMethod("getAllRootTaskInfosOnDisplay", Int::class.javaPrimitiveType).invoke(atm, displayId) as List<*>).size
        }.getOrNull()

    private fun launch(w: Win) {
        w.landed = false
        checkLanded(w)
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

        /** A task change's [reconcile] waits this long, and an empty display is read again this long after. */
        private const val RECONCILE_MS = 400L

        /**
         * [reconcile]'s rule: an Android window is an orphan (its frame closes) when its display is known empty
         * ([tasks] == 0) after it had its app ([landed]) - not while launching (checkLanded's), nor while [held]: adopting
         * a task, or a full-screen app out of it (also marked before its move to display 0). [tasks] null: unreadable,
         * never a close on a guess.
         */
        fun orphaned(
            closed: Boolean,
            landed: Boolean,
            held: Boolean,
            tasks: Int?,
        ): Boolean = !closed && landed && !held && tasks == 0

        /** A Linux web window's switcher card id: this + its window id (no Android task id gets near it). */
        const val LINUX_CARD = 1 shl 29

        /** A full-screen Linux window's layer among the windows ([linuxFullScreen]): above every page-ordered one. */
        private const val FULL_LAYER = 1 shl 20

        /** A full-screen Linux window's edge strips stay home's at least this tall (dp): the status bar, the home gesture. */
        private const val EDGE_STRIP_DP = 24

        /** How far in from an edge strip (dp) a pull leaves full screen. */
        private const val EDGE_PULL_DP = 24

        /** Which edge strip [y] is in on an [h] px tall screen: -1 the top ([top] px), 1 the bottom ([bottom] px), 0 neither. */
        fun fullScreenEdge(
            y: Float,
            h: Int,
            top: Int,
            bottom: Int,
        ): Int =
            when {
                y < top -> -1
                y >= h - bottom -> 1
                else -> 0
            }

        /** [shot] as a card's JPEG, at most [width] px wide. */
        private fun jpeg(
            shot: android.graphics.Bitmap,
            width: Int,
        ): ByteArray {
            val scaled = if (shot.width > width) android.graphics.Bitmap.createScaledBitmap(shot, width, shot.height * width / shot.width, true) else shot
            return java.io.ByteArrayOutputStream().also { scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 82, it) }.toByteArray()
        }

        /** The Linux web window card [taskId] stands for ([linuxCards]), or null for a real task. */
        private fun linuxCardWindow(taskId: Int): Int? = (taskId - LINUX_CARD).takeIf { taskId >= LINUX_CARD }
        const val SETTING = "powos_web_windows"

        /** Home's web windows (the one home page's), or null: what [closeForTask] closes through. */
        @Volatile private var current: WebWindows? = null

        /**
         * The switcher up ([open]) or down (Switcher.open's setter). It is home's own page, and the windows are a layer
         * of home ABOVE its page: up, they covered the switcher - the live window at full size, its bar over the cards
         * (the user, 10-30 18:39: "They still show up wrong in the switcher. When they are like floating."). So the
         * windows' root is hidden while it's up (each window then is its card: its content as a picture, ShellHost
         * /_task via [cardShot]) and shown again after; a card tapped shows its window where it was.
         */
        fun switcherOpen(open: Boolean) {
            val ww = current ?: return
            ww.main.post { ww.rootShown(!open) }
        }

        /**
         * THE close of a web window for a task (Tasks.remove: the switcher's swipe away, "Clear all", any task removal
         * PowOS makes): when task [taskId] is a web window's - on its display, or a full-screen app out of one - that
         * window is closed exactly as its bar's close does ([close] -> [drop]: its layers off at once in one transaction,
         * its tasks removed, its display released, the page told). True: it was one (the caller does nothing more).
         * Before (2026-10-30 18:30, the user: "I try to close it while the switcher but it just left me with this
         * gray"): the switcher removed only the task; the window, its frame's background and its empty display stayed.
         */
        fun closeForTask(
            context: Context,
            taskId: Int,
        ): Boolean {
            val ww = current ?: return false
            linuxCardWindow(taskId)?.let { id ->
                Log.i(TAG, "card $taskId removed (switcher / Tasks.remove): Linux web window $id - closing it (the bar's close path)")
                ww.main.post { ww.close(id) }
                return true
            }
            val id = WebWindowDisplays.windowOf(context, taskId) ?: return false
            Log.i(TAG, "task $taskId removed (switcher / Tasks.remove): it is web window $id - closing the window (the bar's close path)")
            ww.main.post { ww.close(id) }
            return true
        }

        /**
         * Task [taskId]'s switcher card tapped: a web window's floating window comes back where it was - shown,
         * on top, home on its page ("webwindows.show" to home's page) - never startActivityFromRecents (that would pull
         * the task off its display). Its full-screen app: false, the caller opens it as any full-screen task. True: done.
         */
        fun openForTask(
            context: Context,
            taskId: Int,
        ): Boolean {
            val ww = current ?: return false
            linuxCardWindow(taskId)?.let { id ->
                Log.i(TAG, "card $taskId opened from the switcher: Linux web window $id shown where it was, on its page")
                ww.main.post { ww.emit("webwindows.show", id) }
                return true
            }
            if (WebWindowDisplays.fullScreenWindow(taskId) != null) return false
            val id = WebWindowDisplays.windowOf(context, taskId) ?: return false
            Log.i(TAG, "task $taskId opened from the switcher: web window $id shown where it was, on its page")
            ww.main.post { ww.emit("webwindows.show", id) }
            return true
        }

        /** Task [taskId], a web window's full-screen app, back into its window (its card's "Back to window"). */
        fun toWindowForTask(taskId: Int): Boolean {
            val ww = current ?: return false
            val id = WebWindowDisplays.fullScreenWindow(taskId) ?: return false
            ww.main.post { ww.toWindow(id) }
            return true
        }

        /**
         * Task [taskId]'s picture for its switcher card when it's a web window on its display: takeTaskSnapshot now
         * (the system never snapshots a task on a display that stays on), else its window's content captured from
         * the mirror. JPEG, at most [width] px wide; null: not a web window, or no picture.
         */
        fun cardShot(
            context: Context,
            taskId: Int,
            width: Int = 720,
        ): ByteArray? {
            val ww = current ?: return null
            linuxCardWindow(taskId)?.let { return ww.contentShot(it)?.let { shot -> jpeg(shot, width) } }
            val id = WebWindowDisplays.windowOf(context, taskId) ?: return null
            if (WebWindowDisplays.fullScreenWindow(taskId) != null) return null
            dev.omalauncher.system.Tasks.capture(taskId)
            dev.omalauncher.system.Tasks.snapshot(taskId, width)?.let { return it }
            val shot = ww.contentShot(id) ?: return null.also { Log.w(TAG, "task $taskId (window $id): no picture for its card") }
            Log.i(TAG, "task $taskId (window $id): card picture from its mirror (no task snapshot)")
            return jpeg(shot, width)
        }

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

        /** Web windows on: Android apps opened from the wide home are web windows (only those stand the old path down: WebWindowDisplays). */
        fun on(context: Context): Boolean = runCatching { Settings.Global.getInt(context.contentResolver, SETTING, 0) == 1 }.getOrDefault(false)
        private const val PLACE_LOG_MS = 1000L
        /** After a task lands on a window's display (or a Linux consumer starts): its first frame is taken as drawn. */
        private const val LIVE_AFTER_MS = 250L

        /** A scale below this in "w.f" is a bad one (an element measured mid-mount): taken as 1. */
        private const val MIN_ZOOM = 0.05f
        private const val MIRROR_WAIT_MS = 2000L

        /** A KWin window offered to the page ([linuxOpened]) and not taken by then opens as its own task. */
        private const val LINUX_ADOPT_MS = 3000L
        private const val ESCAPE_CHECK_MS = 3000L
        private const val RESIZE_MODE_UNRESIZEABLE = 0
        private const val IME_POLICY_FALLBACK_DISPLAY = 1
        private const val WINDOWING_MODE_FULLSCREEN = 1
        private const val MAX_TASKS = 64
        private val ACTIONS = mapOf("down" to MotionEvent.ACTION_DOWN, "move" to MotionEvent.ACTION_MOVE, "up" to MotionEvent.ACTION_UP)
        private val VERBS = mapOf(MotionEvent.ACTION_DOWN to "DOWN", MotionEvent.ACTION_MOVE to "MOVE", MotionEvent.ACTION_UP to "UP")
    }
}
