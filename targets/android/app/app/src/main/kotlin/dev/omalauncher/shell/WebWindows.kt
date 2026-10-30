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
 *   home's own window surface (AttachedSurfaceControl.buildReparentTransaction) ABOVE home's buffer (layer 1): a window
 *   is a card on home, nothing of home is cut or altered under it (the user, 2026-10-30: "nobody asked for the
 *   cutoff"; windows "f*** up the transparency of the widgets"). Every other window (launcher overlay, shade, PowOS AI,
 *   status bar, IME) is above home's whole layer tree, so above the web windows too. In the container: the native
 *   frame ([WebWindowChrome]: background -1, title bar 1) and the mirror (0) under the bar. The container is cropped to
 *   the frame and to the work area ("w.area": never over the dock and bar) with its corner radius; z-order = the
 *   page's order (setLayer). The page's DOM for a window is invisible: its model, gesture exclusions and body touches.
 * - Geometry: the page sends "w.f <frame> ..." over its native port every frame a window's rect, visibility, order or
 *   scale changed; it goes on the draw that shows that page frame ([FrameSync], the glass's binding), so a page swipe
 *   moves the windows with their page. A window off its page, minimised or out of sight: its layer hidden, never
 *   its display's surface (that would STOP the app within ~40 ms, S0). A new body size resizes the display
 *   (VirtualDisplay.resize in the helper): the app lays out at its real pixel size.
 * - The frame's touches (bar, edges, buttons, two fingers) are the host's from their first event ([onTouch]): moves,
 *   resizes and zooms follow the finger every input frame, one transaction each, as Android's freeform drag.
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

    /** PowOS's own split screen: dividers, the snap hint, the tile menu ([WebWindowTiles]; docs "Tiles"). */
    private val tiles = WebWindowTiles(context, { root?.takeIf { it.isValid } }) { t, sc, r -> cornerRadius(t, sc, r) }
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
        current = this
        runCatching { dm.registerDisplayListener(displayListener, main) }
        // Every touch on home first (Z2): a title-bar move the page handed over is the host's from then on.
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

        /** Its native frame and title bar ([WebWindowChrome]). */
        var chrome: WebWindowChrome? = null

        /** In the page's last "w.f" and visible (main thread): only those take touches ([hit]). */
        var shown = false

        /** Its app's task (learned from its display when first needed; kept while it's a full-screen app). */
        @Volatile var taskId = -1

        /** A running task to move onto its display instead of a launch (ShellBridge.toWebWindow: an app made a window), or -1. */
        @Volatile var adopt = -1

        /** Its app is a full-screen app on display 0 now ([fullScreen]): the window is hidden, its display empty. */
        @Volatile var full = false

        @Volatile var closed = false

        /** A Linux (KWin) window's source instead of a display ([LinuxSource]; docs/WEB_WINDOWS.md S6), else null. */
        var linux: LinuxSource? = null
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

    /** A window's frame and body, in home's window surface px; z: its place in DOM order (0 = bottom). */
    private class Geo(
        val id: Int,
        val frame: Rect,
        val body: Rect,
        val radius: Float,
        val visible: Boolean,
        val z: Int,
    ) {
        /** Two fingers zoomed it (its layer's matrix; the app keeps its resolution). */
        var scale = 1f

        /** Filling the work area (the bar shows restore). */
        var maximised = false

        /**
         * A divider is moving it: its app's last frame is scaled up to cover a body bigger than its display (cropped
         * when smaller), so the tile never shows the background (Android's split shows a veil there). The display
         * gets the real size when the page takes the new split.
         */
        var cover = false
    }

    /** The layer all windows hang under: home's window surface, under its own buffer. Made on first use (main thread). */
    private var root: SurfaceControl? = null

    private fun root(): SurfaceControl? {
        root?.takeIf { it.isValid }?.let { return it }
        val attached = web.rootSurfaceControl ?: return null.also { Log.w(TAG, "home's window has no surface yet") }
        val sc = SurfaceControl.Builder().setName("powos-webwindows").build()
        val t = attached.buildReparentTransaction(sc) ?: return null.also { sc.release(); Log.w(TAG, "home's surface refused a child") }
        // ABOVE home's own buffer (the user, 2026-10-30: "nobody asked for the cutoff"): a window is a card on home,
        // the widgets under it untouched. Still a child of home's surface, so every other window (the launcher overlay,
        // the shade, PowOS AI, the status bar, the IME) stays above it.
        t.setLayer(sc, 1).setVisibility(sc, !underSwitcher).apply()
        root = sc
        watchSurface()
        return sc
    }

    /** The switcher is up: every window's layer hidden under it (main thread). */
    private var underSwitcher = false

    /** The windows' root shown ([on]) or hidden, at once (main thread): [switcherOpen]. */
    private fun rootShown(on: Boolean) {
        underSwitcher = !on
        if (!on) tilesUnderSwitcher()
        val r = root?.takeIf { it.isValid } ?: return
        SurfaceControl.Transaction().setVisibility(r, on).apply()
        Log.i(TAG, "windows ${if (on) "shown again (switcher down)" else "hidden under the switcher (each is its card)"}: ${wins.size} window(s)")
    }

    /**
     * The switcher came up: the tiles' dividers, snap hint and tile menu are children of the windows' root, so they hide
     * with it; a divider drag in progress is let go as cancelled (its split stays), the menu and the hint go.
     */
    private fun tilesUnderSwitcher() {
        divDrag?.takeIf { !it.ended }?.let { dividerUp(it, cancelled = true) }
        tiles.closeMenu()
        tiles.hint(null)
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
        win.chrome = chromeFor(component, container)
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
        win.chrome = WebWindowChrome(context, container, p.label, p.icon)
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
            andro.marchy.WebWindowSource.crop(handle, win.w, win.h)
            andro.marchy.WebWindowSource.refreshRate(handle, rate)
            if (win.closed) {
                src.handle = 0
                andro.marchy.WebWindowSource.stop(handle)
                return@execute
            }
            Log.i(TAG, "window $id: KWin window $kwin (${p.appId}) consumer up, buffers ${bw}x$bh, body ${win.w}x${win.h}")
        }
        andro.marchy.WebWindowSource.size(kwin, w, h)
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
     * "w.f <frame> <dpr> <n> [<id> <fx> <fy> <fw> <fh> <bx> <by> <bw> <bh> <radius> <visible>] * n" (CSS px of the
     * page's viewport; bottom window first: its index is its z), on the port's thread. Every window the page shows is
     * in it; one that isn't is hidden. Applied on the draw that shows page frame <frame> ([FrameSync]).
     */
    fun frameCommand(rest: String) {
        val (frame, geos, divs) = parse(rest) ?: return
        val cookie = sync.receive(frame)
        main.post { sync.bind(frame, cookie) { apply(frame, geos, divs) } }
    }

    /**
     * After the windows: "<n> [<page:axis> <x|y> <pos> <from> <len> <lo> <hi> <before ids,|-> <after ids,|->]*n", the
     * tiles' dividers (ui/webwindows.tsx dividerEntries); absent from an older page.
     */
    private fun parseDividers(
        t: List<String>,
        start: Int,
        dpr: Float,
        at: IntArray,
    ): List<WebWindowTiles.Divider> {
        var i = start
        val n = t.getOrNull(i++)?.toIntOrNull() ?: return emptyList()
        val ids = { s: String -> if (s == "-") IntArray(0) else s.split(',').map { it.toInt() }.toIntArray() }
        return List(n) {
            val key = t[i++]
            val vertical = t[i++] == "x"
            // Along x: pos/lo/hi are x, from is y; along y the other way round.
            val (across, along) = if (vertical) at[0] to at[1] else at[1] to at[0]
            val f = { s: String, o: Int -> s.toFloat() * dpr + o }
            val geo = floatArrayOf(f(t[i++], across), f(t[i++], along), f(t[i++], 0), f(t[i++], across), f(t[i++], across))
            WebWindowTiles.Divider(key, vertical, geo, ids(t[i++]) to ids(t[i++]))
        }
    }

    private fun parse(rest: String): Triple<Long, List<Geo>, List<WebWindowTiles.Divider>>? =
        try {
            val t = rest.trim().split(' ')
            val frame = t[0].toLong()
            val dpr = t[1].toFloat()
            lastDpr = dpr
            val n = t[2].toInt()
            var i = 3
            // The WebView's place in its window (none for home: full screen): geometry is in the window surface's space.
            val at = IntArray(2).also(web::getLocationInWindow)

            fun px(
                v: String,
                o: Int,
            ) = Math.round(v.toFloat() * dpr) + o
            val geos =
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
                    val scale = t.getOrNull(i++)?.toFloatOrNull() ?: 1f
                    val maximised = t.getOrNull(i++) == "1"
                    Geo(id, frameRect, body, radius, visible, z).also {
                        it.scale = scale.coerceIn(MIN_SCALE, 1f)
                        it.maximised = maximised
                    }
                }
            Triple(frame, geos, parseDividers(t, i, dpr, at))
        } catch (e: RuntimeException) {
            Log.w(TAG, "w.f: bad geometry ($e)")
            null
        }

    /** On the main thread, on the draw that shows the page frame the geometry was measured on. */
    private fun apply(
        frame: Long,
        geos: List<Geo>,
        divs: List<WebWindowTiles.Divider>,
    ) {
        val t = SurfaceControl.Transaction()
        placeAll(t, geos)
        if (root?.isValid == true) tiles.place(t, divs, divDrag?.d?.key)
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
        val shown = HashSet<Int>()
        for (g in geos) {
            val win = wins[g.id] ?: continue
            shown += g.id
            win.shown = g.visible
            // Moved by the finger (Z2): the layer stays where the gesture left it until the page has taken that place.
            if (held(win, g)) continue
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
        val g = win.geo?.takeIf { win.shown && it.visible && win.mirror != null } ?: return null
        val chrome = win.chrome ?: return null
        val f = g.frame
        val s = g.scale
        val right = f.left + Math.round(f.width() * s)
        val bottom = f.top + Math.round(chrome.title * s)
        if (!g.maximised) {
            out += Rect(f.left, f.top, right, bottom)
            return null
        }
        val (titleEnd, controls) = chrome.parts(f.width()).map { f.left + Math.round(it * s) }
        out += Rect(f.left, f.top, titleEnd, bottom)
        out += Rect(controls, f.top, right, bottom)
        return intArrayOf(titleEnd, controls)
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
        Log.i(TAG, "w.f f$frame behind=$behind (${behindFrames}/$appliedFrames applies behind) " + geos.joinToString { "${it.id}@${it.body.toShortString()} z${it.z} ${if (it.visible) "shown" else "hidden"}" })
    }

    private var lastPlaceLog = 0L
    private var behindFrames = 0
    private var appliedFrames = 0

    /** [g] into [t]: the container at the frame (cropped, rounded, ordered, shown), the mirror at the body. */
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
        // Hidden is the layer, never the display's surface (a null surface stops the app).
        t.setVisibility(c, g.visible && win.mirror != null)
        val bw = g.body.width().coerceAtLeast(1)
        val bh = g.body.height().coerceAtLeast(1)
        val src = win.linux
        if (src != null && (bw != win.w || bh != win.h)) {
            win.w = bw
            win.h = bh
            // KWin lays the window out at the body's size; the consumer's crop and the buffer queue's size follow in
            // this transaction, so its next frames show 1:1 (one of the old size is dropped by the queue, never stretched).
            // Its own transaction, applied now: a buffer size riding [t] (applyTransactionOnDraw merges it into the
            // view's next frame natively) would skip SurfaceControl's Java-side queue resize - every later frame rejected.
            if (src.content.isValid) SurfaceControl.Transaction().setBufferSize(src.content, bw, bh).apply()
            andro.marchy.WebWindowSource.crop(src.handle, bw, bh)
            andro.marchy.WebWindowSource.size(src.kwin, bw, bh)
        } else if (win.displayId >= 0 && (bw != win.w || bh != win.h)) {
            win.w = bw
            win.h = bh
            // The app lays out at the body's real size; the crop already follows the DOM (its last frame shows anchored
            // top-left until it draws at the new size).
            helper.resize(win.displayId, bw, bh, dpi)
        }
    }

    /**
     * The window's layers for [g]'s frame (place, unscaled size) zoomed by its scale, into [t]: the container there (its
     * scale, cropped to the frame and to the work area - never over the dock), the native frame laid out, the mirror
     * under the bar cropped to the body. Shared by the page's geometry and the finger's moves.
     */
    private fun frameAt(
        t: SurfaceControl.Transaction,
        win: Win,
        g: Geo,
    ) {
        val x = g.frame.left.toFloat()
        val y = g.frame.top.toFloat()
        val w = g.frame.width()
        val h = g.frame.height()
        val scale = g.scale
        val maximised = g.maximised
        val c = win.container
        t.setPosition(c, x, y)
        t.setScale(c, scale, scale)
        // The work area's bottom in the window's own (unscaled) space: the dock strip stays home's.
        val bottom = ((area.bottom - y) / scale).toInt().coerceIn(0, h)
        t.setCrop(c, Rect(0, 0, w, bottom))
        val chrome = win.chrome ?: return
        chrome.layout(t, android.util.Size(w, h), maximised, theme)
        win.mirror?.takeIf { it.isValid }?.let { m ->
            val bodyH = (h - chrome.title).coerceAtLeast(1)
            // A divider drag: the app's last frame scaled to cover the bigger tile, cropped in the smaller (no veil).
            val s = if (g.cover && win.w > 0 && win.h > 0) maxOf(1f, w / win.w.toFloat(), bodyH / win.h.toFloat()) else 1f
            t.setPosition(m, 0f, chrome.title.toFloat())
            t.setScale(m, s, s)
            t.setCrop(m, Rect(0, 0, Math.ceil(w / s.toDouble()).toInt(), Math.ceil(bodyH / s.toDouble()).toInt()))
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

    // ---- the native frame's touches: move, resize, zoom, its buttons (Z2) --------------------------------------------

    /**
     * Touches on a window's native bar, edges and frame are the host's, from the first one (docs/WEB_WINDOWS.md
     * "Native frame and move"). The window is above home, so home's own hit test has the same answer: nothing of home is
     * over it. The body's touches stay the page's (it forwards them to the app, v0) - an app's own pinch is the app's.
     *
     * Why: the user, 2026-10-30, "its like its content is lagging behind slightly even when I move windows, compared to
     * the native android floating windows". A page-driven move binds the geometry to the first draw whose page state is
     * AT LEAST that frame's; with the finger moving, the page is a frame or more further by then ([logFrame]'s
     * "behind"). Here each batched MOVE (Choreographer delivers one per vsync) moves the window's layer in one
     * transaction applied at once, as WMShell's DragPositioningCallback does, and the bar is a layer of the window:
     * the bar and the content are one unit, they can't be a frame apart.
     *
     * - Bar: one finger moves, two fingers move by their centroid and zoom by their distance ("if I touch the titlebar
     *   with two fingers it jumps between the finger positions instead of allowing me to scale down the window"), a
     *   finger coming or going rebases, never jumps. Scale [MIN_SCALE]..1, the window's layer matrix: content and frame
     *   together, the app's resolution unchanged; the page maps body touches through it.
     * - Edges and corners ([EDGE_OUT_DP] outside, [EDGE_IN_DP] inside): resize. The frame and the crop follow the finger
     *   every frame (the app's last frame anchored top-left on the frame's background); the app's display is resized
     *   once, when the page takes the new size ("w.f" -> [place] -> the helper's VirtualDisplay.resize).
     * - Buttons: minimise (hidden at once, the page keeps it in the dock), full screen/restore and close; a double tap
     *   on the bar is full screen/restore.
     * - Up: "webwindows.moved {id, dx, dy, dw, dh, scale}" (CSS px); the layer stays put until a "w.f" has that place
     *   ([held]).
     * Moves and resizes are clamped to the work area ("w.area": above the dock and bar, which windows never cover).
     */
    private class Drag(
        val win: Win,
        /** [EDGE_L]|[EDGE_T]|[EDGE_R]|[EDGE_B]: a resize from those edges; 0: a move (and zoom). */
        val edges: Int,
        /** Its frame when the gesture began: place (window px) and unscaled size. */
        val start: Rect,
        val startScale: Float,
        val maximised: Boolean,
        val downAt: Long,
    ) {
        /** Where the gesture has it now. */
        val frame = Rect(start)
        var scale = startScale

        /** The fingers' centroid and spread, and the frame then, at the gesture's start or the last finger change. */
        var c0x = 0f
        var c0y = 0f
        var spread0 = 0f
        var o0x = 0f
        var o0y = 0f
        var s0 = 1f
        var downX = 0f
        var downY = 0f
        var moved = false
        var moves = 0
        var ended = false
        var endedAt = 0L

        /** A move with the finger at a screen edge or corner: the tile it snaps to when let go there (docs "Tiles"). */
        var slot: String? = null
    }

    private var drag: Drag? = null

    /** A press on a bar button: its window and control, run if the finger lifts on it. */
    private var pressed: Pair<Win, String>? = null
    private var lastTap: Pair<Int, Long>? = null

    @Volatile private var lastDpr = 1f
    private val slop by lazy { android.view.ViewConfiguration.get(context).scaledTouchSlop }

    /** Where windows may be, window px ("w.area"): above home's dock and bar. */
    private var area = Rect(0, 0, Int.MAX_VALUE / 4, Int.MAX_VALUE / 4)
    private var theme = WebWindowChrome.Theme.DEFAULT

    /** Where tiles go, window px (below the status bar, a gap above the dock): ui/webwindows.tsx tileArea. */
    private var tileArea = area

    /** "w.area <dpr> <l> <t> <r> <b> [<tile l> <t> <r> <b>]" (viewport CSS px), the port's thread. */
    fun areaCommand(rest: String) {
        val n = rest.trim().split(' ').mapNotNull { it.toFloatOrNull() }
        if (n.size < 5) return
        val at = IntArray(2).also(web::getLocationInWindow)
        val rect = { i: Int -> Rect(Math.round(n[i] * n[0]) + at[0], Math.round(n[i + 1] * n[0]) + at[1], Math.round(n[i + 2] * n[0]) + at[0], Math.round(n[i + 3] * n[0]) + at[1]) }
        val r = rect(1)
        val tr = if (n.size >= 9) rect(5) else r
        main.post {
            area = r
            tileArea = tr
        }
    }

    /** "w.theme <bg r g b a> <fg r g b a>": the bars in the page's colours (redrawn on their next placing). */
    fun themeCommand(rest: String) {
        val th = WebWindowChrome.Theme.parse(rest) ?: return
        main.post {
            theme = th
            tiles.theme = th
            val t = SurfaceControl.Transaction()
            for (w in wins.values) w.geo?.let { g -> if (w.container.isValid) place(t, w, g) }
            t.apply()
        }
    }

    private fun chromeFor(
        component: ComponentName,
        container: SurfaceControl,
    ): WebWindowChrome {
        val pm = context.packageManager
        val info = runCatching { pm.getActivityInfo(component, 0) }.getOrNull()
        val label = info?.loadLabel(pm)?.toString() ?: component.packageName
        val icon = runCatching { info?.loadIcon(pm) }.getOrNull()
        return WebWindowChrome(context, container, label, icon)
    }

    /** The fingers now: centroid (window px, without one lifting) and spread (mean distance to it). */
    private data class Fingers(
        val x: Float,
        val y: Float,
        val spread: Float,
        val n: Int,
    )

    private fun fingers(ev: MotionEvent): Fingers {
        val at = IntArray(2).also(web::getLocationInWindow)
        val lifting = if (ev.actionMasked == MotionEvent.ACTION_POINTER_UP) ev.actionIndex else -1
        val idx = (0 until ev.pointerCount).filter { it != lifting }.ifEmpty { listOf(0) }
        val x = idx.sumOf { ev.getX(it).toDouble() }.toFloat() / idx.size
        val y = idx.sumOf { ev.getY(it).toDouble() }.toFloat() / idx.size
        val spread = idx.sumOf { Math.hypot((ev.getX(it) - x).toDouble(), (ev.getY(it) - y).toDouble()) }.toFloat() / idx.size
        return Fingers(x + at[0], y + at[1], spread, idx.size)
    }

    /** Every touch on home, first ([HomeWebView.touchHook], main thread): true = the frame's, the page doesn't get it. */
    private fun onTouch(ev: MotionEvent): Boolean {
        // A Linux window's body: the gesture is KWin's ([linuxTouch]), from its first finger to its last.
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            // A first finger is a new gesture: a move or divider drag whose UP never came is over. Left "not ended", it
            // held its window (held(): the page's places and visibility skipped - the layer stuck where it was, on
            // every page, while hit tests used the page's geometry), and only a touch on a bar cleared it - never one
            // on a Linux window's body, which goes to KWin.
            drag?.takeIf { !it.ended }?.let { drag = null }
            divDrag?.takeIf { !it.ended }?.let { divDrag = null }
            pressed = null
            return linuxDown(ev) || frameTouch(ev)
        }
        return linuxTouch?.let { linuxInput(it, ev) } ?: frameTouch(ev)
    }

    /** [onTouch] for the frames: bars, buttons, edges, dividers, the tile menu. */
    private fun frameTouch(ev: MotionEvent): Boolean {
        val f = fingers(ev)
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) return down(f)
        pressed?.let { p -> return pressUp(p, ev, f) }
        divDrag?.takeIf { !it.ended }?.let { dd ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_MOVE -> dividerMove(dd, f)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> dividerUp(dd, ev.actionMasked == MotionEvent.ACTION_CANCEL)
            }
            return true
        }
        val d = drag?.takeIf { !it.ended } ?: return false
        when (ev.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> rebase(d, f)
            MotionEvent.ACTION_MOVE -> follow(d, f)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> endDrag(d, ev.actionMasked == MotionEvent.ACTION_CANCEL)
        }
        return true
    }

    /** A finger down: on a window's bar, button or edge = the host's gesture; on a body or off every window = the page's. */
    private fun down(f: Fingers): Boolean {
        pressed = null
        if (drag?.ended == false) drag = null
        if (divDrag?.ended == false) divDrag = null
        if (menuDown(f) || tilesDown(f)) return true
        val (win, part) = hit(f.x, f.y) ?: return false
        val g = win.geo ?: return false
        emit("webwindows.raise", win.id)
        if (win.container.isValid) SurfaceControl.Transaction().setLayer(win.container, wins.size + 1).apply()
        if (part.startsWith("button:")) {
            pressed = win to part.removePrefix("button:")
            return true
        }
        val edges = if (part == "bar") 0 else part.toInt()
        val d = Drag(win, edges, Rect(g.frame), g.scale, g.maximised, SystemClock.uptimeMillis())
        d.downX = f.x
        d.downY = f.y
        rebase(d, f)
        drag = d
        return true
    }

    /** The tile menu open: a press on it picks (when the finger lifts there); anywhere else closes it (false). */
    private fun menuDown(f: Fingers): Boolean {
        val id = tiles.menuFor ?: return false
        val item = tiles.menuAt(f.x, f.y)
        if (item == null) {
            tiles.closeMenu()
            return false
        }
        wins[id]?.let { pressed = it to "menu:$item" }
        return true
    }

    /** A divider is above every window (its touch target is wider than the gap: it overlaps the tiles' edges). */
    private fun tilesDown(f: Fingers): Boolean {
        // Hidden under the switcher: no divider to grab.
        if (underSwitcher || f.y >= area.bottom) return false
        val dv = tiles.dividerAt(f.x, f.y) ?: return false
        return dividerDown(dv, f)
    }

    /**
     * A Linux window's body touched (docs/WEB_WINDOWS.md S6, Z4): the whole gesture is its, every pointer, straight to
     * KWin over the consumer's input path (as PowosWindowActivity's SurfaceView sends a task's) - never the page's, never
     * re-injected. KWin delivers it to the surface (or popup) under the point.
     */
    private var linuxTouch: Win? = null

    /** The KWin window that last got "focus" from a touch here: told again only when another one is touched. */
    private var linuxFocused = -1

    /** At most one "touch to KWin window" line a second ([linuxDown]). */
    private var lastLinuxLog = 0L

    /** The topmost shown window at ([x], [y]) when the point is on a Linux window's body, else null. */
    private fun linuxBodyAt(
        x: Float,
        y: Float,
    ): Win? {
        if (y >= area.bottom || underSwitcher || tiles.menuFor != null) return null
        val win = wins.values.filter { it.shown && it.mirror != null }.sortedByDescending { it.geo?.z ?: -1 }.firstOrNull { partAt(it, x, y) != null }
        return win?.takeIf { it.linux != null && partAt(it, x, y) == "" }
    }

    /** A first finger down: on a Linux window's body, the gesture is its ([linuxTouch]); false: anything else's. */
    private fun linuxDown(ev: MotionEvent): Boolean {
        linuxTouch = null
        val f = fingers(ev)
        val win = linuxBodyAt(f.x, f.y) ?: return false
        linuxTouch = win
        emit("webwindows.raise", win.id)
        if (win.container.isValid) SurfaceControl.Transaction().setLayer(win.container, wins.size + 1).apply()
        val src = win.linux ?: return true
        if (linuxFocused != src.kwin) {
            linuxFocused = src.kwin
            andro.marchy.WebWindowSource.focus(src.kwin)
        }
        logLinuxTouch(win, src, f)
        return linuxInput(win, ev)
    }

    /** A first finger on [win]'s body, at most once a second (and always when its consumer isn't up): where it went. */
    private fun logLinuxTouch(
        win: Win,
        src: LinuxSource,
        f: Fingers,
    ) {
        val now = SystemClock.uptimeMillis()
        if (src.handle != 0L && now - lastLinuxLog < PLACE_LOG_MS) return
        lastLinuxLog = now
        val g = win.geo ?: return
        val s = g.scale
        val bx = ((f.x - g.frame.left) / s).toInt()
        val by = ((f.y - g.frame.top) / s).toInt() - (win.chrome?.title ?: 0)
        val dropped = if (src.handle == 0L) ": its consumer isn't up, dropped" else ""
        Log.i(TAG, "window ${win.id}: touch to KWin window ${src.kwin} at body px ($bx, $by) x$s$dropped")
    }

    /** [ev] to [win]'s KWin window in its body's own px (its frame's place and scale, under the bar). */
    private fun linuxInput(
        win: Win,
        ev: MotionEvent,
    ): Boolean {
        val a = ev.actionMasked
        if (a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_CANCEL) linuxTouch = null
        val src = win.linux ?: return true
        val g = win.geo ?: return true
        val title = win.chrome?.title ?: 0
        val at = IntArray(2).also(web::getLocationInWindow)
        val s = g.scale
        andro.marchy.WebWindowSource.touch(src.handle, ev, at[0] - g.frame.left.toFloat(), at[1] - g.frame.top - title * s, s)
        return true
    }

    /** The topmost shown window at ([x], [y]) and what of it: "bar", "button:<control>", an edge mask, or null (its body). */
    private fun hit(
        x: Float,
        y: Float,
    ): Pair<Win, String>? {
        if (y >= area.bottom) return null
        for (win in wins.values.filter { it.shown && it.mirror != null }.sortedByDescending { it.geo?.z ?: -1 }) {
            val part = partAt(win, x, y) ?: continue
            return if (part.isEmpty()) null else win to part
        }
        return null
    }

    /** What of [win] is at ([x], [y]): "bar", "button:<control>", an edge mask, "" (its body), or null (not on it). */
    private fun partAt(
        win: Win,
        x: Float,
        y: Float,
    ): String? {
        val g = win.geo ?: return null
        val chrome = win.chrome ?: return null
        val s = g.scale
        // Window-local, unscaled; its size as shown (cut at the work area's bottom).
        val p = android.graphics.PointF((x - g.frame.left) / s, (y - g.frame.top) / s)
        val size = android.graphics.PointF(g.frame.width().toFloat(), minOf(g.frame.height().toFloat(), (area.bottom - g.frame.top) / s))
        val out = EDGE_OUT_DP * density() / s
        if (!android.graphics.RectF(-out, -out, size.x + out, size.y + out).contains(p.x, p.y)) return null
        if (p.y in 0f..chrome.title.toFloat() && p.x in 0f..size.x) return chrome.control(p.x, size.x.toInt())?.let { "button:$it" } ?: "bar"
        val edges = edgesAt(p, size, EDGE_IN_DP * density() / s)
        return if (edges != 0) edges.toString() else ""
    }

    /** Which edges window-local [p] is on, in a window of [size] ([inner]: how far inside counts; above it is the top). */
    private fun edgesAt(
        p: android.graphics.PointF,
        size: android.graphics.PointF,
        inner: Float,
    ): Int {
        var e = 0
        if (p.x < inner) e = e or EDGE_L
        if (p.x > size.x - inner) e = e or EDGE_R
        if (p.y > size.y - inner) e = e or EDGE_B
        if (p.y < 0) e = e or EDGE_T
        return e
    }

    /** A bar button's press: it runs when the finger lifts on the same button. */
    private fun pressUp(
        p: Pair<Win, String>,
        ev: MotionEvent,
        f: Fingers,
    ): Boolean {
        val a = ev.actionMasked
        if (a != MotionEvent.ACTION_UP && a != MotionEvent.ACTION_CANCEL) return true
        pressed = null
        val (win, control) = p
        if (control.startsWith("menu:")) return menuUp(win, control.removePrefix("menu:"), a, f)
        if (a == MotionEvent.ACTION_CANCEL || hit(f.x, f.y)?.let { it.first === win && it.second == "button:$control" } != true) return true
        control(win, control)
        return true
    }

    /** A tile menu item pressed: it runs when the finger lifts on it. */
    private fun menuUp(
        win: Win,
        item: String,
        action: Int,
        f: Fingers,
    ): Boolean {
        if (action != MotionEvent.ACTION_UP || item.isEmpty() || tiles.menuAt(f.x, f.y) != item) return true
        tiles.closeMenu()
        Log.i(TAG, "window ${win.id}: tile $item (its tile menu)")
        emit("webwindows.tile", mapOf("id" to win.id, "slot" to item))
        return true
    }

    private fun control(
        win: Win,
        control: String,
    ) {
        Log.i(TAG, "window ${win.id}: $control (its bar)")
        when (control) {
            "close" -> close(win.id)
            "minimise" -> {
                // At once (the page drops it from its geometry a frame later): the app keeps running.
                if (win.container.isValid) SurfaceControl.Transaction().setVisibility(win.container, false).apply()
                win.shown = false
                emit("webwindows.control", mapOf("id" to win.id, "action" to "minimise"))
            }
            "tile" -> tileMenu(win)
            // The button: the app becomes a real full-screen app (the manager's rule, 10-29). The bar's double tap is
            // the window's own maximise ([tapped]).
            else -> fullScreen(win)
        }
    }

    /** The bar's tile button: the tile menu under it (left, right, top, bottom, grid, float). */
    private fun tileMenu(win: Win) {
        val g = win.geo ?: return
        val chrome = win.chrome ?: return
        val anchor = g.frame.left + chrome.centerOf("tile", g.frame.width()) * g.scale
        val top = g.frame.top + (chrome.title + 4 * density()) * g.scale
        val tiled = tiles.dividers.any { win.id in it.before || win.id in it.after }
        tiles.openMenu(win.id, android.graphics.PointF(anchor, top), area, tiled)
    }

    /** A finger came or went (or the gesture began): the gesture goes on from here, the window doesn't jump. */
    private fun rebase(
        d: Drag,
        f: Fingers,
    ) {
        d.c0x = f.x
        d.c0y = f.y
        d.spread0 = if (f.n >= 2) f.spread else 0f
        d.o0x = d.frame.left.toFloat()
        d.o0y = d.frame.top.toFloat()
        d.s0 = d.scale
    }

    /** One batched MOVE (one per vsync): the window where the fingers have it, one transaction, applied now. */
    private fun follow(
        d: Drag,
        f: Fingers,
    ) {
        if (!d.moved) {
            d.moved = Math.hypot((f.x - d.downX).toDouble(), (f.y - d.downY).toDouble()) > slop || (d.spread0 > 0 && Math.abs(f.spread - d.spread0) > slop)
            if (!d.moved) return
        }
        if (d.edges == 0) {
            moveTo(d, f)
            trackSlot(d, f)
        } else {
            resizeTo(d, f)
        }
        d.moves++
        val t = SurfaceControl.Transaction()
        val live = Geo(d.win.id, Rect(d.frame), Rect(d.frame), 0f, true, 0).also {
            it.scale = d.scale
            it.maximised = d.maximised
        }
        if (d.win.container.isValid) frameAt(t, d.win, live)
        t.apply()
    }

    /** A one-finger move at a screen edge or corner: the snap hint shows that tile (only when it changes). */
    private fun trackSlot(
        d: Drag,
        f: Fingers,
    ) {
        val slot = if (f.n == 1 && d.spread0 == 0f) snapSlot(f.x, f.y) else null
        if (slot == d.slot) return
        d.slot = slot
        tiles.hint(slot?.let(::slotRect))
    }

    /** Move and zoom: the window point under the centroid at the rebase stays under it, at the fingers' scale. */
    private fun moveTo(
        d: Drag,
        f: Fingers,
    ) {
        d.scale = if (d.spread0 > 0 && f.n >= 2) (d.s0 * f.spread / d.spread0).coerceIn(MIN_SCALE, 1f) else d.s0
        val px = (d.c0x - d.o0x) / d.s0
        val py = (d.c0y - d.o0y) / d.s0
        val w = d.frame.width() * d.scale
        val keep = KEEP_DP * density()
        val bar = (d.win.chrome?.title ?: 0) * d.scale
        val x = (f.x - px * d.scale).coerceIn(area.left - w + keep, area.right - keep)
        val y = (f.y - py * d.scale).coerceIn(area.top.toFloat(), (area.bottom - bar).coerceAtLeast(area.top.toFloat()))
        d.frame.offsetTo(Math.round(x), Math.round(y))
    }

    /** Resize from the gesture's edges: the opposite edges stay, the frame follows the finger, inside the work area. */
    private fun resizeTo(
        d: Drag,
        f: Fingers,
    ) {
        val s = d.scale
        val st = d.start
        val minW = MIN_W_DP * density() * s
        val minH = MIN_H_DP * density() * s
        // Screen px: the start's edges, the dragged ones moved by the finger.
        var l = st.left.toFloat()
        var t = st.top.toFloat()
        var r = l + st.width() * s
        var b = t + st.height() * s
        val dx = f.x - d.downX
        val dy = f.y - d.downY
        if (d.edges and EDGE_L != 0) l = (l + dx).coerceIn(area.left.toFloat(), r - minW)
        if (d.edges and EDGE_R != 0) r = (r + dx).coerceIn(l + minW, area.right.toFloat())
        if (d.edges and EDGE_T != 0) t = (t + dy).coerceIn(area.top.toFloat(), b - minH)
        if (d.edges and EDGE_B != 0) b = (b + dy).coerceIn(t + minH, area.bottom.toFloat())
        val left = Math.round(l)
        val top = Math.round(t)
        d.frame.set(left, top, left + Math.round((r - l) / s), top + Math.round((b - t) / s))
    }

    private fun endDrag(
        d: Drag,
        cancelled: Boolean,
    ) {
        d.ended = true
        d.endedAt = SystemClock.uptimeMillis()
        val ms = d.endedAt - d.downAt
        val dpr = lastDpr
        val win = d.win
        val tap = !d.moved && !cancelled && ms < TAP_MS
        Log.i(TAG, "native ${if (d.edges == 0) "move" else "resize"} w${win.id}: ${d.moves} layer moves in $ms ms (one per input frame), frame ${d.start.toShortString()} -> ${d.frame.toShortString()} x${"%.2f".format(d.scale)}${if (tap) ", a tap" else ""}")
        if (snapEnd(d, cancelled)) return
        if (tap && d.edges == 0) tapped(win, d.endedAt)
        if (!d.moved) {
            drag = null
            return
        }
        emit(
            "webwindows.moved",
            mapOf(
                "id" to win.id,
                "dx" to (d.frame.left - d.start.left) / dpr,
                "dy" to (d.frame.top - d.start.top) / dpr,
                "dw" to (d.frame.width() - d.start.width()) / dpr,
                "dh" to (d.frame.height() - d.start.height()) / dpr,
                "scale" to d.scale,
            ),
        )
    }

    /**
     * Let go at an edge or corner: into that tile at once (the tile's rect as the page will make it, so the hold ends
     * on the page's first frame with it), the app's last frame covering it until it resizes. False: not at one.
     */
    private fun snapEnd(
        d: Drag,
        cancelled: Boolean,
    ): Boolean {
        val slot = d.slot ?: return false
        tiles.hint(null)
        if (cancelled) return false
        val win = d.win
        d.frame.set(slotRect(slot))
        d.scale = 1f
        val t = SurfaceControl.Transaction()
        if (win.container.isValid) frameAt(t, win, Geo(win.id, Rect(d.frame), Rect(d.frame), 0f, true, 0).also { it.cover = true })
        t.apply()
        Log.i(TAG, "window ${win.id}: snapped to tile $slot ${d.frame.toShortString()} (let go at the screen's edge)")
        emit("webwindows.tile", mapOf("id" to win.id, "slot" to slot))
        return true
    }

    /** A tap on [win]'s bar at [at]: the second one soon after on the same bar is full screen / restore. */
    private fun tapped(
        win: Win,
        at: Long,
    ) {
        val last = lastTap
        lastTap = win.id to at
        if (last == null || last.first != win.id || at - last.second >= DOUBLE_TAP_MS) return
        lastTap = null
        // Fill the work area above the dock / restore (the page's toggleMaximise): not the full screen button's.
        Log.i(TAG, "window ${win.id}: maximise (bar double tap)")
        emit("webwindows.control", mapOf("id" to win.id, "action" to "maximise"))
    }

    /**
     * In [placeAll]: true = the finger's gesture owns [win]'s layer this frame (not placed from [g]). After the up, the
     * page's frames still show the old place until it took the new one: held until a frame has it (2 px), or a second.
     */
    private fun held(
        win: Win,
        g: Geo,
    ): Boolean {
        heldByDivider(win, g)?.let { return it }
        val d = drag?.takeIf { it.win === win } ?: return false
        if (!d.ended) return true
        if (!near(g.frame, d.frame) && SystemClock.uptimeMillis() - d.endedAt < HOLD_MS) return true
        drag = null
        return false
    }

    // ---- tiles: snapping at the screen's edges, dividers ---------------------------------------------------------------

    /** A move's finger at the work area's left/right edge (a corner: its top/bottom too): that tile, or null. */
    private fun snapSlot(
        x: Float,
        y: Float,
    ): String? {
        val edge = SNAP_EDGE_DP * density()
        val corner = SNAP_CORNER_DP * density()
        val left = x <= area.left + edge
        if (!left && x < area.right - edge) return null
        val row =
            when {
                y <= area.top + corner -> 0
                y >= area.bottom - corner -> 2
                else -> 1
            }
        return SNAP_SLOTS[row][if (left) 0 else 1]
    }

    /** Tile [slot]'s rect (window px), as ui/webwindows.tsx tileRects makes it for a new tiling (at a half). */
    private fun slotRect(slot: String): Rect {
        val area = tileArea
        val g = WebWindowTiles.GAP_CSS * lastDpr / 2
        val mx = (area.left + area.right) / 2f
        val my = (area.top + area.bottom) / 2f
        val l = area.left.toFloat()
        val t = area.top.toFloat()
        val r = area.right.toFloat()
        val b = area.bottom.toFloat()
        val (x0, y0, x1, y1) =
            when (slot) {
                "left" -> listOf(l, t, mx - g, b)
                "right" -> listOf(mx + g, t, r, b)
                "tl" -> listOf(l, t, mx - g, my - g)
                "tr" -> listOf(mx + g, t, r, my - g)
                "bl" -> listOf(l, my + g, mx - g, b)
                else -> listOf(mx + g, my + g, r, b)
            }
        return Rect(Math.round(x0), Math.round(y0), Math.round(x1), Math.round(y1))
    }

    /** A divider under the finger: the tiles on both sides follow it live (native, no page round trip). */
    private class DivDrag(
        val d: WebWindowTiles.Divider,
        val handle: Any?,
        /** The finger's coordinate across the divider at the down. */
        val down: Float,
        /** The tiles' frames at the down (window px). */
        val starts: Map<Int, Rect>,
    ) {
        val downAt = SystemClock.uptimeMillis()
        var pos = d.pos
        var moved = false
        var moves = 0
        var ended = false
        var endedAt = 0L

        /** After the up: where each tile was let go (held there until the page's frame has it). */
        val targets = HashMap<Int, Rect>()
    }

    private var divDrag: DivDrag? = null

    private fun dividerDown(
        dv: WebWindowTiles.Divider,
        f: Fingers,
    ): Boolean {
        val starts = (dv.before + dv.after).toList().mapNotNull { id -> wins[id]?.geo?.let { id to Rect(it.frame) } }.toMap()
        val handle = tiles.handle(dv)
        divDrag = DivDrag(dv, handle, if (dv.vertical) f.x else f.y, starts)
        return true
    }

    /** Each tile's frame with the divider at [pos]: the before side's far edge and the after side's near edge follow it. */
    private fun dividerFrames(
        dd: DivDrag,
        pos: Float,
    ): Map<Int, Rect> {
        val g = WebWindowTiles.GAP_CSS * lastDpr / 2
        val out = HashMap<Int, Rect>()
        for ((id, start) in dd.starts) {
            val r = Rect(start)
            val before = id in dd.d.before
            when {
                dd.d.vertical && before -> r.right = Math.round(pos - g)
                dd.d.vertical -> r.left = Math.round(pos + g)
                before -> r.bottom = Math.round(pos - g)
                else -> r.top = Math.round(pos + g)
            }
            out[id] = r
        }
        return out
    }

    /** The tiles and the handle with the divider at [pos], one transaction now: each app's last frame scaled or cropped. */
    private fun dividerShow(
        dd: DivDrag,
        pos: Float,
    ) {
        val t = SurfaceControl.Transaction()
        for ((id, r) in dividerFrames(dd, pos)) {
            val win = wins[id]?.takeIf { it.container.isValid } ?: continue
            frameAt(t, win, Geo(id, r, r, 0f, true, 0).also { it.cover = true })
        }
        dd.handle?.let { tiles.at(t, it, pos, dd.d) }
        t.apply()
    }

    private fun dividerMove(
        dd: DivDrag,
        f: Fingers,
    ) {
        val at = if (dd.d.vertical) f.x else f.y
        if (!dd.moved) {
            dd.moved = Math.abs(at - dd.down) > slop
            if (!dd.moved) return
        }
        val min = MIN_TILE_DP * density()
        dd.pos = (dd.d.pos + at - dd.down).coerceIn(dd.d.lo + min, (dd.d.hi - min).coerceAtLeast(dd.d.lo + min))
        dd.moves++
        dividerShow(dd, dd.pos)
    }

    /**
     * Let go: within [WebWindowTiles.DROP] of an edge the squeezed side's windows leave the tiles (the page minimises
     * them, the rest close up); else it snaps to 1/3, 1/2 or 2/3, at once, and the page takes that split (its next
     * frame resizes the displays: each app lays out at its real tile size).
     */
    private fun dividerUp(
        dd: DivDrag,
        cancelled: Boolean,
    ) {
        dd.ended = true
        dd.endedAt = SystemClock.uptimeMillis()
        if (!dd.moved) {
            divDrag = null
            return
        }
        val r = dd.d.ratio(dd.pos)
        val ms = dd.endedAt - dd.downAt
        val drop =
            when {
                cancelled -> null
                r < WebWindowTiles.DROP -> dd.d.before
                r > 1 - WebWindowTiles.DROP -> dd.d.after
                else -> null
            }
        if (drop != null && drop.isNotEmpty()) {
            Log.i(TAG, "divider ${dd.d.key}: ${dd.moves} live moves in $ms ms, let go at ${"%.2f".format(r)}: windows ${drop.joinToString()} leave the tiles (to the dock)")
            divDrag = null
            emit("webwindows.divider", mapOf("key" to dd.d.key, "ratio" to r, "drop" to drop.toList()))
            return
        }
        val snapped = if (cancelled) dd.d.ratio(dd.d.pos) else WebWindowTiles.snap(r)
        dd.pos = dd.d.lo + snapped * (dd.d.hi - dd.d.lo)
        dd.targets.putAll(dividerFrames(dd, dd.pos))
        dividerShow(dd, dd.pos)
        Log.i(TAG, "divider ${dd.d.key}: ${dd.moves} live moves in $ms ms (last frames scaled/cropped, no veil), ${"%.2f".format(r)} -> snapped ${"%.2f".format(snapped)}")
        emit("webwindows.divider", mapOf("key" to dd.d.key, "ratio" to snapped))
    }

    /** [held] for a divider's tiles: null = not one of them; else whether its layer stays where the drag left it. */
    private fun heldByDivider(
        win: Win,
        g: Geo,
    ): Boolean? {
        val dd = divDrag ?: return null
        if (win.id !in dd.starts) return null
        if (!dd.ended) return true
        val target = dd.targets[win.id] ?: return null
        if (!near(g.frame, target) && SystemClock.uptimeMillis() - dd.endedAt < HOLD_MS) return true
        dd.targets.remove(win.id)
        if (dd.targets.isEmpty()) divDrag = null
        return false
    }

    /** The page's frame [a] has the gesture's place [b] (2 px either way: rounding). */
    private fun near(
        a: Rect,
        b: Rect,
    ): Boolean = maxOf(Math.abs(a.left - b.left), Math.abs(a.top - b.top), Math.abs(a.width() - b.width()), Math.abs(a.height() - b.height())) <= 2

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
        if (current === this) current = null
        drag = null
        divDrag = null
        tiles.release()
        (web as? HomeWebView)?.touchHook = null
        // Linux windows keep running as their own tasks (home's page is going: nothing would show them); Android ones
        // close with their displays as before.
        wins.values.toList().forEach { drop(it, handBack = it.linux != null) }
        pendingLinux.keys.toList().forEach { kwin -> pendingLinux.remove(kwin)?.let { andro.marchy.WebWindowSource.fallback(context, kwin, it.appId, it.title) } }
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
        handBack: Boolean = false,
    ) {
        if (wins.remove(w.id) == null) return
        w.closed = true
        dropLinux(w, handBack)
        Log.i(TAG, "close window ${w.id} (${w.component.packageName}, display ${w.displayId}, task ${w.taskId}${if (w.full) ", full screen" else ""}): 1/4 layers off")
        if (drag?.win === w) drag = null
        if (divDrag?.starts?.containsKey(w.id) == true) divDrag = null
        if (tiles.menuFor == w.id) tiles.closeMenu()
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
        Log.i(TAG, "close window ${w.id}: 2/4 layers gone (container, mirror, frame), page told (webwindows.closed) - 4/4")
        emit("webwindows.closed", w.id)
    }

    /** [w]'s layers (mirror, frame, container) off the screen in one transaction, then released. */
    private fun releaseLayers(w: Win) {
        val t = SurfaceControl.Transaction()
        w.mirror?.let { if (it.isValid) t.reparent(it, null) }
        w.chrome?.release(t)
        if (w.container.isValid) t.reparent(w.container, null)
        t.apply()
        w.chrome?.releaseNow()
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
        if (win.linux != null) {
            // Not yet a full-screen app for a Linux window (S6 next steps): its button fills the work area instead.
            Log.i(TAG, "window ${win.id}: full screen for a Linux window is the work area's maximise (for now)")
            emit("webwindows.control", mapOf("id" to win.id, "action" to "maximise"))
            return
        }
        if (win.displayId < 0 || win.full) return
        // Out of its tile (the page closes the others up on "webwindows.full"): no divider drag or tile menu on it.
        if (divDrag?.starts?.containsKey(win.id) == true) divDrag = null
        if (tiles.menuFor == win.id) tiles.closeMenu()
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

    /** The page's "webwindows.fullScreen": window [id]'s app full screen ([fullScreen]); false: no such window. */
    fun fullScreen(id: Int): Boolean {
        val w = wins[id] ?: return false
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

        /** A Linux web window's switcher card id: this + its window id (no Android task id gets near it). */
        const val LINUX_CARD = 1 shl 29

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
        /** A press on the bar that didn't move and lifted within this: a tap (two make a double tap: maximise). */
        private const val TAP_MS = 300L
        private const val DOUBLE_TAP_MS = 350L

        /** After the finger's up, how long the layer waits for the page to take the place (then the page's wins). */
        private const val HOLD_MS = 1000L
        private const val MIN_SCALE = 0.4f

        /** Resize grabs: outside the frame and inside its edges (the bar's top edge is its move). */
        private const val EDGE_OUT_DP = 20f
        private const val EDGE_IN_DP = 12f
        private const val MIN_W_DP = 220f
        private const val MIN_H_DP = 160f

        /** A divider stops this far from its span's ends (a tile that small is about to leave: [WebWindowTiles.DROP]). */
        private const val MIN_TILE_DP = 48f

        /** A move snaps to a tile with the finger this near the work area's left/right edge (corner: and its top/bottom). */
        private const val SNAP_EDGE_DP = 24f
        private const val SNAP_CORNER_DP = 120f
        private val SNAP_SLOTS = listOf(listOf("tl", "tr"), listOf("left", "right"), listOf("bl", "br"))

        /** How much of a window's width stays on screen when it's moved sideways off it. */
        private const val KEEP_DP = 64f
        private const val EDGE_L = 1
        private const val EDGE_T = 2
        private const val EDGE_R = 4
        private const val EDGE_B = 8
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
