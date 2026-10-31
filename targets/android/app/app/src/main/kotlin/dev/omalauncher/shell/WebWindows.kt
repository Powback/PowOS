package dev.omalauncher.shell

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
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
                    WindowLog.i(TAG, "display $displayId removed: window ${w.id} closed")
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
     * [ORPHAN_CONFIRM_MS] later (a trampoline activity, a move in progress) and, still [orphaned], closed - the frame never
     * outlives its task.
     */
    private fun reconcile() {
        tick()
        val all = wins.values.filter { it.linux == null && !it.closed }
        val ws = all.filter { it.displayId >= 0 }
        // Any state (tiled, a hidden tab, full screen, minimised, no display): a known task that is gone closes it.
        val tasked = all.filter { it.displayId < 0 && it.taskId >= 0 }
        if (ws.isEmpty() && tasked.isEmpty()) return
        // A window minimised as a home gesture (MN1: its task left for display 0 / PiP) is checkLeft's, not follow's.
        io.post { reconcileNow(ws, tasked) }
    }

    /** [reconcile]'s next run [HEARTBEAT_MS] on, and the host's window ids to the page (its model agrees: no stale entry in "w.f"). */
    private fun tick() {
        main.removeCallbacks(heartbeat)
        if (wins.isNotEmpty()) main.postDelayed(heartbeat, HEARTBEAT_MS)
        emit("webwindows.alive", org.json.JSONArray(wins.keys.toList()))
    }

    /** On [io]: [reconcile]'s reads for Android windows [ws]. */
    private fun reconcileNow(
        ws: List<Win>,
        tasked: List<Win> = emptyList(),
    ) {
        @Suppress("DEPRECATION")
        val running = runCatching { context.getSystemService(android.app.ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrNull()
        // A window whose app's task is gone closes, whatever state it is in (on its display, full screen, minimised,
        // removed by PowOS itself or anyone else): the frame never outlives its task.
        running?.let { r -> (ws + tasked).filter { taskDead(it, r) }.forEach { w -> io.postDelayed({ confirmDead(w) }, DEAD_CONFIRM_MS) } }
        ws.filter { it.leftAt == 0L }.forEach { if (running == null || !follow(it, running)) checkOrphan(it) }
        ws.filter { it.leftAt != 0L }.forEach(::checkLeft)
    }

    /** While there are windows, a [reconcile] at least every [HEARTBEAT_MS]: a missed task change never leaves a ghost. */
    private val heartbeat = Runnable { reconcile() }

    /**
     * On [io]: [w]'s app's task (known: [Win.taskId]) is in no running task and its display holds none - its app is
     * gone, wherever the window had it (its display, full screen on display 0, minimised / PiP). Not while adopting.
     */
    private fun taskDead(
        w: Win,
        running: List<android.app.ActivityManager.RunningTaskInfo>,
    ): Boolean {
        if (w.closed || w.adopt >= 0 || w.taskId < 0) return false
        if (running.any { it.taskId == w.taskId }) return false
        return w.displayId < 0 || tasksOn(w.displayId) == 0
    }

    /** On [io]: task [id] is still running somewhere (unknown: true; removing a task that is gone is a no-op). */
    private fun taskAlive(id: Int): Boolean {
        @Suppress("DEPRECATION")
        val running = runCatching { context.getSystemService(android.app.ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrNull() ?: return true
        return running.any { it.taskId == id }
    }

    /** On [io]: [taskDead] still true [DEAD_CONFIRM_MS] later - the window closed the bar's way (main thread). */
    private fun confirmDead(w: Win) {
        @Suppress("DEPRECATION")
        val running = runCatching { context.getSystemService(android.app.ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrNull() ?: return
        if (!taskDead(w, running)) return
        val task = w.taskId
        main.post {
            if (w.closed) return@post
            WindowLog.i(TAG, "window ${w.id} (${w.component.packageName}${stateOf(w)}): its app's task $task is gone (removed by ${dev.omalauncher.system.Tasks.removedBy(task)}): window closed")
            WebWindowDisplays.fullScreen(task, w.id, false)
            // Nothing left to remove: its task is gone already.
            w.full = false
            w.leftAt = 0L
            drop(w)
        }
    }

    /** The Android window that holds (or held) task [taskId], whatever its state: the stale-map fallback of [closeForTask]. */
    internal fun windowOfTask(taskId: Int): Int? =
        if (taskId < 0) null else runCatching { wins.values.toList() }.getOrNull()?.firstOrNull { it.linux == null && !it.closed && it.taskId == taskId }?.id

    /**
     * On [io] (WM1): [w]'s app's task, wherever the system or the app took it - OnePlus' "Floating window" (its "..."
     * menu, WINDOWING_MODE_ZOOM) or freeform, PiP, a split, full screen, on display 0 or in the window's own display -
     * followed by the window, never left as an empty frame beside a native window ([followOf]): floating -> back on its
     * display, full screen there, the same window at its place and size; full screen / split on display 0 -> the
     * window's full-screen state; PiP -> minimised (the frame hidden). True: the task is alive and the window holds it
     * (no orphan check); false: not this window's to follow (gone, another display) - [checkOrphan] decides.
     * Its task is learned from its display while it's there ([Win.taskId]).
     */
    private fun follow(
        w: Win,
        running: List<android.app.ActivityManager.RunningTaskInfo>,
    ): Boolean {
        val t = followedTask(w, running) ?: return false
        val display = WebWindowDisplays.displayOf(t)
        val mode = modeOf(t)
        // D1: the user made its app an Android floating window on purpose ("..." or the switcher's Floating window): it
        // stays native. The window lets go of it (false: its display empty, checkOrphan closes it), never pulls it back.
        // Only a float on the main display: OnePlus' Floating window never puts a task on a window's own display, and a
        // task PowOS launched or pulled into its window is never the user's native float, whatever mode it reports there.
        if (display == android.view.Display.DEFAULT_DISPLAY && (mode == WINDOWING_MODE_FREEFORM || mode == WINDOWING_MODE_ZOOM) &&
            dev.omalauncher.system.FreeformTasks.isNativeFloat(t.taskId, mode)
        ) {
            if (w.followed != "native") WindowLog.i(TAG, "window ${w.id} (${w.component.packageName}): its task ${t.taskId} is a floating window the user picked: left native")
            w.followed = "native"
            return false
        }
        val act = followOf(display == w.displayId, display == android.view.Display.DEFAULT_DISPLAY, mode)
        if (act == null) {
            if (display == w.displayId) w.followed = null
            return display == w.displayId
        }
        val key = "$display/$mode"
        if (w.followed == key) return true
        w.followed = key
        WindowLog.i(TAG, "window ${w.id} (${w.component.packageName}): its task ${t.taskId} went to display $display mode $mode by the system or the app: $act")
        followNow(w, t.taskId, act)
        return true
    }

    /** On [io]: [w]'s app's task in [running] (learned from its display while it's there), or null: none to follow. */
    private fun followedTask(
        w: Win,
        running: List<android.app.ActivityManager.RunningTaskInfo>,
    ): android.app.ActivityManager.RunningTaskInfo? {
        if (w.closed || w.full || w.adopt >= 0) return null
        val mine = running.filter { WebWindowDisplays.displayOf(it) == w.displayId }
        if (mine.none { it.taskId == w.taskId }) mine.firstOrNull()?.let { w.taskId = it.taskId }
        val task = w.taskId
        if (task < 0 || WebWindowDisplays.fullScreenWindow(task) == w.id) return null
        return running.firstOrNull { it.taskId == task }
    }

    /** On [io]: [follow]'s [act] for [w]'s [task]. */
    private fun followNow(
        w: Win,
        task: Int,
        act: Follow,
    ) {
        when (act) {
            Follow.BACK -> followBack(w, task)
            Follow.FULL -> {
                // As fullScreenNow, but the system already put it there: the window hidden, held as its full-screen app.
                main.post { hideFrame(w) }
                WebWindowDisplays.fullScreen(task, w.id, true)
                announce(w, true)
            }
            Follow.PIP -> main.post {
                // HACK: the page's own minimise (to the dock) stands for PiP until ww-pip's MN1/MN2 state lands here: the
                // frame hidden, never empty. Real fix: call its PiP state (the window's dock entry restores from PiP).
                hideFrame(w)
                if (!w.closed) emit("webwindows.control", mapOf("id" to w.id, "action" to "minimise"))
            }
        }
    }

    /** On [io]: [w]'s floating [task] back on its display, full screen there; the window shown where it was. */
    private fun followBack(
        w: Win,
        task: Int,
    ) {
        val ok = moveTask(task, w.displayId)
        WindowLog.i(TAG, "window ${w.id}: task $task followed back onto its display ${w.displayId}: $ok")
        if (!ok) {
            w.followed = null
            return
        }
        main.post { if (!w.closed) emit("webwindows.show", w.id) }
    }

    /** Main thread: [w]'s container hidden at once (the page drops it from "w.f" a frame later). */
    private fun hideFrame(w: Win) {
        if (w.container.isValid) SurfaceControl.Transaction().setVisibility(w.container, false).apply()
        w.shown = false
    }

    /** Task [t]'s windowing mode (WindowConfiguration, hidden: reflected), or 0 (undefined/unreadable). */
    private fun modeOf(t: android.app.TaskInfo): Int =
        runCatching {
            HiddenApi.allow()
            val c = android.app.TaskInfo::class.java.getField("configuration").get(t) as android.content.res.Configuration
            val wc = android.content.res.Configuration::class.java.getField("windowConfiguration").get(c)!!
            wc.javaClass.getMethod("getWindowingMode").invoke(wc) as Int
        }.getOrDefault(0)

    /** On [io]: [w]'s display read; empty after it had its app: read again [ORPHAN_CONFIRM_MS] later ([confirmOrphan]). */
    private fun checkOrphan(w: Win) {
        val n = tasksOn(w.displayId)
        if (n != null && n > 0) w.landed = true
        if (gone(w, n)) io.postDelayed({ confirmOrphan(w) }, ORPHAN_CONFIRM_MS)
    }

    /** On [io]: [w]'s display still empty - the window closed the bar's way (main thread). */
    private fun confirmOrphan(w: Win) {
        val again = tasksOn(w.displayId)
        if (!gone(w, again)) return
        main.post {
            if (!gone(w, again)) return@post
            WindowLog.i(TAG, "window ${w.id} (${w.component.packageName}): its app's task left display ${w.displayId} (finished, moved to another display or re-parented): window closed")
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

        /** When [open] made it (uptime ms), and when it was first on screen (0: not yet): "shown N ms after open". */
        val openedAt = SystemClock.uptimeMillis()
        @Volatile var displayAt = 0L
        var shownAt = 0L

        /** The last geometry the page gave it (main thread): applied again when the mirror arrives. */
        var geo: Geo? = null
        var downAt = 0L

        /** PZ1: the fingers on its body now (pointer id -> device px x, y; the pointer index is its place by id), on the bridge thread. */
        val fingers = java.util.TreeMap<Int, FloatArray>()

        /** Its app's content shows: the page dropped the placeholder ([liveWhenDrawn]). */
        var live = false

        /** In the page's last "w.f" and visible (main thread): only those take touches ([hit]). */
        var shown = false

        /** Its app's task (learned from its display when first needed; kept while it's a full-screen app). */
        @Volatile var taskId = -1

        /** A running task to move onto its display instead of a launch (ShellBridge.toWebWindow: an app made a window), or -1. */
        @Volatile var adopt = -1

        /** The task's "display/mode" [follow] last acted on (once per change), null while it's back in its display. */
        @Volatile var followed: String? = null

        /** Its app is a full-screen app on display 0 now ([fullScreen]): the window is hidden, its display empty. */
        @Volatile var full = false

        /** Minimised the home gesture's way ([minimise]): its task on display 0 (in PiP, or behind home); uptime then, else 0. */
        @Volatile var leftAt = 0L

        @Volatile var closed = false

        /** Its display has had its app's task (seen by [checkLanded] / [reconcile]); false again on each [launch]. */
        @Volatile var landed = false

        /** A Linux (KWin) window's source instead of a display ([LinuxSource]; docs/WEB_WINDOWS.md S6), else null. */
        var linux: LinuxSource? = null

        /** Its Linux window is full screen ([linuxFullScreen], kwin 0043): the whole screen, no bar, the page's place kept. */
        var linuxFull = false

        /** When [linuxFull] last went on (uptime ms), and since when the page's "w.f" lists it as a plain window anyway (0: not): IR1. */
        var linuxFullAt = 0L
        var fullListedAt = 0L

        /**
         * PowOS asked KWin to put it full screen ([fullScreen]) and KWin hasn't confirmed yet ("fullscreen <id> 1"): its
         * full-screen size goes to KWin only then ([fullScreenConfirmed]). Sent with the request, KWin took the size
         * before the window's own full screen and then laid it out at KWin's OUTPUT size - the desktop consumer's, still
         * the folded cover's 1116x2358 on the unfolded screen (the user, 10-30 22:19: Dolphin pillarboxed at ~1116 px).
         */
        var fullAsked = false

        /**
         * Its container hangs under [root], ordered among the page's windows by [Geo.z]. False while [fillScreen] hangs
         * it on home's surface itself (above home's buffer, at [FULL_LAYER]); [place] puts it back under the root.
         */
        var underRoot = true

        /** RS1: a resize drag's counts ([paced]), the last body size, and the fill under its app ([fillUnder]). */
        var resizing = false
        var steps = 0
        var relayouts = 0
        var lastBw = 0
        var lastBh = 0
        var fill: SurfaceControl? = null
        var fillColor = 0
        var fillUntil = 0L
        var fillPending = false
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

        /**
         * RS1: a resize drag is in progress - [cw]x[ch] px is the app's paced size (the page sends a new one at most every
         * 3 frames, ui/webwindows.tsx pace), the body only cropped and the last buffer anchored; else the body's own.
         */
        var resizing = false
        var cw = 1
        var ch = 1

        /** The theme's surface (0xAARRGGBB): what a body shows where its app hasn't drawn yet (a grow mid-resize). */
        var fill = 0xff000000.toInt()
    }

    /** The layer all windows hang under: home's window surface, under its own buffer. Made on first use (main thread). */
    private var root: SurfaceControl? = null

    private fun root(): SurfaceControl? {
        root?.takeIf { it.isValid }?.let { return it.also { rootAgain(it) } }
        val attached = web.rootSurfaceControl ?: return null.also { WindowLog.w(TAG, "home's window has no surface yet") }
        val sc = SurfaceControl.Builder().setName("powos-webwindows").build()
        val t = underHome(sc, "made") ?: return null.also { sc.release(); WindowLog.w(TAG, "home's surface refused a child") }
        t.setVisibility(sc, !underSwitcher).apply()
        root = sc
        watchSurface()
        return sc
    }

    /**
     * [r] re-parented BELOW home's own buffer, at -1: a direct child of home's window surface - the layer that holds the
     * buffer - so SurfaceFlinger draws it before that buffer. The window is an element of the page: the page is
     * transparent over its body, and every DOM element above it (another window's bar, the tile menu, popovers, the
     * dock) paints over it. Not the public `buildReparentTransaction`: that hangs it under the window's BOUNDS layer, a
     * z=0 child of the buffer layer, so a -1 there is still ABOVE the buffer - every app's pixels covered every DOM
     * element over its body (Z3, 10-30: SurfaceFlinger's composition list Wallpaper, HomeShell, Discord; Calculator's
     * keypad over Discord's bar, the tile menu opened under its own window's app).
     *
     * HACK: ViewRootImpl.getSurfaceControl is hidden (WindowBlur and GlassBlur reflect it too); without it, the public
     * bounds-layer parent is kept (and logged): windows then cover the page's DOM over them. Real fix: none public for
     * a child under a window's own buffer (SurfaceView uses the same hidden surface).
     */
    private fun underHome(
        r: SurfaceControl,
        why: String,
    ): SurfaceControl.Transaction? {
        val home = homeSurface()
        if (home != null) {
            if (rootParent != "home's buffer") WindowLog.i(TAG, "windows' root under home's buffer ($why)")
            rootParent = "home's buffer"
            return SurfaceControl.Transaction().reparent(r, home).setLayer(r, -1)
        }
        val t = web.rootSurfaceControl?.buildReparentTransaction(r) ?: return null
        if (rootParent != "bounds") WindowLog.w(TAG, "windows' root on home's bounds layer ($why): no window surface by reflection - apps cover the DOM over them")
        rootParent = "bounds"
        return t.setLayer(r, -1)
    }

    /**
     * EW1 (the user, 10-31 00:50: "Windows still don't load ... I have to full screen them"): each new window's open puts
     * the existing root under home's CURRENT window surface again and shows it unless the switcher is really up. The
     * root hangs on a native layer of home's surface taken when it was made; a surface change the callback didn't
     * report ([reattach]) left it on a dead layer, and a switcher close that never reached [switcherOpen] left it
     * hidden - either way every window afterwards was a hole showing the wallpaper (its app VISIBLE on its display)
     * while full screen, which hangs the app elsewhere, still showed. Re-parenting to the same layer is a no-op.
     */
    private fun rootAgain(r: SurfaceControl) {
        val switcher = dev.omalauncher.system.Switcher.open
        if (underSwitcher && !switcher) WindowLog.w(TAG, "windows' root was still hidden for a switcher that is gone: shown again")
        underSwitcher = switcher
        val t = underHome(r, "open") ?: return WindowLog.w(TAG, "windows' root: home has no surface to hang it on at open").let { }
        t.setVisibility(r, !underSwitcher).apply()
    }

    /** Where [root] hangs, for the log: "home's buffer" or "bounds". */
    private var rootParent = ""

    /** Home's window surface (ViewRootImpl.getSurfaceControl: the layer that holds its buffer), valid, or null. */
    private fun homeSurface(): SurfaceControl? =
        runCatching {
            HiddenApi.allow()
            val vri = web.rootSurfaceControl ?: return null
            vri.javaClass.getMethod("getSurfaceControl").invoke(vri) as SurfaceControl?
        }.onFailure { if (rootParent != "bounds") WindowLog.w(TAG, "home's window surface unreadable", it) }.getOrNull()?.takeIf { it.isValid }

    /** The switcher is up: every window's layer hidden under it (main thread). */
    private var underSwitcher = false

    /** The windows' root shown ([on]) or hidden, at once (main thread): [switcherOpen]. */
    private fun rootShown(on: Boolean) {
        underSwitcher = !on
        val t = SurfaceControl.Transaction()
        // FL3: a full-screen Linux window hangs on home's surface itself, ABOVE home's buffer ([fillScreen]), not under
        // the root: hiding the root left it over the switcher, which opened (NavGesture "gesture: Switcher", 10-30
        // 22:34) under it, unseen - the user, 22:20: "I can't open the switcher now either". Hidden with the root.
        for (w in wins.values) if (!w.underRoot && w.container.isValid) t.setVisibility(w.container, on && w.shown)
        val r = root?.takeIf { it.isValid }
        if (r == null) {
            t.apply()
            return
        }
        t.setVisibility(r, on).apply()
        WindowLog.i(TAG, "windows ${if (on) "shown again (switcher down)" else "hidden under the switcher (each is its card)"}: ${wins.size} window(s)")
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
        if (!enabled()) return -1.also { WindowLog.w(TAG, "open ${component.packageName}: $SETTING is off") }
        unresizeable(component)?.let { why ->
            // Fallback: Android's own window (the caller launches it as before; the switcher uses Android's split).
            WindowLog.w(TAG, "fallback: ${component.packageName} keeps Android's own window/split, not a web window: $why")
            // A launch held for this window (WebWindowLaunch) goes the old way now, not after its wait.
            WebWindowLaunch.refused(component.packageName)
            return -1
        }
        existingFor(component, task)?.let { return it }
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
                WindowLog.w(TAG, "window $id (${component.packageName}): no display: $error")
                main.post { drop(win, released = true) }
                return@create
            }
            win.displayId = displayId
            win.displayAt = SystemClock.uptimeMillis()
            WebWindowDisplays.add(displayId, id)
            // Closed while its display was being made: the display goes too.
            if (win.closed) return@create helper.release(displayId)
            WindowLog.i(TAG, "window $id: trusted display $displayId ${w}x$h dpi $dpi (${component.packageName})")
            main.post { scheduleReconcile() }
            io.post { mirrorWhenKnown(win, SystemClock.uptimeMillis()) }
        }
        return id
    }

    /**
     * One display per app task: [component]'s app has an Android window already - that window's id (the page raises it,
     * "webwindows.show"), never a second display. [task] (an adopt) of the window's own task: the same. Another task of
     * the app: moved into that window (its display shows the newest), unless it is a new document by design
     * (FLAG_ACTIVITY_NEW_DOCUMENT / MULTIPLE_TASK: Chrome's or Docs' own extra windows) - then a window of its own.
     * Null: none, make one.
     */
    private fun existingFor(
        component: ComponentName,
        task: Int,
    ): Int? {
        val pkg = component.packageName
        val w = wins.values.firstOrNull { it.linux == null && !it.closed && it.component.packageName == pkg } ?: return null
        if (task >= 0 && task != w.taskId && !secondTask(w, task)) return null
        WindowLog.i(TAG, "open $pkg task $task: window ${w.id} (display ${w.displayId}) has the app already: raised, no second display")
        emit("webwindows.show", w.id)
        return w.id
    }

    /**
     * [existingFor]: another task [task] of [w]'s app - false: a new document, a window of its own; true: moved into [w]
     * (when it shows on its display now).
     */
    private fun secondTask(
        w: Win,
        task: Int,
    ): Boolean {
        if (newDocument(task)) {
            WindowLog.i(TAG, "open ${w.component.packageName} task $task: a new document of the app (window ${w.id} has task ${w.taskId}): a window of its own")
            return false
        }
        val onDisplay = w.displayId >= 0 && !w.full && w.leftAt == 0L
        if (onDisplay) io.post { WindowLog.i(TAG, "open ${w.component.packageName} task $task: its second task moved into window ${w.id} (display ${w.displayId}): ${moveTask(task, w.displayId)}") }
        return true
    }

    /** Task [task] was started as a new document (FLAG_ACTIVITY_NEW_DOCUMENT / MULTIPLE_TASK): a window of its own by design. */
    private fun newDocument(task: Int): Boolean {
        @Suppress("DEPRECATION")
        val info = runCatching { context.getSystemService(android.app.ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrNull()?.firstOrNull { it.taskId == task }
        return (info?.baseIntent?.flags ?: 0) and (Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK) != 0
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
            WindowLog.i(TAG, "KWin window $kwin (${offer.appId}) again: web window ${w.id} shown where it was")
            emit("webwindows.show", w.id)
            return
        }
        if (pendingLinux.containsKey(kwin)) return
        offer.key = key
        pendingLinux[kwin] = offer
        WindowLog.i(TAG, "KWin window $kwin (${offer.appId}, \"${offer.title}\"): offered to the page as $key")
        // "ownFrame": it draws its own complete frame (Brave, Steam, GTK CSD; kwin 0046) - the page shows no bar over it.
        val own = andro.marchy.WebWindowSource.ownFrame(kwin)
        emit("webwindows.adopt", JSONObject().put("kwin", kwin).put("key", key).put("label", offer.label).put("ownFrame", own))
        main.postDelayed({
            pendingLinux.remove(kwin)?.let { p ->
                WindowLog.w(TAG, "fallback: KWin window $kwin (${p.appId}): the page made no web window in $LINUX_ADOPT_MS ms, a task instead")
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
        val p = pendingLinux.remove(kwin) ?: return -1.also { WindowLog.w(TAG, "open KWin window $kwin: not offered (or taken already)") }
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
                WindowLog.e(TAG, "window $id (KWin window $kwin): consumer did not start")
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
            WindowLog.i(TAG, "window $id: KWin window $kwin (${p.appId}) consumer up, buffers ${bw}x$bh, body ${win.w}x${win.h}")
            liveWhenDrawn(win)
        }
        andro.marchy.WebWindowSource.size(kwin, w, h)
        // KWin focused the new window (its task's start): a touch back on the window it came from focuses that again.
        linuxFocused = kwin
        WindowLog.i(TAG, "window $id: KWin window $kwin (${p.appId}) as a web window, ${w}x$h")
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
            WindowLog.i(TAG, "window ${w.id}: closed with its app $key (the app menu's close)")
            drop(w)
        }
        return ws.isNotEmpty()
    }

    /** KWin closed window [kwin] (main thread): its web window goes, nothing told back. */
    fun linuxClosed(kwin: Int) {
        pendingLinux.remove(kwin)
        val w = wins.values.firstOrNull { it.linux?.kwin == kwin } ?: return
        w.linux?.kwinClosed = true
        WindowLog.i(TAG, "KWin closed window $kwin: web window ${w.id} goes")
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
        WindowLog.i(TAG, "close window ${w.id}: KWin window ${src.kwin} ${if (handBack) "handed back as a task" else "quit (KWin closes it, then ends the app)"}")
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
                WindowLog.w(TAG, "mirrorDisplay(${win.displayId}) refused for PowOS's uid: ${e.cause ?: e}")
                main.post { drop(win) }
                return
            }
        val waited = SystemClock.uptimeMillis() - since
        when {
            out != null -> {
                WindowLog.i(TAG, "window ${win.id}: display ${win.displayId} mirrored after $waited ms (PowOS uid)")
                main.post { attach(win, out) }
            }
            waited > MIRROR_WAIT_MS -> {
                WindowLog.w(TAG, "window ${win.id}: display ${win.displayId} not known to WM after $waited ms")
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
        win.geo?.let {
            place(t, win, it)
            shown(win, it)
        }
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
        WindowLog.i(TAG, "window ${win.id}: app's task $task ${if (ok) "moved onto display ${win.displayId}" else "NOT moved: launched there instead"}")
        if (ok) win.taskId = task else main.post { if (!win.closed) launch(win) }
    }

    // ---- geometry ------------------------------------------------------------------------------------------------------

    /**
     * "w.f <frame> <dpr> <n> [<id> <frame x y w h> <body x y w h> <clip l t r b> <radius> <visible> <alpha> <scale>
     * <maximised> <titleEnd> <controls>] * n" (viewport CSS px, measured after transforms; bottom window first: its index
     * is its z), on the port's thread. Every window the page shows is in it; one that isn't is hidden. Applied on the
     * draw that shows page frame <frame> ([FrameSync.next]: the window's next draw, not the visual-state callback's
     * draw a frame or more later).
     */
    fun frameCommand(
        rest: String,
        direct: Boolean = false,
    ) {
        val (frame, geos, pageMs) = parse(rest) ?: return
        val cookie = sync.receive(frame)
        via = if (direct) "direct" else "port"
        sync.next(frame, cookie, pageMs) { apply(frame, geos) }
    }

    @Volatile private var lastDpr = 1f

    /** Sums of the page's share (rAF frame time to its send) and the hop (send to receipt), ms, over [rxSplit] frames. */
    @Volatile private var rxPage = 0.0
    @Volatile private var rxHop = 0.0
    @Volatile private var rxSplit = 0

    /** How the last "w.f" came: "direct" (ShellNative's geometry interface, a binder thread) or "port" (main first). */
    @Volatile private var via = "port"

    /** The frame id, the windows, and the page frame's time (epoch ms; NaN when the page didn't stamp it). */
    private fun parse(rest: String): Triple<Long, List<Geo>, Double>? =
        try {
            val t = rest.trim().split(' ')
            val dpr = t[1].toFloat()
            lastDpr = dpr
            // The WebView's place in its window (none for home: full screen): geometry is in the window surface's space.
            val c = Cursor(t, 3, dpr, IntArray(2).also(web::getLocationInWindow))
            val geos = List(t[2].toInt()) { z -> entry(c, z) }
            val page = t.getOrNull(c.i)?.toDoubleOrNull() ?: Double.NaN
            // The page's send time (its second stamp, wall-clock ms): "rx=" split into the page's share and the hop.
            t.getOrNull(c.i + 1)?.toDoubleOrNull()?.takeIf { !page.isNaN() }?.let { sent ->
                rxPage += sent - page
                rxHop += System.currentTimeMillis() - sent
                rxSplit++
            }
            Triple(t[0].toLong(), geos, page)
        } catch (e: RuntimeException) {
            WindowLog.w(TAG, "w.f: bad geometry ($e)")
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
            resizing = c.word() == "1"
            val pw = c.word().toFloat()
            val ph = c.word().toFloat()
            appSize(pw * c.dpr, ph * c.dpr)
            fill = (0xff000000.toInt() or c.word().toInt(16))
        }

    /**
     * [Geo.bw]/[Geo.bh] and [Geo.cw]/[Geo.ch] from the page's app size [pw] x [ph] (its CSS layout size x dpr: device
     * px, rounded ONCE here). Never derived from the measured (transformed, rounded) body and its 2-decimal scale when
     * the page gave the size: that moved by a pixel whenever an ancestor's transform did, and each pixel was a display
     * resize - YouTube flickered after a rescale (10-30). During a drag the body's measured size stays the step count's.
     */
    private fun Geo.appSize(
        pw: Float,
        ph: Float,
    ) {
        val mw = Math.round(body.width() / scale).coerceAtLeast(1)
        val mh = Math.round(body.height() / scale).coerceAtLeast(1)
        val gw = if (pw > 0) Math.round(pw).coerceAtLeast(1) else mw
        val gh = if (ph > 0) Math.round(ph).coerceAtLeast(1) else mh
        bw = if (resizing) mw else gw
        bh = if (resizing) mh else gh
        cw = gw
        ch = gh
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
            // No invalidate: the page's commit draws ([FrameSync.next]).
            attached.applyTransactionOnDraw(t)
        }
        logFrame(frame, geos)
        orderCheckSoon(geos)
    }

    // ---- the layer order check: SurfaceFlinger's composition against the page's z ----------------------------------------

    /** The page's z order of the shown windows (bottom first) last checked, and when the last check ran (uptime ms). */
    private var checkedOrder: List<Int> = emptyList()
    private var lastOrderCheck = 0L
    @Volatile private var orderCheckBroken = false
    @Volatile private var orderCheckOk = false
    @Volatile private var orderCheckViaRoot = false

    /**
     * After [apply]: when the shown windows' page order changed (a raise, an open), or [ORDER_RECHECK_MS] after the last
     * check while two or more are shown, SurfaceFlinger's last composition is compared with the page's order
     * ([orderCheck]) a little later, once it has composed. Not every frame: a SurfaceFlinger dump takes its locks.
     */
    private fun orderCheckSoon(geos: List<Geo>) {
        if (orderCheckBroken) return
        val order = geos.filter { g -> g.visible && wins[g.id]?.let { it.shown && !it.linuxFull && it.mirror != null } == true }.sortedBy { it.z }.map { it.id }
        val now = SystemClock.uptimeMillis()
        if (order.isEmpty()) {
            checkedOrder = order
            return
        }
        if (order == checkedOrder && now - lastOrderCheck < ORDER_RECHECK_MS) return
        checkedOrder = order
        lastOrderCheck = now
        val names = order.associateWith { id -> wins[id]?.let(::layerKey) ?: "" }
        io.postDelayed({ orderCheck(order, names) }, ORDER_CHECK_DELAY_MS)
    }

    /** What names [win]'s content in SurfaceFlinger's output: its Linux layer, or its app's package (the mirror's clones). */
    private fun layerKey(win: Win): String = if (win.linux != null) "powos-ww-${win.id}-linux" else "${win.component.packageName}/"

    /** On [io]: SurfaceFlinger's output layer order for the shown display against the page's [order] (bottom first). */
    private fun orderCheck(
        order: List<Int>,
        names: Map<Int, String>,
    ) {
        val dump = surfaceFlingerDump() ?: return
        val layers = outputLayers(dump)
        if (layers == null) {
            if (!dump.contains("Output Layer")) {
                orderCheckBroken = true
                WindowLog.w(TAG, "layer order check: the dump has no output layers (${dump.take(120).replace('\n', ' ')}); off")
            }
            return
        }
        val at = order.associateWith { id -> names[id]?.takeIf { it.isNotEmpty() }?.let { n -> layers.indexOfFirst { it.contains(n) } } ?: -1 }
        val home = layers.indexOfFirst { it.contains("HomeShell") }
        val divergence = orderDivergence(order, at) ?: overHome(at, home)
        if (divergence == null) {
            if (!orderCheckOk) WindowLog.i(TAG, "layer order check: ok - page (bottom first) ${order.joinToString()} at output layers ${order.map { at[it] }}, home's buffer at $home (logged once)")
            orderCheckOk = true
            return
        }
        WindowLog.w(
            TAG,
            "layer order != page order: $divergence; page (bottom first) ${order.joinToString { "$it(${names[it]})" }}, " +
                "SurfaceFlinger's output: ${layers.withIndex().joinToString { (i, n) -> "$i ${n.take(60)}" }} (home's buffer at $home)",
        )
    }

    /** Z3: every window's content under home's buffer ([home]: its output layer), or the DOM over it is covered; null: so. */
    private fun overHome(
        at: Map<Int, Int>,
        home: Int,
    ): String? {
        val over = at.filterValues { it > home && home >= 0 }.keys
        return if (over.isEmpty()) null else "window(s) ${over.joinToString()} drawn OVER home's buffer (layer $home): the page's DOM over them is covered"
    }

    /**
     * On [io]: SurfaceFlinger's dump, or null (the check then off, logged). The app's uid gets "Permission Denial: can't
     * dump SurfaceFlinger" (10-30, why the check never said anything): root's dump then, logged once.
     */
    private fun surfaceFlingerDump(): String? =
        runCatching {
            val p = ProcessBuilder("dumpsys", "SurfaceFlinger").redirectErrorStream(true).start()
            val own = p.inputStream.bufferedReader().use { it.readText() }.also { p.waitFor() }
            if (!own.startsWith("Permission Denial")) return@runCatching own
            if (!orderCheckViaRoot) WindowLog.i(TAG, "layer order check: SurfaceFlinger refuses the app's uid, read as root")
            orderCheckViaRoot = true
            andro.marchy.RootShell.run("dumpsys SurfaceFlinger", null, ROOT_DUMP_MS).output
        }.getOrElse {
            orderCheckBroken = true
            WindowLog.w(TAG, "layer order check: no SurfaceFlinger dump ($it); off")
            null
        }

    private fun placeAll(
        t: SurfaceControl.Transaction,
        geos: List<Geo>,
    ) {
        // A full-screen Linux window keeps its own place ([linuxFullScreen]): neither placed nor hidden by the page.
        val shown = wins.values.filter { it.linuxFull }.mapTo(HashSet()) { it.id }
        pageAgrees(geos)
        for (g in geos.filterNot { it.id in shown }) {
            val win = wins[g.id] ?: continue
            shown += g.id
            win.shown = g.visible
            win.geo = g
            place(t, win, g)
            shown(win, g)
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
     * arrived when this one was applied (0 now: each applies before the next draw). "lag": applies by window draws
     * between the frame's receipt and its apply ([FrameSync.lag]: 0 = on the draw that shows its page frame, 1, 2, 3+),
     * the content trailing the DOM chrome by that many frames (docs/WEB_WINDOWS.md "Measured lag"). "pf": the same counted
     * from the page frame itself ([FrameSync.pageLag]: catches a draw before the message reached the host), "rx": the
     * mean ms from the page frame to the host's receipt, "via": the channel the last one came on.
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
        WindowLog.i(TAG, "w.f f$frame behind=$behind (${behindFrames}/$appliedFrames applies behind) lag=${sync.lag.joinToString("/")} pf=${sync.pageLag.joinToString("/")} rx=${"%.1f".format(sync.receiptMs / sync.pageLag.sum().coerceAtLeast(1))}ms (page ${"%.1f".format(rxPage / rxSplit.coerceAtLeast(1))} + hop ${"%.1f".format(rxHop / rxSplit.coerceAtLeast(1))}) via=$via " + geos.joinToString { "${it.id}@${it.body.toShortString()} clip ${it.clip.toShortString()} z${it.z} ${if (it.visible) "shown" else "hidden"}" })
    }

    private var lastPlaceLog = 0L
    private var behindFrames = 0
    private var appliedFrames = 0

    /**
     * [win] on screen for the first time (frame placed by the page's geometry and its display mirrored): the open's
     * latency logged, the number the next regression shows in (2026-10-30: Chrome's window 15-20 s after the tap).
     */
    private fun shown(
        win: Win,
        g: Geo,
    ) {
        if (win.shownAt != 0L || !g.visible || win.mirror == null) return
        win.shownAt = SystemClock.uptimeMillis()
        val ms = win.shownAt - win.openedAt
        val display = if (win.displayAt > 0) "display after ${win.displayAt - win.openedAt} ms" else "no display (KWin)"
        val line = "window ${win.id} (${win.linux?.offer?.appId ?: win.component.packageName}): shown $ms ms after open ($display)"
        if (ms > SHOWN_SLOW_MS) WindowLog.w(TAG, "$line - slow, over $SHOWN_SLOW_MS ms") else WindowLog.i(TAG, line)
    }


    /** [g] into [t]: the container at the body (cropped to its clip, rounded, ordered, faded, shown), the mirror in it. */
    private fun place(
        t: SurfaceControl.Transaction,
        win: Win,
        g: Geo,
    ) {
        val c = win.container
        if (!c.isValid) return
        underRoot(t, win)
        frameAt(t, win, g)
        cornerRadius(t, c, g.radius)
        // Every window's z is its page order, a Linux one's as an Android one's: one parent (the root), one z each.
        t.setLayer(c, g.z)
        t.setAlpha(c, g.alpha)
        // Hidden is the layer, never the display's surface (a null surface stops the app).
        t.setVisibility(c, g.visible && !g.clip.isEmpty && win.mirror != null)
        fillUnder(t, win, g)
        val released = paced(win, g)
        resizeContent(win, g.cw, g.ch)
        released?.let { counts -> if (win.linux == null && win.displayId >= 0) helper.settle(win.displayId, counts) else WindowLog.i(TAG, "$counts (Linux: no settle measure)") }
    }

    /**
     * RS1's counts: each step of a resize drag (a new body size) and each real resize ([resizeContent]) while it lasts;
     * on release (the first geometry without [Geo.resizing]) the final resize goes out and the settle is measured -
     * "window N: resize: R relayouts for S steps, settled X ms after release" (Android: the helper's display frames,
     * [Helper.settle]; Linux: no frame signal here, the counts only).
     */
    private fun paced(
        win: Win,
        g: Geo,
    ): String? {
        var released: String? = null
        if (g.resizing) {
            pacedStep(win, g)
        } else if (win.resizing) {
            win.resizing = false
            val final = if (g.bw != win.w || g.bh != win.h) 1 else 0
            released = "window ${win.id}: resize: ${win.relayouts + final} relayouts for ${win.steps} steps"
        }
        win.lastBw = g.bw
        win.lastBh = g.bh
        return released
    }

    /** One geometry of a resize drag: a step when the body changed, a relayout when the app's paced size did. */
    private fun pacedStep(
        win: Win,
        g: Geo,
    ) {
        if (!win.resizing) {
            win.resizing = true
            win.steps = 0
            win.relayouts = 0
        }
        if (g.bw != win.lastBw || g.bh != win.lastBh) win.steps++
        if (g.cw != win.w || g.ch != win.h) win.relayouts++
    }

    /**
     * RS1: the theme's surface under the app's layer in [win]'s container - what a grow shows until the app draws at
     * its new size (its last buffer anchored top left over it, never stretched). A 1x1 buffer scaled past any body; the
     * container's crop clips it. Shown only while resizing and [FILL_HOLD_MS] after (an app's own translucency is never
     * filled otherwise).
     */
    private fun fillUnder(
        t: SurfaceControl.Transaction,
        win: Win,
        g: Geo,
    ) {
        val now = SystemClock.uptimeMillis()
        if (g.resizing) win.fillUntil = now + FILL_HOLD_MS
        val on = now < win.fillUntil
        if (!on && win.fill == null) return
        val f = win.fill ?: newFill(win) ?: return
        if (win.fillColor != g.fill) paintFill(win, f, g.fill)
        t.setLayer(f, -1)
        t.setVisibility(f, on)
        if (on && !win.fillPending) {
            win.fillPending = true
            main.postDelayed({ win.fillPending = false; hideFill(win) }, FILL_HOLD_MS + 16)
        }
    }

    /** [win]'s fill hidden once its hold ran out with no new geometry (the page sends none when nothing moved). */
    private fun hideFill(win: Win) {
        val f = win.fill?.takeIf { it.isValid } ?: return
        if (SystemClock.uptimeMillis() < win.fillUntil) return
        SurfaceControl.Transaction().setVisibility(f, false).apply()
    }

    private fun newFill(win: Win): SurfaceControl? {
        if (!win.container.isValid) return null
        val f = SurfaceControl.Builder().setName("powos-ww-${win.id}-fill").setParent(win.container).setBufferSize(1, 1).setOpaque(true).setHidden(true).build()
        SurfaceControl.Transaction().setScale(f, FILL_SCALE, FILL_SCALE).apply()
        win.fill = f
        return f
    }

    private fun paintFill(
        win: Win,
        f: SurfaceControl,
        argb: Int,
    ) {
        win.fillColor = argb
        val surface = android.view.Surface(f)
        runCatching {
            val canvas = surface.lockCanvas(null)
            canvas.drawColor(argb)
            surface.unlockCanvasAndPost(canvas)
        }.onFailure { WindowLog.w(TAG, "window ${win.id}: fill not drawn", it) }
        surface.release()
    }

    /**
     * [win]'s container back under [root] when it hangs elsewhere (home's surface, left by [fillScreen]): a container
     * outside the root is ordered against home's surface's children, not against the other windows, so its [Geo.z]
     * meant nothing there (docs/WEB_WINDOWS.md S6). A no-op for one under the root already.
     */
    private fun underRoot(
        t: SurfaceControl.Transaction,
        win: Win,
    ) {
        if (win.underRoot || win.linuxFull) return
        val r = root?.takeIf { it.isValid } ?: return
        if (!win.container.isValid) return
        t.reparent(win.container, r)
        win.underRoot = true
        WindowLog.w(TAG, "window ${win.id}: its layer was outside the windows' root (left by full screen): back under it, at the page's z")
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
        }.onFailure { WindowLog.w(TAG, "no setCornerRadius: square windows", it) }.getOrNull()
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
        }.onFailure { WindowLog.w(TAG, "no surface callback: re-attached on window visibility instead", it) }.isSuccess

    /** One call on the surface callback's Proxy (UI thread). */
    private fun surfaceCall(
        proxy: Any,
        name: String,
        args: Array<out Any?>?,
    ): Any? =
        when (name) {
            "surfaceCreated", "surfaceReplaced" -> reattach(args?.getOrNull(0) as? SurfaceControl.Transaction, name).let { null }
            "surfaceDestroyed" -> WindowLog.i(TAG, "home's surface destroyed: ${wins.size} window(s) wait for the next one").let { null }
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
        val re = underHome(r, "home's surface $why") ?: run { WindowLog.w(TAG, "home's surface $why: no surface to re-attach to"); return }
        if (t != null) t.merge(re) else re.apply()
        WindowLog.i(TAG, "home's surface $why: windows' root re-attached (${wins.size} window(s): ${wins.values.joinToString { "${it.id}@d${it.displayId}" }})")
        for (w in wins.values) if (w.displayId >= 0 && w.mirror?.isValid == false) io.post { remirror(w) }
        // Every window's whole layer state again, from the page's next frame (not only when its geometry next changes).
        resend("home's surface $why")
    }

    /** On [io]: [w]'s display mirrored again into its container (its mirror lost), the app left running as it is. */
    private fun remirror(w: Win) {
        if (w.closed) return
        val out = runCatching { mirror(w.displayId) }.getOrNull() ?: run { WindowLog.w(TAG, "window ${w.id}: display ${w.displayId} not mirrored again"); return }
        main.post {
            if (w.closed || !w.container.isValid) return@post out.release()
            w.mirror?.release()
            w.mirror = out
            val t = SurfaceControl.Transaction().reparent(out, w.container).setLayer(out, 0).setVisibility(out, true).setCrop(out, Rect(0, 0, 0, 0))
            w.geo?.let { place(t, w, it) }
            t.apply()
            WindowLog.i(TAG, "window ${w.id}: display ${w.displayId} mirrored again")
            resend("window ${w.id} mirrored again")
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
                    WindowLog.i(TAG, "window ${e.id}: ${if (e.side < 0) "top" else "bottom"} edge pull: leaves full screen")
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
        WindowLog.i(TAG, "window ${w.id}: $why: leaves full screen")
        return toWindow(w.id)
    }

    /** The full-screen Linux window, unless the switcher is up, else null. */
    private fun fullLinux(): Win? {
        if (underSwitcher) return null
        val w = wins.values.firstOrNull { it.linuxFull && it.linux != null } ?: return null
        // IR1: a stale full screen (its window closed, its layer or consumer gone, KWin closed it) never takes touches.
        val why = staleFull(w) ?: return w
        if (staleFullLogged != w.id) {
            staleFullLogged = w.id
            WindowLog.w(TAG, "IR1: window ${w.id} is marked full screen but $why: its touches go to home's page")
            // The page's model wins: back in its window, as the page shows it.
            if (w.fullListedAt != 0L && !w.closed) main.post { linuxFullScreen(w, false) }
        }
        return null
    }

    /**
     * The page's "w.f" against the host's windows: an id the host has no more is told closed ([staleInPage]); a
     * full-screen Linux window it lists as a plain window (its "webwindows.full" lost, a page reload) is marked since
     * when, for [fullLinux]'s IR1 check.
     */
    private fun pageAgrees(geos: List<Geo>) {
        val listed = geos.mapTo(HashSet()) { it.id }
        listed.filterNot { it in wins }.forEach(::staleInPage)
        val now = SystemClock.uptimeMillis()
        wins.values.filter { it.linuxFull }.forEach { w -> w.fullListedAt = if (w.id !in listed) 0L else w.fullListedAt.takeIf { it != 0L } ?: now }
    }

    /** The window [fullLinux] last refused (logged once). */
    private var staleFullLogged = -1

    /** Why full-screen Linux window [w] must not take touches (IR1), or null: it may. */
    private fun staleFull(w: Win): String? {
        val src = w.linux ?: return "not a Linux window"
        val now = SystemClock.uptimeMillis()
        val listed = w.fullListedAt != 0L && now - w.fullListedAt > STALE_FULL_MS && now - w.linuxFullAt > STALE_FULL_MS
        return when {
            w.closed -> "closed"
            !w.container.isValid -> "its layer is gone"
            src.kwinClosed -> "KWin closed it"
            src.handle == 0L -> "its consumer is stopped"
            listed -> "the page shows it as a plain window (not full screen) for ${now - w.fullListedAt} ms"
            else -> null
        }
    }

    /** Ids in the page's "w.f" this host has no window for (each told once). */
    private val staleIds = HashSet<Int>()

    /** The page's "w.f" lists window [id], which the host has no more: the page drops it ("webwindows.closed"). */
    private fun staleInPage(id: Int) {
        if (id < 0 || !staleIds.add(id)) return
        WindowLog.w(TAG, "window $id is in the page's w.f but not the host's: the page told it is closed")
        emit("webwindows.closed", id)
    }

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
        WindowLog.i(TAG, "window ${win.id}: gesture to KWin window ${src.kwin}${g?.let { " (body ${it.body.toShortString()} x${it.scale})" } ?: ""}${if (src.handle == 0L) ": its consumer isn't up, dropped" else ""}")
        gesture?.let { linuxInput(win, it) }
    }

    /**
     * [forward] for a Linux window: a DOWN claims the native gesture ([linuxClaim]); a "cancel" (the page ended the press
     * unfinished: a second finger made it the window's pinch) gives KWin a CANCEL and home the rest ([linuxRelease]).
     */
    private fun forwardLinux(
        w: Win,
        action: String,
    ): Boolean {
        if (action == "down") linuxClaim(w)
        if (action == "cancel") main.post { linuxRelease(w) }
        return true
    }

    /** [win]'s claim of the current gesture ended early ([forward] "cancel"): KWin gets a CANCEL, home keeps the rest. */
    private fun linuxRelease(win: Win) {
        if (linuxTouch !== win) return
        val g = gesture
        if (g == null) {
            linuxTouch = null
            return
        }
        val ev = MotionEvent.obtain(g).apply { action = MotionEvent.ACTION_CANCEL }
        try {
            linuxInput(win, ev)
        } finally {
            ev.recycle()
        }
        linuxTouch = null
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
            // Full screen: the window is at its full-screen place (below the status bar, [fullScreenArea]), 1:1.
            val area = fullScreenArea()
            andro.marchy.WebWindowSource.touch(src.handle, ev, at[0] - area.left.toFloat(), at[1] - area.top.toFloat(), 1f)
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
        WindowLog.i(TAG, "window ${w.id}: live (its content shows; the page drops the placeholder)")
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
        at: BodyTouch,
    ): Boolean {
        val w = wins[id] ?: return false
        return forward(w, action, at)
    }

    /** A body touch's place (CSS px from the body's top-left, unscaled) and finger (PZ1: 0, 1, ... of one gesture). */
    data class BodyTouch(val x: Double, val y: Double, val finger: Int = 0)

    /**
     * A body touch to [w]'s app: Linux - a DOWN claims the native gesture for KWin ([linuxClaim]; its moves and UP
     * come from the gesture itself, every pointer); Android - injected on its display (v0; S4: the injector). Both
     * focus their window: KWin's "focus", or the injected touch moving the top focused display to the window's.
     * PZ1: every finger of a body gesture is [pointer] (0, 1, ...): Android gets ONE multi-touch gesture (a second
     * finger's DOWN is ACTION_POINTER_DOWN, every MOVE carries every finger), so a pinch in Chrome zooms its page; a
     * Linux window already gets every native pointer from its claim, so only finger 0 claims.
     */
    private fun forward(
        w: Win,
        action: String,
        at: BodyTouch,
    ): Boolean {
        if (w.linux != null) return if (at.finger == 0 || action == "cancel") forwardLinux(w, action) else true
        if (w.displayId < 0) return false
        val px = (at.x * density()).toFloat()
        val py = (at.y * density()).toFloat()
        val act = fingerAction(w, action, at.finger, px to py) ?: return true
        val pts = fingersSent(w, act, at.finger)
        // The injector: the shell-uid helper (holds INJECT_EVENTS), one line per event over its stdin - no process per
        // touch. The fallbacks below only when it can't be reached.
        if (helper.touch(w, act, pts)) {
            if (act != MotionEvent.ACTION_MOVE) WindowLog.i(TAG, "input: window ${w.id} $action finger ${at.finger} of ${pts.size} at ${px.toInt()},${py.toInt()} -> display ${w.displayId} (helper)")
            return true
        }
        WindowLog.w(TAG, "input: window ${w.id} $action -> display ${w.displayId}: helper unreachable, falling back")
        val props = Array(pts.size) { i -> MotionEvent.PointerProperties().apply { id = pts[i].first; toolType = MotionEvent.TOOL_TYPE_FINGER } }
        val coords = Array(pts.size) { i -> MotionEvent.PointerCoords().apply { x = pts[i].second; y = pts[i].third; pressure = 1f; size = 1f } }
        injectFallback(w, MotionEvent.obtain(w.downAt, SystemClock.uptimeMillis(), act, pts.size, props, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0))
        return true
    }

    /** PZ1: every finger [act] carries (id, x, y), then the lifted ones dropped from [Win.fingers]. */
    private fun fingersSent(
        w: Win,
        act: Int,
        finger: Int,
    ): List<Triple<Int, Float, Float>> {
        val pts = w.fingers.entries.map { (id, p) -> Triple(id, p[0], p[1]) }
        when (act and MotionEvent.ACTION_MASK) {
            MotionEvent.ACTION_POINTER_UP -> w.fingers.remove(finger)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> w.fingers.clear()
        }
        return pts
    }

    /**
     * PZ1: finger [finger] of [w]'s body gesture at [at] (device px) into [Win.fingers]: the MotionEvent action for it (a
     * second finger's down ACTION_POINTER_DOWN with its pointer index, its up ACTION_POINTER_UP), or null: nothing to
     * send (a finger the app never got a down for, a cancel with none down).
     */
    private fun fingerAction(
        w: Win,
        action: String,
        finger: Int,
        at: Pair<Float, Float>,
    ): Int? {
        val f = w.fingers
        val index = { f.headMap(finger).size shl MotionEvent.ACTION_POINTER_INDEX_SHIFT }
        if (action == "down") return fingerDown(w, finger, at) ?: (MotionEvent.ACTION_POINTER_DOWN or index())
        if (action != "move" && action != "up") return if (f.isEmpty()) null else MotionEvent.ACTION_CANCEL
        val p = f[finger] ?: return null
        p[0] = at.first
        p[1] = at.second
        return when {
            action == "move" -> MotionEvent.ACTION_MOVE
            f.size == 1 -> MotionEvent.ACTION_UP
            else -> MotionEvent.ACTION_POINTER_UP or index()
        }
    }

    /** [fingerAction]'s down: ACTION_DOWN for the gesture's first finger (its start), null for a later one. */
    private fun fingerDown(
        w: Win,
        finger: Int,
        at: Pair<Float, Float>,
    ): Int? {
        val first = w.fingers.isEmpty()
        if (first) {
            w.downAt = SystemClock.uptimeMillis()
            androidGesture = true
            main.post { homeIme(false) }
        }
        w.fingers[finger] = floatArrayOf(at.first, at.second)
        return if (first) MotionEvent.ACTION_DOWN else null
    }

    /** Without the helper: PowOS's own injectInputEvent (refused without INJECT_EVENTS), else root `input` per event. */
    private fun injectFallback(
        w: Win,
        ev: MotionEvent,
    ) {
        try {
            if (injectWorks != false && injectReflect(w.displayId, ev)) {
                if (injectWorks == null) WindowLog.i(TAG, "input path: InputManager.injectInputEvent (reflection, setDisplayId)")
                injectWorks = true
                return
            }
            if (injectWorks != false) WindowLog.i(TAG, "input path: root `input -d <id> motionevent` (reflection refused)")
            injectWorks = false
            injectRoot(w.displayId, ev)
        } finally {
            ev.recycle()
        }
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
        WindowLog.i(TAG, "home's window ${if (on) "takes the keyboard again" else "leaves the keyboard to the web window's app"}")
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
        dev.omalauncher.system.Tasks.logRemove("close", w.taskId, "web window $id (${w.component.packageName}, display ${w.displayId})")
        val full = w.full || w.leftAt != 0L
        drop(w)
        // Its app's task off the display by now (a move in flight - full screen, a minimise, PiP - ran before the close's
        // removeTasks): it goes with the window all the same. Queued after drop's own removals on [io].
        val app = w.taskId
        if (w.linux == null && app >= 0 && !full) io.post { if (taskAlive(app)) removeTask(app, "app of window $id, off its display at the close") }
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
        logDrop(w, released)
        dropLinux(w, handBack)
        WindowLog.i(TAG, "close window ${w.id} (${w.component.packageName}, display ${w.displayId}, task ${w.taskId}${if (w.full) ", full screen" else ""}): 1/4 layers off")
        releaseLayers(w)
        main.post { publishBars() }
        val displayId = w.displayId
        WebWindowDisplays.remove(displayId)
        WebWindowDisplays.windowGone(w.id)
        // A full-screen app out of this window (its task on display 0 now): it goes with the window.
        val fullTask = w.taskId.takeIf { (w.full || w.leftAt != 0L) && it >= 0 }
        if (fullTask != null) io.post { removeTask(fullTask, "full screen / minimised (PiP) app of window ${w.id}") }
        if (displayId >= 0 && !released) {
            io.post {
                // DESTROY_CONTENT_ON_REMOVAL finishes the activities but leaves the task in recents (S0): removed first.
                removeTasks(displayId)
                WindowLog.i(TAG, "close window ${w.id}: 3/4 display $displayId released")
                helper.release(displayId)
            }
        }
        WindowLog.i(TAG, "close window ${w.id}: 2/4 layers gone (container, mirror), page told (webwindows.closed) - 4/4")
        emit("webwindows.closed", w.id)
    }

    private fun logDrop(
        w: Win,
        released: Boolean,
    ) {
        val gone = if (released) ", display gone" else ""
        dev.omalauncher.system.Tasks.logRemove("drop", w.taskId, "web window ${w.id} (${w.component.packageName}, display ${w.displayId}$gone${stateOf(w)})")
    }

    /** ", full screen" / ", minimised" / "": [w]'s app's state for a log line. */
    private fun stateOf(w: Win): String =
        when {
            w.full -> ", full screen"
            w.leftAt != 0L -> ", minimised"
            else -> ""
        }

    /** [w]'s layers (mirror, frame, container) off the screen in one transaction, then released. */
    private fun releaseLayers(w: Win) {
        val t = SurfaceControl.Transaction()
        w.mirror?.let { if (it.isValid) t.reparent(it, null) }
        if (w.container.isValid) t.reparent(w.container, null)
        t.apply()
        w.fill?.release()
        w.fill = null
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
                dev.omalauncher.system.Tasks.logRemove("removeTask", id, "every task on closed web window display $displayId", removes = true)
                val ok = runCatching { remove.invoke(atm, id) as Boolean }.getOrDefault(false)
                WindowLog.i(TAG, "display $displayId: task $id removed=$ok")
            }
        }.onFailure { WindowLog.w(TAG, "display $displayId: its tasks not removed (they stay in recents)", it) }
    }

    private fun removeTask(
        id: Int,
        why: String,
    ) {
        dev.omalauncher.system.Tasks.logRemove("removeTask", id, why, removes = true)
        val ok = runCatching { atm().javaClass.getMethod("removeTask", Int::class.javaPrimitiveType).invoke(atm(), id) as Boolean }.getOrDefault(false)
        WindowLog.i(TAG, "task $id removed=$ok ($why)")
    }

    // ---- minimise: a home gesture's lifecycle (MN1/MN2) -------------------------------------------------------------------

    /**
     * MN1 (the user, 2026-10-30 22:52: "Click the minimize button on for example YouTube. It should act as if I swiped
     * home on it ... If I swipe home on YouTube it's activating this picture in picture floating YouTube thing"): the
     * page's minimise of Android window [id] (bar button, dock toggle, a tile dropped to the dock). An app whose top
     * activity declares picture-in-picture gets exactly a home swipe: its task moved to display 0, then home started
     * there - a user-initiated start, so the app pauses as the user leaving (onUserLeaveHint, onPause, onStop) and may
     * enter PiP (enterPictureInPictureMode from the hint, or auto-enter): native PiP, draggable, over home and windows.
     * Display 0 because Android's PiP is the pinned task of the display the activity is on - entered on the window's
     * own (hidden) display it would never show. An app without PiP is just hidden, as before (moving it would cost a
     * relayout for nothing). The window keeps its display (empty meanwhile) and frame: [restore] / [checkLeft] (PiP
     * expanded, its switcher card opened) put the app back in it (MN2). Main thread.
     */
    fun minimise(id: Int): Boolean {
        val w = wins[id] ?: return false
        if (w.linux != null || w.full || w.leftAt != 0L || w.displayId < 0) return true
        io.post { leaveNow(w) }
        return true
    }

    /** On [io]: [minimise]'s home gesture for [w]'s task. */
    private fun leaveNow(w: Win) {
        if (w.closed || w.leftAt != 0L) return
        val task = taskOn(w.displayId) ?: return Unit.also { WindowLog.w(TAG, "window ${w.id}: no task on display ${w.displayId} to minimise") }
        val top = taskInfo(task)?.topActivity
        if (top == null || !supportsPip(top)) {
            WindowLog.i(TAG, "window ${w.id}: minimised (${top?.flattenToShortString()} has no picture-in-picture: just hidden)")
            return
        }
        w.taskId = task
        w.leftAt = android.os.SystemClock.uptimeMillis()
        // Known as its window's BEFORE it lands on display 0: the old path's adopt must never float it, the switcher's
        // card opens it as a task ([checkLeft] then brings it back into its window).
        WebWindowDisplays.fullScreen(task, w.id, true)
        if (!moveTask(task, android.view.Display.DEFAULT_DISPLAY)) {
            WebWindowDisplays.fullScreen(task, w.id, false)
            w.leftAt = 0L
            WindowLog.w(TAG, "window ${w.id}: minimise's move to display 0 FAILED: just hidden")
            return
        }
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val ok = runCatching { context.startActivity(home, ActivityOptions.makeBasic().setLaunchDisplayId(android.view.Display.DEFAULT_DISPLAY).toBundle()) }
            .onFailure { WindowLog.w(TAG, "window ${w.id}: home not started for the minimise", it) }.isSuccess
        WindowLog.i(TAG, "window ${w.id}: minimised as a home gesture (${top.flattenToShortString()}, task $task on display 0, home started=$ok)")
        io.postDelayed({ WindowLog.i(TAG, "window ${w.id}: after its minimise task $task is ${taskInfo(task)?.let { "mode ${windowingMode(it)} visible ${visibleOf(it)} on display ${WebWindowDisplays.displayOf(it)}" } ?: "gone"}") }, LEFT_SETTLE_MS)
    }

    /** MN2: the page's way back from minimised (dock, switcher, its page): an app [minimise] moved out, back in window [id]. */
    fun restore(id: Int): Boolean {
        val w = wins[id] ?: return false
        if (w.leftAt == 0L) return true
        io.post { backNow(w, "restored") }
        return true
    }

    /** On [io]: [w]'s task back on its display, in front (out of PiP too: startActivityFromRecents full screen there). */
    private fun backNow(
        w: Win,
        why: String,
    ) {
        if (w.closed || w.leftAt == 0L) return
        w.leftAt = 0L
        val task = w.taskId
        val alive = taskDisplay(task) != null
        val ok = if (alive) moveTask(task, w.displayId) else true.also { main.post { if (!w.closed) launch(w) } }
        WebWindowDisplays.fullScreen(task, w.id, false)
        WindowLog.i(TAG, "window ${w.id}: back in its window ($why; task $task ${if (alive) "moved back to display ${w.displayId}: $ok" else "gone: launched again"})")
    }

    /**
     * On [io], on a task change: minimised window [w]'s task. Gone (its PiP dismissed): the window closes with it, as
     * the app did. Full screen and visible on display 0 after the leave settled (PiP expanded, its switcher card or a
     * launch brought it to the front): back into its window, shown on its page (MN2: "PiP expand brings it back to its
     * window, not to full screen").
     */
    private fun checkLeft(w: Win) {
        if (w.closed || w.leftAt == 0L) return
        if (android.os.SystemClock.uptimeMillis() - w.leftAt < LEFT_SETTLE_MS) return
        val t = taskInfo(w.taskId)
        if (t == null) {
            main.post { leftGone(w) }
            return
        }
        if (windowingMode(t) != WINDOWING_MODE_FULLSCREEN || visibleOf(t) != true) return
        backNow(w, "PiP expanded / brought to the front")
        main.post { if (!w.closed) emit("webwindows.show", w.id) }
    }

    /** Main thread: [checkLeft] found [w]'s minimised app gone (its PiP dismissed): the window closes with it. */
    private fun leftGone(w: Win) {
        if (w.closed || w.leftAt == 0L) return
        WindowLog.i(TAG, "window ${w.id}: its minimised app (task ${w.taskId}) is gone (PiP dismissed): window closed")
        w.leftAt = 0L
        WebWindowDisplays.fullScreen(w.taskId, w.id, false)
        drop(w)
    }

    /** Task [taskId]'s info, or null: not running. */
    private fun taskInfo(taskId: Int): android.app.ActivityManager.RunningTaskInfo? {
        if (taskId < 0) return null
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(android.app.ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        return tasks.firstOrNull { it.taskId == taskId }
    }

    /** HACK: TaskInfo.getWindowingMode is hidden (reflected). Real fix: none public for an app. -1: unreadable. */
    private fun windowingMode(t: android.app.TaskInfo): Int =
        runCatching { android.app.TaskInfo::class.java.getMethod("getWindowingMode").invoke(t) as Int }.getOrDefault(-1)

    /** HACK: TaskInfo.isVisible is hidden before API 34's isVisible() (reflected). Real fix: none for older APIs. */
    private fun visibleOf(t: android.app.TaskInfo): Boolean? =
        runCatching { android.app.TaskInfo::class.java.getField("isVisible").getBoolean(t) }.getOrNull()

    /**
     * [component] declares android:supportsPictureInPicture. HACK: ActivityInfo.FLAG_SUPPORTS_PICTURE_IN_PICTURE is
     * hidden (read reflected, its AOSP value as the fallback). Real fix: none public (it's the manifest attribute's flag).
     */
    private fun supportsPip(component: ComponentName): Boolean {
        val flag = runCatching { ActivityInfo::class.java.getField("FLAG_SUPPORTS_PICTURE_IN_PICTURE").getInt(null) }.getOrDefault(0x400000)
        return runCatching { context.packageManager.getActivityInfo(component, 0).flags and flag != 0 }.getOrDefault(false)
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
                WindowLog.i(TAG, "window ${win.id}: KWin takes no full-screen request: full screen by PowOS alone")
                linuxFullScreen(win, true)
                return
            }
            // KWin puts the window itself full screen (its F11); shown so at once, KWin's "fullscreen <id> 1|0" confirms.
            WindowLog.i(TAG, "window ${win.id}: KWin window ${src.kwin} full screen asked")
            win.fullAsked = true
            andro.marchy.WebWindowSource.fullScreen(src.kwin, true)
            linuxFullScreen(win, true)
            // HACK: KWin that never answers (a window that can't go full screen says "stays", so this is a lost line):
            // sized anyway. Real fix: kwin 0047 sizes a requested full screen by the task, never by its output.
            main.postDelayed({ if (win.fullAsked) fullScreenConfirmed(win, "no answer from KWin in 1.5 s") }, 1_500L)
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
        // Closed while this waited on [io] (10-31 03:05, "Clear all": window 1 closed at .466, this ran at .588 and moved
        // Chrome's task to display 0 before the close's removeTasks(224) - the task outlived its window, a second window
        // took it and the next Tasks.remove found the closed window 1 in the stale full-screen map): nothing to move.
        if (win.closed) return
        val task = taskOn(win.displayId)
        if (task == null) {
            WindowLog.w(TAG, "window ${win.id}: no task on display ${win.displayId} to make full screen")
            announce(win, false)
            return
        }
        win.taskId = task
        // Known as a full-screen web window BEFORE it lands on display 0: the old path's adopt must never float it.
        WebWindowDisplays.fullScreen(task, win.id, true)
        val ok = moveTask(task, android.view.Display.DEFAULT_DISPLAY)
        if (!ok || win.closed) WebWindowDisplays.fullScreen(task, win.id, false)
        if (win.closed) {
            // Closed during the move: its app goes with it, wherever the move left it.
            removeTask(task, "app of window ${win.id}, closed while it went full screen")
            return
        }
        WindowLog.i(TAG, "window ${win.id}: ${if (ok) "its app (task $task) is a full-screen app on display 0" else "full screen FAILED (task $task stays on display ${win.displayId})"}")
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
        if (!full) resend("window ${win.id} back from full screen")
    }

    /**
     * The page sends every window's geometry again on its next frame ("webwindows.resend"), changed or not, so the
     * whole layer state - parent, z, crop, position, visibility - is committed after a transition the page's geometry
     * string may not see: back from full screen, a mirror made again, home's surface re-attached. Before (10-30 22:59):
     * a Discord window back from full screen showed a bare hole until the user dragged it (its next changed geometry).
     */
    private fun resend(why: String) {
        WindowLog.i(TAG, "geometry resend asked: $why")
        emit("webwindows.resend", 0)
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
        markLinuxFull(win, on)
        if (!on) win.fullAsked = false
        // Covers every web window now: a new window of its app opens as a task in front of it (WindowTasks.open).
        andro.marchy.WebWindowSource.shownFullScreen(src.kwin, on)
        val t = SurfaceControl.Transaction()
        if (on) {
            fillScreen(t, win, src)
        } else {
            // Back under home's surface among the page's windows: the page's next frame places it.
            // In this transaction, at the page's last place and z: left to the page's next frame it kept FULL_LAYER
            // (above every other window) until the page measured a change - and none comes while nothing moves.
            win.geo?.let { place(t, win, it) } ?: underRoot(t, win)
            t.apply()
        }
        WindowLog.i(TAG, "window ${win.id}: KWin window ${src.kwin} ${if (on) "full screen" else "back in its window"}")
        win.full = on
        emit("webwindows.full", mapOf("id" to win.id, "on" to on))
        if (!on) resend("window ${win.id} back from full screen")
        publishBars()
    }

    /** [win]'s [Win.linuxFull] set to [on], its IR1 marks reset. */
    private fun markLinuxFull(
        win: Win,
        on: Boolean,
    ) {
        win.linuxFull = on
        win.linuxFullAt = SystemClock.uptimeMillis()
        win.fullListedAt = 0L
        if (staleFullLogged == win.id) staleFullLogged = -1
    }

    /**
     * [linuxFullScreen]'s on: [win]'s layers over the whole screen at 1:1 below the status bar ([fullScreenArea]), KWin's
     * window at that size - at once, or on KWin's confirmation when PowOS asked for the full screen ([Win.fullAsked]).
     */
    private fun fillScreen(
        t: SurfaceControl.Transaction,
        win: Win,
        src: LinuxSource,
    ) {
        if (linuxTouch !== win) linuxTouch = null
        val area = fullScreenArea()
        win.container.takeIf { it.isValid }?.let { c ->
            // Full screen is not an element of the page: ABOVE home's buffer (a child of home's surface itself, as the
            // windows' root is), so nothing of the page paints over it; the root's own layer is -1, under home.
            // HACK: home's surface recreated while it is full screen leaves it on the old surface ([reattach] moves only
            // the root); real fix: a second root above home's buffer, re-attached the same way.
            web.rootSurfaceControl?.buildReparentTransaction(c)?.let {
                t.merge(it)
                win.underRoot = false
            }
            // FL5: the app's area starts below the status bar, never under it (the user, 10-30 22:19: Dolphin's toolbar
            // drawn through the clock and icons).
            t.setPosition(c, area.left.toFloat(), area.top.toFloat()).setScale(c, 1f, 1f)
                .setCrop(c, Rect(0, 0, area.width(), area.height())).setLayer(c, FULL_LAYER).setVisibility(c, !underSwitcher)
            cornerRadius(t, c, 0f)
        }
        src.content.takeIf { it.isValid }?.let { m -> t.setPosition(m, 0f, 0f).setScale(m, 1f, 1f).setCrop(m, Rect(0, 0, area.width(), area.height())) }
        t.apply()
        win.shown = true
        if (win.fullAsked) {
            WindowLog.i(TAG, "window ${win.id}: full screen ${area.width()}x${area.height()} at ${area.left},${area.top}: sized on KWin's answer")
        } else {
            linuxResize(win, src, area.width(), area.height())
        }
    }

    /** A full-screen Linux window's place: the whole screen less the status bar on top (display px = home's window px). */
    private fun fullScreenArea(): Rect {
        val b = context.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds
        val insets = web.rootWindowInsets
        val bar = insets?.getInsetsIgnoringVisibility(android.view.WindowInsets.Type.statusBars())?.top ?: 0
        val cut = insets?.getInsets(android.view.WindowInsets.Type.displayCutout())?.top ?: 0
        return Rect(0, fullScreenTop(b.height(), maxOf(bar, cut)), b.width(), b.height())
    }

    /**
     * KWin confirmed [win]'s full screen (or never answered): its window to the full-screen size now. KWin's own full
     * screen took its output's size (setFullScreen: FullScreenArea) - and that output is the desktop consumer's, the
     * folded cover's while unfolded - and kwin 0040 kept it while the task's size equalled the one from before the full
     * screen. A size sent after the answer differs from that one: the task's size wins.
     */
    private fun fullScreenConfirmed(
        win: Win,
        why: String,
    ) {
        if (!win.fullAsked) return
        win.fullAsked = false
        val src = win.linux ?: return
        if (win.closed || !win.linuxFull) return
        val area = fullScreenArea()
        WindowLog.i(TAG, "window ${win.id}: KWin window ${src.kwin} full screen ($why): sized ${area.width()}x${area.height()}")
        linuxResize(win, src, area.width(), area.height())
    }

    /** KWin's "fullscreen <kwin> 1|0" (ShellBridge's host, main thread): the window went full screen or left it. */
    fun linuxFullScreen(
        kwin: Int,
        on: Boolean,
    ) {
        val w = wins.values.firstOrNull { it.linux?.kwin == kwin } ?: return
        if (on && w.linuxFull) fullScreenConfirmed(w, "KWin's answer")
        linuxFullScreen(w, on)
    }

    // ---- Linux windows that draw their own frame (CSD: Brave, Chrome, Steam, GTK header bars; kwin 0046) -------------

    /** KWin window [kwin] draws its own frame now ([own]) or not: the page shows its bar or not (main thread). */
    fun linuxOwnFrame(
        kwin: Int,
        own: Boolean,
    ) {
        val w = wins.values.firstOrNull { it.linux?.kwin == kwin } ?: return
        WindowLog.i(TAG, "window ${w.id}: KWin window $kwin ${if (own) "draws its own frame: no PowOS bar" else "has PowOS's bar"}")
        emit("webwindows.frame", mapOf("id" to w.id, "own" to own))
    }

    /**
     * KWin window [kwin]'s own frame dragged ("moveresize <id> move|<edges>": its tab strip, its edge): the touch doing
     * it stops going to KWin (a cancel for every pointer), and the page's frame follows the rest of it - a move as its
     * bar's drag, a resize as its edge grab ("webwindows.moveresize" {id, edges}; the page's Body holds the pointer).
     * Main thread.
     */
    fun linuxMoveResize(
        kwin: Int,
        edges: String,
    ) {
        val w = wins.values.firstOrNull { it.linux?.kwin == kwin } ?: return
        if (w.linuxFull) return
        val g = gesture
        if (linuxTouch === w && g != null) {
            val src = w.linux
            val cancel = MotionEvent.obtain(g).apply { action = MotionEvent.ACTION_CANCEL }
            if (src != null) {
                val at = IntArray(2).also(web::getLocationInWindow)
                val geo = w.geo
                if (geo != null) andro.marchy.WebWindowSource.touch(src.handle, cancel, at[0] - geo.body.left.toFloat(), at[1] - geo.body.top.toFloat(), geo.scale)
            }
            cancel.recycle()
            linuxTouch = null
        }
        WindowLog.i(TAG, "window ${w.id}: KWin window $kwin's own frame ${if (edges == "move") "dragged: the window moves" else "resized ($edges): the window resizes"}")
        emit("webwindows.moveresize", mapOf("id" to w.id, "edges" to edges))
    }

    /**
     * KWin window [kwin]'s own frame's buttons (main thread): "maximize" = PowOS full screen (the user's rule: max = full
     * screen; a double click on its tab strip too), "minimize" = the page's minimise (to the dock).
     */
    fun linuxControl(
        kwin: Int,
        action: String,
    ) {
        val w = wins.values.firstOrNull { it.linux?.kwin == kwin } ?: return
        WindowLog.i(TAG, "window ${w.id}: KWin window $kwin's own $action button")
        when (action) {
            "maximize" -> if (w.linuxFull) toWindow(w.id) else fullScreen(w.id)
            "minimize" -> emit("webwindows.control", mapOf("id" to w.id, "action" to "minimise"))
        }
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
        WindowLog.i(TAG, "window ${w.id}: back to a window (task $task ${if (alive) "moved back to display ${w.displayId}: $ok" else "gone: launched again"})")
        if (!ok) return
        WebWindowDisplays.fullScreen(task, w.id, false)
        announce(w, false)
    }

    /** Window [id]'s full-screen app to the front again (a dock tap on it): back on display 0, full screen. */
    private fun front(id: Int): Boolean {
        val w = wins[id] ?: return false
        io.post {
            if (taskDisplay(w.taskId) == null) {
                WindowLog.i(TAG, "window ${w.id}: its full-screen app (task ${w.taskId}) is gone: back to its window")
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
        }.onFailure { WindowLog.w(TAG, "display $displayId: its tasks unreadable", it) }.getOrNull()

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
                .onFailure { WindowLog.w(TAG, "moveRootTaskToDisplay($taskId, $displayId) refused: ${it.cause ?: it}") }.isSuccess
        val started = fromRecents(taskId, displayId)
        var now = taskDisplay(taskId)
        if (now != displayId) {
            val r = runCatching { andro.marchy.RootShell.run("cmd activity display move-stack $taskId $displayId") }.getOrNull()
            WindowLog.w(TAG, "task $taskId still on display $now: root move-stack -> code ${r?.code} ${r?.output?.take(160)}")
            fromRecents(taskId, displayId)
            now = taskDisplay(taskId)
        }
        WindowLog.i(TAG, "task $taskId to display $displayId: moveRootTaskToDisplay=$moved startActivityFromRecents=$started, now on display $now")
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
        }.onFailure { WindowLog.w(TAG, "startActivityFromRecents($taskId) on display $displayId refused: ${it.cause ?: it}") }.getOrDefault(false)
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
        }.onFailure { WindowLog.w(TAG, "window $windowId: its content not captured", it) }.getOrNull()
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
        io.postDelayed({ if (!w.closed && tasksOn(w.displayId) == 0) pullStrayTask(w) }, STRAY_CHECK_MS)
        io.postDelayed({ landedOrFallback(w) }, ESCAPE_CHECK_MS)
    }

    /** On [io], [ESCAPE_CHECK_MS] after the launch: landed, the app's stray task pulled in, or the fallback. */
    private fun landedOrFallback(w: Win) {
        if (w.closed) return
        val n = tasksOn(w.displayId)
        if (n != null && n > 0) w.landed = true
        if (n == null || n > 0 || pullStrayTask(w)) return
        WindowLog.w(TAG, "fallback: ${w.component.packageName} has no task on display ${w.displayId} ${ESCAPE_CHECK_MS} ms after its launch: Android's own window instead of web window ${w.id}")
        main.post {
            drop(w)
            runCatching {
                context.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setComponent(w.component).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }.onFailure { WindowLog.w(TAG, "fallback launch of ${w.component.packageName} failed", it) }
        }
    }

    /**
     * On [io], LN1 (10-31 00:22: PowApps from the launcher opened an empty window - its task was on display 0 with a
     * package-installer dialog, and the launch onto the window's display only brought that task forward there): the
     * app's own running task outside every other window ([w]'s display empty) is moved into [w], dialogs and all, so a
     * frame never stands without a bound task. True: moved.
     */
    private fun pullStrayTask(w: Win): Boolean {
        val stray = strayTask(w) ?: return false
        val ok = moveTask(stray, w.displayId)
        WindowLog.w(TAG, "window ${w.id} (${w.component.packageName}): its display was empty, the app's task $stray ran elsewhere - ${if (ok) "moved into the window" else "NOT moved"}")
        if (ok) w.landed = true
        return ok
    }

    /** On [io]: [w]'s app's running task on a known display that is neither [w]'s nor another window's, or null. */
    private fun strayTask(w: Win): Int? {
        val pkg = w.component.packageName
        // Read off main: a copy that races an open/close gives up (no move rather than a wrong one).
        val windowDisplays = runCatching { wins.values.filter { !it.closed }.map { it.displayId }.toSet() }.getOrNull() ?: return null
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(android.app.ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        return tasks.firstOrNull { t ->
            val d = WebWindowDisplays.displayOf(t)
            d >= 0 && d !in windowDisplays && (t.baseActivity?.packageName == pkg || t.topActivity?.packageName == pkg)
        }?.taskId
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
        // A launch held for this window (a notification, a widget, settings search: WebWindowLaunch) starts on its
        // display instead of the app's launcher activity - straight into the window, never via display 0.
        if (WebWindowLaunch.take(w.component.packageName, w.displayId)) return
        val intent =
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setComponent(w.component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            val opts = ActivityOptions.makeBasic().setLaunchDisplayId(w.displayId)
            context.startActivity(intent, opts.toBundle())
            WindowLog.i(TAG, "launched ${w.component.flattenToShortString()} on display ${w.displayId} (ActivityOptions)")
        } catch (e: Exception) {
            WindowLog.w(TAG, "ActivityOptions launch on display ${w.displayId} refused: ${e.message}; trying root am start")
            io.post {
                val r = runCatching { andro.marchy.RootShell.run("am start --display ${w.displayId} -f 0x10000000 -n ${w.component.flattenToShortString()}") }.getOrNull()
                WindowLog.i(TAG, "launched ${w.component.flattenToShortString()} on display ${w.displayId} (root am start): code ${r?.code} ${r?.output?.take(200)}")
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
        if (result.isSuccess) WindowLog.i(TAG, "IME policy of display $displayId: fallback to default display (ok)")
        else WindowLog.w(TAG, "IME policy of display $displayId not set: ${result.exceptionOrNull()?.let { it.cause ?: it }}")
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
                // Group uhid (3011) as adb's shell has it: the helper's per-display touchscreen is a uinput device
                // (WebWindowsHost.Touch); a bare `su 2000` gets no supplementary groups and /dev/uinput is refused.
                val p = ProcessBuilder("su", "-g", "2000", "-G", "3011", "2000", "-c", cmd).redirectErrorStream(true).start()
                process = p
                writer = BufferedWriter(OutputStreamWriter(p.outputStream))
                Thread({ read(p) }, "powos-ww-helper").apply { isDaemon = true }.start()
                WindowLog.i(TAG, "display helper started (shell uid, app_process)")
                writer
            } catch (e: Exception) {
                WindowLog.w(TAG, "display helper not started", e)
                null
            }
        }

        /** Its own thread: the helper's answers. */
        private fun read(p: Process) {
            val r = BufferedReader(InputStreamReader(p.inputStream))
            while (true) answer(runCatching { r.readLine() }.getOrNull() ?: break)
            WindowLog.w(TAG, "display helper gone (exit ${runCatching { p.waitFor() }.getOrNull()}): its windows close")
            val left = synchronized(waiting) { waiting.values.toList().also { waiting.clear() } }
            left.forEach { it(-1, "helper gone") }
            main.post { wins.values.filter { it.displayId >= 0 }.toList().forEach { drop(it, released = true) } }
        }

        private fun answer(line: String) {
            val a = line.split(' ', limit = 3)
            val waiter = if (a.size >= 2 && (a[0] == "display" || a[0] == "error")) synchronized(waiting) { waiting.remove(a[1]) } else null
            when {
                a[0] == "hello" -> WindowLog.i(TAG, "display helper ready")
                a[0] == "display" -> waiter?.invoke(a.getOrNull(2)?.trim()?.toIntOrNull() ?: -1, "bad answer: $line")
                a[0] == "error" -> waiter?.invoke(-1, a.getOrNull(2))
                else -> WindowLog.i(TAG, "display helper: $line")
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
                WindowLog.w(TAG, "display helper: '$line' not sent", e)
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

        /** After a resize drag's final resize: the helper logs [counts] with the settle time ("settled ..."). */
        fun settle(
            displayId: Int,
            counts: String,
        ) = io.post { send("settle $displayId $counts") }

        fun release(displayId: Int) {
            io.post { send("release $displayId") }
        }

        /**
         * A body touch injected on [displayId] by the helper (in order on [io]); false when no helper runs (the caller
         * falls back). The helper answers "log touch ..." for every down/up (and any move it couldn't inject).
         */
        fun touch(
            w: Win,
            action: Int,
            pointers: List<Triple<Int, Float, Float>>,
        ): Boolean {
            if (process?.isAlive != true) return false
            val line = "touch ${w.displayId} $action ${w.downAt} " + pointers.joinToString(" ") { (id, x, y) -> "$id,$x,$y" }
            io.post { if (!send(line)) WindowLog.w(TAG, "input: '$line' not sent") }
            return true
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
        }.onFailure { WindowLog.w(TAG, "no IWindowManager.mirrorDisplay: no web windows", it) }.getOrNull()
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
            WindowLog.w(TAG, "injectInputEvent refused: ${(e.cause ?: e)}")
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
        // `input motionevent` is one pointer: a second finger's down/up can't be said (PZ1: the helper's path can).
        if (ev.actionMasked == MotionEvent.ACTION_POINTER_DOWN || ev.actionMasked == MotionEvent.ACTION_POINTER_UP) return
        val verb = VERBS[ev.actionMasked] ?: "CANCEL"
        val cmd = "input -d $displayId touchscreen motionevent $verb ${ev.x.toInt()} ${ev.y.toInt()}"
        if (ev.actionMasked != MotionEvent.ACTION_MOVE) {
            io.post { runCatching { andro.marchy.RootShell.run(cmd) }.onFailure { WindowLog.w(TAG, "root input failed", it) } }
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

        /** An empty display is read again this long after: a window closes only when its task was gone over a second. */
        private const val ORPHAN_CONFIRM_MS = 1000L

        /** A dead task ([taskDead]) is read again this long after: with [RECONCILE_MS], its window closes within 1 s. */
        private const val DEAD_CONFIRM_MS = 300L

        /** [reconcile] runs at least this often while there are windows (task changes run it sooner). */
        private const val HEARTBEAT_MS = 2000L

        /** IR1: a full-screen Linux window the page lists as a plain window this long is stale (no full-screen touches). */
        private const val STALE_FULL_MS = 500L

        /** [WebWindows.minimise]: its move + home (and the PiP entry) settle in this; [checkLeft] waits it out. */
        private const val LEFT_SETTLE_MS = 2000L

        /** An open slower than this to show is logged as a warning ([shown]). */
        private const val SHOWN_SLOW_MS = 1000L

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

        /** [follow]'s answer for a window's task. */
        enum class Follow { BACK, FULL, PIP }

        /**
         * [follow]'s rule, by where the task is ([own]: the window's display, [main]: display 0) and its windowing mode:
         * floating (freeform 5, OnePlus' zoom 100) anywhere of these two -> [Follow.BACK] (full screen on its display);
         * PiP (2) -> [Follow.PIP]; full screen (1) or a split (6) on display 0 -> [Follow.FULL]; else (full screen in its
         * own display, another display) nothing.
         */
        fun followOf(
            own: Boolean,
            main: Boolean,
            mode: Int,
        ): Follow? =
            when {
                !own && !main -> null
                mode == WINDOWING_MODE_PINNED -> Follow.PIP
                mode == WINDOWING_MODE_FREEFORM || mode == WINDOWING_MODE_ZOOM -> Follow.BACK
                main && (mode == WINDOWING_MODE_FULLSCREEN || mode == WINDOWING_MODE_MULTI_WINDOW) -> Follow.FULL
                else -> null
            }

        /**
         * WM1: task [taskId] (floating on display 0: SystemFloat's hand-over) is a web window's app - followed back into
         * that window ([follow], at once), never a second window. False: no window's.
         */
        /** [displayOfApp]: [pkg]'s window holds a full-screen app on display 0 now. */
        const val FULL_APP = -2

        /**
         * The display of [pkg]'s Android web window (WebWindowLaunch: a launch goes straight onto it), -1 while it is
         * being made, [FULL_APP] when its app is full screen now, null: no window. Any thread (a snapshot).
         */
        fun displayOfApp(pkg: String): Int? {
            val ww = current ?: return null
            // wins is main-thread state; a copy taken off it may race a change: then no window (the old way).
            val w = (runCatching { ww.wins.values.toList() }.getOrNull() ?: return null).firstOrNull { it.linux == null && !it.closed && it.component.packageName == pkg } ?: return null
            return if (w.full) FULL_APP else w.displayId
        }

        fun followTask(taskId: Int): Boolean {
            val ww = current ?: return false
            val w = ww.wins.values.firstOrNull { it.taskId == taskId && it.linux == null && !it.closed && !it.full } ?: return false
            WindowLog.i(TAG, "task $taskId floating on display 0 is window ${w.id}'s app: followed, no second window")
            ww.main.removeCallbacks(ww.reconcileRun)
            ww.main.post(ww.reconcileRun)
            return true
        }

        /**
         * PowOS removed task [taskId] directly (Tasks.remove found no web window by its display maps): a window that
         * still holds it by id closes now, the bar's way - never a ghost frame left for the reconcile. Any thread.
         */
        fun taskRemovedByPowos(taskId: Int) {
            val ww = current ?: return
            ww.main.post {
                val id = ww.windowOfTask(taskId) ?: return@post
                WindowLog.w(TAG, "task $taskId removed by PowOS outside its window's close: web window $id closed with it (a stale task map)")
                ww.close(id)
            }
        }

        /** A Linux web window's switcher card id: this + its window id (no Android task id gets near it). */
        const val LINUX_CARD = 1 shl 29

        /** The order check ([orderCheckSoon]) waits this long after the apply, for SurfaceFlinger to compose it. */
        private const val ORDER_CHECK_DELAY_MS = 300L

        /** The order check's root dump gives up after this long (it shares the root shell with input's fallback). */
        private const val ROOT_DUMP_MS = 3_000L

        /** ... and runs again at most this often while the order is unchanged and two or more windows are shown. */
        private const val ORDER_RECHECK_MS = 10_000L

        /**
         * The output layer names (bottom first) of the enabled display that composed home in a "dumpsys SurfaceFlinger"
         * [dump] ("Display <id> ... isEnabled=true ... - Output Layer 0x...(<name>)"), or null: none such.
         */
        fun outputLayers(dump: String): List<String>? {
            val displays = dump.split(Regex("(?m)^Display \\d+ "))
            val shown = displays.drop(1).firstOrNull { it.contains("isEnabled=true") && it.contains("HomeShell") } ?: return null
            return Regex("(?m)^\\s*- Output Layer 0x[0-9a-f]+\\((.*)\\)\\s*$").findAll(shown).map { it.groupValues[1] }.toList()
        }

        /**
         * The page's [order] (window ids, bottom first) against [at] (each window's first output layer index, -1: not
         * composed): a line naming the first pair SurfaceFlinger drew the other way round, or null when they agree.
         */
        fun orderDivergence(
            order: List<Int>,
            at: Map<Int, Int>,
        ): String? {
            val seen = order.filter { (at[it] ?: -1) >= 0 }
            for (i in seen.indices) {
                for (j in i + 1 until seen.size) {
                    val lo = seen[i]
                    val hi = seen[j]
                    if (at.getValue(lo) > at.getValue(hi)) {
                        return "window $hi is above window $lo in the page but drawn under it (layers ${at.getValue(hi)} < ${at.getValue(lo)})"
                    }
                }
            }
            return null
        }

        /** A full-screen Linux window's layer among the windows ([linuxFullScreen]): above every page-ordered one. */
        private const val FULL_LAYER = 1 shl 20

        /** A full-screen Linux window's edge strips stay home's at least this tall (dp): the status bar, the home gesture. */
        private const val EDGE_STRIP_DP = 24

        /** How far in from an edge strip (dp) a pull leaves full screen. */
        private const val EDGE_PULL_DP = 24

        /** A full-screen Linux window's top on an [h] px tall screen whose status bar is [bar] px: below the bar. */
        fun fullScreenTop(
            h: Int,
            bar: Int,
        ): Int = bar.coerceIn(0, h / 4)

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
         * Home from the switcher (its "recents.end" to home, or its close): a full-screen Linux window leaves full screen
         * as on Home ([leaveFullScreen], FL3) - shown again with the windows' root, it covered home after "swipe up to the
         * switcher, then home". Any thread.
         */
        fun switcherHome(why: String) {
            val ww = current ?: return
            ww.main.post { ww.leaveFullScreen(why) }
        }

        /**
         * A full-screen Linux window is up on home's page (main thread). It is home's own page underneath, so no
         * Android task is visible: the nav swipe asks this to treat it as an app (a swipe = home, a hold = the switcher)
         * instead of as home's main page, where a swipe up opens the switcher (10-31 02:13, the user: "If I open an
         * application full screen and then swipe home then it always activates the switcher instead").
         */
        fun fullScreenUp(): Boolean = current?.fullLinux() != null

        /** The home swipe over a full-screen window: it leaves full screen and is minimised to the dock - home shows. */
        fun homeGesture(why: String) {
            val ww = current ?: return
            ww.main.post {
                val w = ww.wins.values.firstOrNull { it.linuxFull } ?: return@post
                ww.leaveFullScreen(why)
                if (!w.closed) ww.emit("webwindows.control", mapOf("id" to w.id, "action" to "minimise"))
            }
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
                WindowLog.i(TAG, "card $taskId removed (switcher / Tasks.remove): Linux web window $id - closing it (the bar's close path)")
                ww.main.post { ww.close(id) }
                return true
            }
            val id = WebWindowDisplays.windowOf(context, taskId) ?: ww.windowOfTask(taskId) ?: return false
            dev.omalauncher.system.Tasks.logRemove("closeForTask", taskId, "web window $id")
            WindowLog.i(TAG, "task $taskId removed (switcher / Tasks.remove): it is web window $id - closing the window (the bar's close path)")
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
                WindowLog.i(TAG, "card $taskId opened from the switcher: Linux web window $id shown where it was, on its page")
                ww.main.post { ww.emit("webwindows.show", id) }
                return true
            }
            if (WebWindowDisplays.fullScreenWindow(taskId) != null) return false
            val id = WebWindowDisplays.windowOf(context, taskId) ?: return false
            WindowLog.i(TAG, "task $taskId opened from the switcher: web window $id shown where it was, on its page")
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
            val shot = ww.contentShot(id) ?: return null.also { WindowLog.w(TAG, "task $taskId (window $id): no picture for its card") }
            WindowLog.i(TAG, "task $taskId (window $id): card picture from its mirror (no task snapshot)")
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
                    .onSuccess { WindowLog.w(TAG, "no home ${HOME_GRACE_MS} ms after PowOS came back (web windows on): started it on display 0") }
                    .onFailure { WindowLog.w(TAG, "no home after PowOS came back, and starting it failed", it) }
            }, "powos-ww-home").start()
        }

        private const val HOME_GRACE_MS = 4000L

        /** Web windows on: Android apps opened from the wide home are web windows (only those stand the old path down: WebWindowDisplays). */
        fun on(context: Context): Boolean = runCatching { Settings.Global.getInt(context.contentResolver, SETTING, 0) == 1 }.getOrDefault(false)
        private const val PLACE_LOG_MS = 1000L

        /** RS1: the fill under a resized app stays this long after release (its final relayout's ~100-200 ms). */
        private const val FILL_HOLD_MS = 400L

        /** The 1x1 fill's scale: past any body; the container's crop is its size. */
        private const val FILL_SCALE = 8192f
        /** After a task lands on a window's display (or a Linux consumer starts): its first frame is taken as drawn. */
        private const val LIVE_AFTER_MS = 250L

        /** A scale below this in "w.f" is a bad one (an element measured mid-mount): taken as 1. */
        private const val MIN_ZOOM = 0.05f
        private const val MIRROR_WAIT_MS = 2000L

        /** A KWin window offered to the page ([linuxOpened]) and not taken by then opens as its own task. */
        private const val LINUX_ADOPT_MS = 3000L
        private const val ESCAPE_CHECK_MS = 3000L

        /** LN1: an empty window's display checked this soon after its launch for the app's task elsewhere. */
        private const val STRAY_CHECK_MS = 700L
        private const val RESIZE_MODE_UNRESIZEABLE = 0
        private const val IME_POLICY_FALLBACK_DISPLAY = 1
        private const val WINDOWING_MODE_FULLSCREEN = 1
        private const val WINDOWING_MODE_PINNED = 2
        private const val WINDOWING_MODE_FREEFORM = 5
        private const val WINDOWING_MODE_MULTI_WINDOW = 6

        /** OnePlus' own floating ("zoom") window: its "..." menu's "Floating window". */
        private const val WINDOWING_MODE_ZOOM = 100
        private const val MAX_TASKS = 64
        private val VERBS = mapOf(MotionEvent.ACTION_DOWN to "DOWN", MotionEvent.ACTION_MOVE to "MOVE", MotionEvent.ACTION_UP to "UP")
    }
}
