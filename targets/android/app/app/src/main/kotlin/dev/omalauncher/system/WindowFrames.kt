package dev.omalauncher.system

import android.content.Context
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.WindowManager
import androidx.compose.runtime.mutableStateOf

/**
 * PowOS's frames for the floating app windows on the unfolded home ([AppWindows], [WindowFrame]): a frame on every
 * floating window that shows and isn't covered by another, kept on the task as Android moves, raises and closes it
 * (the task stack listener, [FreeformTasks.listen]). Minimised windows ([minimise]) leave the screen and stay in the
 * dock ([running], home's page: windows.changed), which brings them back ([restore]). Lives with the recents service
 * (SystemUI bound); none while the lock screen or the switcher is up, or folded.
 */
class WindowFrames(
    service: Context,
) {
    private val display: Display = service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    private val context: Context = service.createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
    private val main = Handler(Looper.getMainLooper())
    private val frames = mutableMapOf<Int, WindowFrame>()
    private var stopListening: (() -> Unit)? = null
    private var keyguard = false
    private val refreshNow = Runnable { refresh() }
    private val refreshLate = Runnable { refresh() }

    fun start(): Boolean {
        overlayGrant()
        // The system's own caption would show under PowOS's bar on every window: off (OemCaption).
        OemCaption.off(context)
        stopListening =
            FreeformTasks.listen {
                events++
                main.removeCallbacks(refreshNow)
                main.postDelayed(refreshNow, SETTLE_MS)
            }
        // Without the listener nothing is ever listed after this first read: no window gets a home page (2026-10-23).
        Log.i(TAG, "frames on, task listener ${if (stopListening != null) "on" else "MISSING"}")
        current = this
        // Home's page swipes at its fast rate over the windows too (HighRefresh.wanted: the top-most window's mode wins).
        dev.omalauncher.shell.HighRefresh.onWanted = { id -> frames.values.forEach { it.preferMode(id) } }
        refresh()
        return stopListening != null
    }

    /**
     * The frames are TYPE_APPLICATION_OVERLAY windows (over apps, UNDER the status bar and the shade - the recents role's
     * 2017 would sit over the shade), which need the "display over other apps" app op. It was found reset to default on
     * 2026-10-23 ("permission denied for window type 2038": no title bars at all), so it's granted again through root
     * whenever it's missing, as QuickSettings does WRITE_SETTINGS. The reset's cause: the manifest had stopped
     * declaring SYSTEM_ALERT_WINDOW (2026-10-16), so the op fell back to "default" and `appops set` didn't take (rc 0,
     * still default); declared again in AndroidManifest.xml. HACK: the user's grant done for them. Real fix: the grant
     * in PowOS's setup (Settings > display over other apps), kept.
     */
    private fun overlayGrant() {
        if (Settings.canDrawOverlays(context)) return
        Thread {
            val r = runCatching { andro.marchy.RootShell.run("appops set ${context.packageName} SYSTEM_ALERT_WINDOW allow") }.getOrNull()
            Log.i(TAG, "overlay app op was off: granted again (${r?.code ?: "no root"})")
            main.post(refreshNow)
        }.start()
    }

    /**
     * A frame couldn't be added (WindowFrame.addViews): the app op again, at most once a minute - but [overlayGrant]
     * does nothing when the op is already on (the common case: a transient add failure right after a task's own
     * change, not a reset op), so without this a lost bar stayed lost until an unrelated event rebuilt its frame from
     * scratch (a dock minimise/restore right after a window opened: no title bar to close it by, 2026-10-24). Retry
     * the refresh regardless of why the add failed.
     */
    fun frameRefused() {
        val now = android.os.SystemClock.uptimeMillis()
        if (now - lastGrant < GRANT_EVERY_MS) return
        lastGrant = now
        overlayGrant()
        main.postDelayed(refreshNow, RETRY_MS)
    }

    private var lastGrant = 0L

    fun stop() {
        stopListening?.invoke()
        stopListening = null
        main.removeCallbacks(refreshNow)
        main.removeCallbacks(refreshLate)
        frames.values.forEach { it.remove() }
        frames.clear()
        if (current === this) {
            current = null
            dev.omalauncher.shell.HighRefresh.onWanted = null
        }
    }

    /** A window's bounds changed under PowOS's own hand (a bar drag, a grip resize): the list again, from any thread. */
    fun changed() {
        main.removeCallbacks(refreshNow)
        main.postDelayed(refreshNow, SETTLE_MS)
        // Once more after the change's transition has played: the task's bounds may still read the old ones at 80 ms.
        main.removeCallbacks(refreshLate)
        main.postDelayed(refreshLate, LATE_MS)
    }

    /**
     * Whether screen point ([x], [y]) (px) is on a floating window showing now - its content or its title bar, where
     * it is on the glass (one a finger is moving: where the finger has it). PowOS's own gestures over home (the shade's
     * pull on home's body: ShadeHost) never start there: a scroll inside an app is the app's. Main thread.
     */
    fun covers(
        x: Float,
        y: Float,
    ): Boolean {
        val bar = (WindowFrame.BAR_DP + WindowFrame.HIT_DP) * context.resources.displayMetrics.density
        val live = frames.values.filter { it.dragging }.associate { it.id to it.bounds }
        return running.value.any { w ->
            val b = live[w.id] ?: w.bounds
            val top = if (frames[w.id]?.ownBar == true) 0f else bar
            !w.minimised && !w.away && b != null && x >= b.left && x < b.right && y >= b.top - top && y < b.bottom
        }
    }

    /**
     * A home panel is over the windows (shell/PanelLift): the frames' windows are stacked under home then, so none is
     * added or re-added meanwhile (a new overlay would stack over the panel); the ones missed come with the refresh after.
     */
    var underPanel = false
        set(v) {
            if (field == v) return
            field = v
            if (!v) main.post(refreshNow)
        }

    /** Window [w] may have a frame now: not a new one under a home panel ([underPanel]). */
    private fun mayFrame(w: FreeformTasks.Window) = !underPanel || w.id in frames

    /** The frames' windows' views, bottom-most frame first (see [underPanel]). */
    fun frameViews(): List<android.view.View> = stack.mapNotNull { frames[it] }.flatMap { it.panelViews }

    /** SystemUI's state flags: no frames over the lock screen. */
    fun systemUiState(flags: Long) {
        val k = flags and SYSUI_KEYGUARD_SHOWING != 0L && flags and SYSUI_KEYGUARD_OCCLUDED == 0L
        if (k == keyguard) return
        keyguard = k
        refresh()
    }

    /** Folded/unfolded, rotated: the frames again. */
    fun refresh() {
        val all = runCatching { FreeformTasks.list(context) }.onFailure { Log.w(TAG, "no floating windows", it) }.getOrDefault(emptyList())
        val floating = AppWindows.floating(context)
        if (adopting(floating)) return
        logChange(all, floating)
        track(all, floating)
        val framed = floating && !keyguard && !Switcher.open
        val show = if (framed) shown(all) else emptyList()
        val ids = show.map { it.id }.toSet() + held(all, floating && !keyguard)
        frames.keys.filter { it !in ids }.forEach { frames.remove(it)?.remove() }
        if (framed) belowStatusBar(show)
        frame(show)
        restack(show.asReversed().map { it.id })
    }

    /** The windows that get a frame: showing, not minimised or away, their bar not under a window above. */
    private fun shown(all: List<FreeformTasks.Window>) = uncovered(all.filter { it.visible && it.id !in minimised && it.id !in away })

    /**
     * Every window of [show] (top-most first) framed and placed: bottom-most first, so a new frame's windows stack over
     * the ones under it. Under a home panel, a new one waits (underPanel).
     */
    private fun frame(show: List<FreeformTasks.Window>) {
        show.asReversed().filter(::mayFrame).forEach { w ->
            val own = ownBar(w)
            // Who draws its title bar changed (a launch window became Steam's, KWin's "decor"): a new frame, between touches.
            frames[w.id]?.takeIf { it.ownBar != own && !it.held && !it.dragging }?.let { frames.remove(w.id)?.remove() }
            frames.getOrPut(w.id) { WindowFrame(context, w.id, WindowFrame.App(w.pkg, ownTitle(w), own), ::minimise, ::edge, ::maximise) }.apply { showMaximised(w.id in maximised) }.place(w.bounds)
        }
    }

    /**
     * [w] draws its own title bar: a Linux window with client-side decorations (Steam, GTK header bars; KWin says,
     * WindowTasks "decor"), so its frame has none - one title bar per window. Android apps never (their caption is off).
     */
    private fun ownBar(w: FreeformTasks.Window) = w.pkg == context.packageName && andro.marchy.WindowTasks.drawsOwnBar(w.id)

    /**
     * The window's own title bar is being dragged ([e]: from KWin's "move" to the lift, PowosWindowActivity): its frame
     * moves it like a drag of our bar. False when it has no frame now. Main thread.
     */
    fun appMove(
        taskId: Int,
        e: android.view.MotionEvent,
    ): Boolean = frames[taskId]?.appMove(e) ?: false

    /**
     * The frames a finger has, while their task is there ([all]) and frames show at all ([on]): they stay even when the
     * task isn't shown (its report lags the finger, or a transition of the drag's hides it for a moment) - removed,
     * the touch stream ended and the drag with it.
     */
    private fun held(
        all: List<FreeformTasks.Window>,
        on: Boolean,
    ): Set<Int> {
        if (!on) return emptySet()
        val listed = all.map { it.id }.toSet()
        return frames.filter { (id, f) -> (f.held || f.dragging) && id in listed }.keys
    }

    /**
     * Frames may be re-added now: not under a home panel (underPanel), and never under a finger - a re-added bar loses
     * its touch stream (the drag never starts); that restack runs at the lift ([touchEnded]).
     */
    private fun mayRestack(): Boolean {
        if (underPanel) return false
        restackWaiting = frames.values.any { it.held || it.dragging }
        return !restackWaiting
    }

    /** A restack waited for a finger to lift ([touchEnded]). */
    private var restackWaiting = false

    /** A finger left a frame (WindowFrame): a restack that waited for it, now. */
    fun touchEnded() {
        if (restackWaiting) changed()
    }

    /**
     * Every window's whole bar under the status bar (AppWindows.area's top): the status bar's window is above every
     * overlay, so a bar reaching into it lost its touches there and sat over the status bar (01:47, a bar at y 60-100).
     * Whoever placed it (an app's own bounds, a Linux window, Android after a mode change), it moves down once, with
     * its content (a change transition). Not while a finger has it or maximised (the area's own top).
     */
    private fun belowStatusBar(show: List<FreeformTasks.Window>) {
        val top = AppWindows.area(context).top
        for (w in show.filter { lowerable(it, top) }) {
            if (!lowered.add("${w.id}@${w.bounds.flattenToString()}")) continue
            val to = Rect(w.bounds).apply { offset(0, top - w.bounds.top) }
            val ok = FreeformTasks.moveTo(context, w.id, to)
            Log.i(TAG, "task ${w.id} was under the status bar (${w.bounds.toShortString()}): moved to ${to.toShortString()} ok=$ok")
        }
        if (lowered.size > LOWERED_MAX) lowered.clear()
    }

    /** [w] reaches above [top] and nobody else has it (a finger, maximise). */
    private fun lowerable(
        w: FreeformTasks.Window,
        top: Int,
    ): Boolean {
        val f = frames[w.id] ?: return false
        return w.bounds.top < top && !f.held && !f.dragging && w.id !in maximised
    }

    /** Windows moved out from under the status bar, by task and the bounds they had (each once). */
    private val lowered = mutableSetOf<String>()

    /** The frames' ids bottom-most first, in the order their windows were added (overlays stack so). */
    private val stack = mutableListOf<Int>()

    /**
     * The frames stacked as their tasks ([wanted], bottom-most first): a window raised after its frame was made (a
     * restore, a tap, a desktop switch) had its bar under a lower window's (that bar took the drag: Chrome moved for
     * Calculator, 2026-10-23). Re-added from the first one out of place up, only when one out of order overlaps
     * another's bar or grip (a re-add blinks).
     */
    private fun restack(wanted: List<Int>) {
        if (!mayRestack()) return
        stack.retainAll(wanted.toSet())
        wanted.filter { it !in stack }.forEach { stack.add(it) }
        if (stack == wanted) return
        val wrong =
            wanted.indices.any { i ->
                (i + 1 until wanted.size).any { j ->
                    stack.indexOf(wanted[i]) > stack.indexOf(wanted[j]) && Rect.intersects(frames[wanted[i]]?.reach() ?: Rect(), frames[wanted[j]]?.reach() ?: Rect())
                }
            }
        // Out of order but apart: left as they are (the real order stays recorded for when they meet).
        if (!wrong) return
        val from = wanted.indices.first { stack[it] != wanted[it] }
        Log.i(TAG, "frames restacked from task ${wanted[from]}: ${wanted.joinToString(" ")} (were ${stack.joinToString(" ")})")
        wanted.drop(from).forEach { frames[it]?.raise() }
        stack.clear()
        stack.addAll(wanted)
    }

    /**
     * Unfolded, every app is a window: an app task showing full screen - opened without PowOS's launch options (another
     * app, a system notification, `am start`), or left full screen from the folded screen - is made one at the next
     * cascaded place (FreeformTasks.toWindow). Each task once ([adopted]): one that won't float stays as it is. True when
     * one changed (the task listener's refresh follows). PowOS's own tasks (Linux windows: WindowTasks decides) never.
     */
    private fun adopting(floating: Boolean): Boolean {
        // Folded, apps are full screen by design; unfolded again, they become windows again.
        if (!floating) {
            adopted.clear()
            windowed.clear()
            fullBefore.clear()
        }
        return floating && !keyguard && !Switcher.open && adopt()
    }

    private fun adopt(): Boolean {
        val full = FreeformTasks.fullScreen(context)
        // A window that is full screen now went there by its app's own request (a video, a game: Activity.
        // requestFullscreenMode): left so - no frame, no dock over it - and floats again where it was when it leaves.
        full.filter { (id, _) -> id in windowed && id !in fullBefore }.forEach { (id, pkg) ->
            fullBefore[id] = lastBounds[id] ?: Rect()
            Log.i(TAG, "task $id ($pkg) went full screen by itself (was ${lastBounds[id]?.toShortString()})")
        }
        val stray = full.filter { (id, pkg) -> pkg != null && pkg != context.packageName && id !in adopted && id !in windowed }
        stray.forEach { (id, pkg) ->
            adopted.add(id)
            val ok = FreeformTasks.toWindow(context, id, AppWindows.nextBounds(context))
            Log.i(TAG, "task $id ($pkg) was full screen: ${if (ok) "now a window" else "can't float it"}")
        }
        if (stray.isEmpty()) return false
        main.removeCallbacks(refreshNow)
        main.postDelayed(refreshNow, SETTLE_MS)
        return true
    }

    /**
     * The floating windows as Android lists them (logcat PowosWindowFrames), once per change, with how many task events
     * came since: a window that shows but isn't here never gets a home page (desktops.ts places what windows.list has).
     */
    private fun logChange(
        all: List<FreeformTasks.Window>,
        floating: Boolean,
    ) {
        val now = all.joinToString(" ") { "${it.id}:${it.pkg}${if (it.visible) "" else "(hidden)"}@${it.bounds.toShortString()}" }
        val key = "$floating $keyguard $now"
        if (key == logged) return
        logged = key
        Log.i(TAG, "windows (floating=$floating keyguard=$keyguard, $events task events): ${now.ifEmpty { "none" }}")
    }

    private var logged: String? = null
    @Volatile private var events = 0

    /** A PowOS (Linux) window's caption for its bar: its task is PowOS's own (PowosWindowActivity), so not "PowOS". */
    private fun ownTitle(w: FreeformTasks.Window): String? = w.label.takeIf { w.pkg == context.packageName }

    /** The per-window state kept up with the listed windows ([all]; none count folded, apps aren't windows there). */
    private fun track(
        all: List<FreeformTasks.Window>,
        floating: Boolean,
    ) {
        val ids = all.map { it.id }.toSet()
        minimised.retainAll(ids)
        // Folded, the windows aren't listed but still belong to their pages: kept for the unfold.
        if (floating) away.retainAll(ids)
        // Folded, apps aren't windows: the dock shows none.
        publish(if (floating) all else emptyList())
        // PowOS's own tasks (Linux windows, PowosWindowActivity) draw KWin's buffer pixel for pixel: no density.
        dense(if (floating) all.filter { it.pkg != context.packageName } else emptyList())
        keepMaximised(all)
        if (floating) backFromFullScreen(all)
    }

    /**
     * Maximised windows stay so until moved or resized by hand. Right after the button its task may still list the
     * bounds before (the change's transition plays first): kept until it shows the new ones ([Max.seen]), then only
     * while it keeps them; one that never changed in [MAX_SETTLE_MS] is ordinary again.
     */
    private fun keepMaximised(all: List<FreeformTasks.Window>) {
        val now = android.os.SystemClock.uptimeMillis()
        maximised.entries.removeAll { (id, m) ->
            val w = all.firstOrNull { it.id == id } ?: return@removeAll true
            val seen = m.seen
            when {
                seen != null -> w.bounds != seen
                w.bounds != m.before -> false.also { m.seen = Rect(w.bounds) }
                else -> now - m.at > MAX_SETTLE_MS
            }
        }
    }

    /**
     * A window back from its app's own full screen ([fullBefore]): exactly where it was before. Android puts an
     * Activity.requestFullscreenMode window back itself; a Linux window's (KWin's "fullscreen") or one Android put
     * somewhere else is set back here.
     */
    private fun backFromFullScreen(all: List<FreeformTasks.Window>) {
        all.forEach { w ->
            windowed.add(w.id)
            lastBounds[w.id] = Rect(w.bounds)
            val before = fullBefore.remove(w.id) ?: return@forEach
            val ok = before.isEmpty || w.bounds == before || FreeformTasks.resize(w.id, before)
            Log.i(TAG, "task ${w.id} left full screen: at ${w.bounds.toShortString()}, was ${before.toShortString()}${if (ok) "" else " (can't put it back)"}")
            if (!before.isEmpty && w.bounds != before) lastBounds[w.id] = Rect(before)
        }
        val ids = all.map { it.id }.toSet()
        // Gone tasks; a full-screen one isn't listed (not floating) but keeps its entry.
        windowed.retainAll { it in ids || it in fullBefore }
        lastBounds.keys.retainAll { it in ids || it in fullBefore }
    }

    /**
     * A Linux window's application went full screen by itself (KWin's "fullscreen", PowosWindowActivity) - [on] - or
     * left it: its task [taskId] over the whole screen, then floating again at its bounds before. Any thread.
     */
    fun appFullScreen(
        taskId: Int,
        on: Boolean,
    ) {
        main.post {
            if (!AppWindows.floating(context)) return@post
            val ok = if (on) toFullScreen(taskId) else toWindowAgain(taskId)
            Log.i(TAG, "task $taskId ${if (on) "full screen (its app's own)" else "a window again"}: ${fullBefore[taskId]?.toShortString()} ok=$ok")
            changed()
        }
    }

    private fun toFullScreen(taskId: Int): Boolean {
        if (taskId !in fullBefore) fullBefore[taskId] = lastBounds[taskId] ?: running.value.firstOrNull { it.id == taskId }?.bounds ?: Rect()
        return FreeformTasks.setFullScreen(context, taskId, true, null)
    }

    private fun toWindowAgain(taskId: Int): Boolean {
        val before = fullBefore[taskId]?.takeIf { !it.isEmpty } ?: AppWindows.nextBounds(context)
        return FreeformTasks.setFullScreen(context, taskId, false, before)
    }

    /**
     * Every floating window's app at the windows' density (AppWindows.windowDpi: about its full-screen size, not the
     * phone layout blown up); a task that is no longer a window ([windows] = the floating ones; none folded) gets the
     * screen's density back, so full screen is exactly as before.
     *
     * HACK: set while the window is still opening (the first refresh after its launch), the density doesn't stick on
     * OxygenOS 16 (measured 2026-10-23: the transaction succeeds, the task still says the screen's dpi; the same call
     * 3 s later sticks). So it's read back from the task's configuration and set again until it shows, a few tries
     * apart. Real fix: set it in the launch itself - needs WM Shell's desktop mode (SystemUI's), off on this ROM.
     */
    private fun dense(windows: List<FreeformTasks.Window>) {
        val dpi = AppWindows.windowDpi(context)
        val ids = windows.map { it.id }.toSet()
        (scaled - ids).forEach { FreeformTasks.density(context, it, 0) }
        scaled.retainAll(ids)
        denseTries.keys.retainAll(ids)
        var again = false
        for (w in windows) {
            if (w.dpi == dpi) {
                scaled.add(w.id)
                continue
            }
            val n = denseTries.getOrDefault(w.id, 0)
            if (n >= DENSE_TRIES) continue
            denseTries[w.id] = n + 1
            if (FreeformTasks.density(context, w.id, dpi)) scaled.add(w.id)
            Log.i(TAG, "task ${w.id} at ${w.dpi} dpi: set $dpi (try ${n + 1})")
            again = true
        }
        if (again) main.postDelayed(refreshNow, DENSE_RETRY_MS)
    }

    /**
     * Task [id]'s window over all of the windows' area (AppWindows.area: under the status bar, above home's bottom bar)
     * - its title bar's maximise; again, back where it was. Moved or resized by hand, it's an ordinary window again.
     */
    fun maximise(id: Int) {
        val now = frames[id]?.bounds ?: FreeformTasks.list(context).firstOrNull { it.id == id }?.bounds ?: return
        val back = maximised.remove(id)
        val target = back?.before ?: AppWindows.area(context)
        if (back == null) maximised[id] = Max(Rect(now), Rect(target), android.os.SystemClock.uptimeMillis())
        frames[id]?.showMaximised(back == null)
        val how = boundsTo(id, target, raise = !isFront(id))
        Log.i(TAG, "task $id ${if (back == null) "maximised" else "restored"}: ${now.toShortString()} -> ${target.toShortString()} ($how)")
        changed()
    }

    /**
     * Task [id]'s window to [target] in one change, the way a drag of its frame ends (TaskLeash: a change transition
     * whose content PowOS places at the new bounds, then WM's bounds at its end). Measured 2026-10-23 (f468af79): the
     * bare resizeTask the button used changed nothing - the window stayed where it was; it is only the fallback now.
     */
    private fun boundsTo(
        id: Int,
        target: Rect,
        raise: Boolean,
    ): String {
        if (TaskLeash.enabled(context) && boundsLive(id, target, raise)) return "change transition${if (raise) " + raised" else ""}"
        if (raise) FreeformTasks.raise(context, id)
        return if (FreeformTasks.resize(id, target)) "resizeTask" else "resizeTask refused"
    }

    /**
     * [boundsTo] through a change transition PowOS plays ([TaskLeash]); false if it couldn't start. Raised in the same
     * transaction (one transition), never a moveTaskToFront first: that is a transition of its own (TO_FRONT), still
     * collecting while the change starts.
     */
    private fun boundsLive(
        id: Int,
        target: Rect,
        raise: Boolean,
    ): Boolean {
        val set: (Any, (Int) -> Any?) -> Unit = { wct, token -> token(id)?.let { TaskLeash.setBounds(wct, it, target) } }
        val start: (Any, (Int) -> Any?) -> Unit = { wct, token ->
            if (raise) token(id)?.let { TaskLeash.reorder(wct, it, true) }
            set(wct, token)
        }
        val s = TaskLeash.Session(context, listOf(id), "task $id maximise")
        s.onReady = { live ->
            if (live) s.finish(mapOf(id to target), set) else Log.i(TAG, "task $id maximise: no leash, resizeTask ${FreeformTasks.resize(id, target)}")
            changed()
        }
        return s.start(start)
    }

    /** Task [id]'s frame (its bar and grip), if it shows one. */
    fun frame(id: Int): WindowFrame? = frames[id]

    /** Task [id]'s window is the top-most one showing (home's dock order, [running]): nothing to raise. */
    fun isFront(id: Int): Boolean = running.value.firstOrNull { !it.minimised && !it.away }?.id == id

    /** A maximised window: its bounds [before], the maximised ones asked for, when, and the ones its task then [seen]. */
    private class Max(
        val before: Rect,
        val target: Rect,
        val at: Long,
    ) {
        var seen: Rect? = null
    }

    /** The windows (top-most first) whose title bar isn't under a window above them: a covered bar would float over it. */
    private fun uncovered(windows: List<FreeformTasks.Window>): List<FreeformTasks.Window> {
        val bar = (WindowFrame.BAR_DP * context.resources.displayMetrics.density).toInt()
        return windows.filterIndexed { i, w ->
            val strip = Rect(w.bounds.left, w.bounds.top - bar, w.bounds.right, w.bounds.top)
            windows.take(i).none { Rect.intersects(it.bounds, strip) }
        }
    }

    /** Task [id]'s window let go at the screen's [side] edge: home takes it to the next page (shell windows.edge). */
    private fun edge(
        id: Int,
        side: Int,
    ) {
        edges.value = Edge(id, side, (edges.value?.seq ?: 0) + 1)
    }

    /** Task [id]'s window off the screen, into the dock. */
    fun minimise(id: Int) {
        val ok = FreeformTasks.minimise(context, id)
        // What a dock tap did (the e2e's "a dock tap on Chrome in front: minimised=false" had no trace either way).
        Log.i(TAG, "minimise task $id: ${if (ok) "done" else "refused"} (front was ${running.value.firstOrNull { !it.minimised && !it.away && it.bounds != null }?.id})")
        if (!ok) return
        minimised.add(id)
        refresh()
    }

    /**
     * Home's pages are desktops (shell ui/desktops.ts): [hide] are the windows of the other pages. Those leave the
     * screen as a minimise does (the task keeps running, no frame); the ones no longer in it come back, bottom-most
     * first so the stack keeps its order. A window the user minimised stays minimised. Folded (apps full screen):
     * nothing. On the main thread, like [refresh].
     */
    fun desktop(hide: Set<Int>): Boolean {
        if (!AppWindows.floating(context)) return false
        main.post { showOnly(hide) }
        return true
    }

    private fun showOnly(hide: Set<Int>) {
        val back = away - hide
        away.clear()
        away.addAll(hide)
        // All of them, not only the new: after a fold and unfold Android may have raised them again.
        hide.forEach { FreeformTasks.minimise(context, it) }
        running.value.asReversed().filter { it.id in back && it.id !in minimised }.forEach { FreeformTasks.raise(context, it.id) }
        main.removeCallbacks(refreshNow)
        main.postDelayed(refreshNow, SETTLE_MS)
    }

    /** Task [id]'s window back where it was, on top (a tap on it in the dock; home goes to its page, windows.raised). */
    fun restore(id: Int): Boolean {
        minimised.remove(id)
        away.remove(id)
        val ok = FreeformTasks.raise(context, id) || Tasks.open(context, id)
        main.postDelayed(refreshNow, SETTLE_MS)
        return ok
    }

    /** [pkg]'s floating window back (a tap on its app anywhere on home), if it has one and apps float: its task, or null. */
    fun restoreApp(pkg: String): Int? {
        if (!AppWindows.floating(context)) return null
        val w = running.value.firstOrNull { it.pkg == pkg } ?: return null
        return w.id.takeIf { restore(it) }
    }

    private fun publish(all: List<FreeformTasks.Window>) {
        val pm = context.packageManager
        val next =
            all.map { w ->
                val label = w.pkg?.let { p -> runCatching { pm.getApplicationLabel(pm.getApplicationInfo(p, 0)).toString() }.getOrNull() }
                Running(w.id, w.pkg, label ?: w.pkg.orEmpty(), w.id in minimised, w.id in away, w.bounds.takeIf { w.visible })
            }
        if (next != running.value) running.value = next
    }

    /** A window let go at a screen edge: [side] -1 left, 1 right; [seq] tells two drops apart. */
    data class Edge(
        val id: Int,
        val side: Int,
        val seq: Int,
    )

    /** A floating window for the dock: its task, app, name and whether it's minimised. */
    data class Running(
        val id: Int,
        val pkg: String?,
        val label: String,
        val minimised: Boolean,
        /** On another home page (desktop): out of sight until home shows that page. */
        val away: Boolean = false,
        /** Where it is on the screen (px) while it shows: home's gestures never start inside it. */
        val bounds: Rect? = null,
    )

    companion object {
        private const val TAG = "PowosWindowFrames"
        private const val SETTLE_MS = 80L
        private const val LOWERED_MAX = 256
        private const val LATE_MS = 600L
        private const val GRANT_EVERY_MS = 60_000L
        private const val RETRY_MS = 1_000L
        private const val DENSE_TRIES = 8
        private const val DENSE_RETRY_MS = 500L
        private const val SYSUI_KEYGUARD_SHOWING = 1L shl 6
        private const val SYSUI_KEYGUARD_OCCLUDED = 1L shl 9

        @Volatile
        var current: WindowFrames? = null
            private set

        /** Minimised windows' tasks (kept across a service rebind: the windows are still minimised). */
        private val minimised = mutableSetOf<Int>()

        /** Tasks whose density is the windows' (FreeformTasks.density): given back the screen's once not a window. */
        private val scaled = mutableSetOf<Int>()

        /** How often each window's density was set so far ([dense]: until its task says it). */
        private val denseTries = mutableMapOf<Int, Int>()

        /** Tasks [adopt] made windows (or tried to) since the last unfold: each once, so one that won't float isn't retried. */
        private val adopted = mutableSetOf<Int>()

        /** Maximised windows: task -> its bounds before and after ([Max]). */
        private val maximised = mutableMapOf<Int, Max>()

        /** How long a maximise may take to show in its task's bounds before it counts as not done. */
        private const val MAX_SETTLE_MS = 3000L

        /** Tasks seen as floating windows since the unfold: one of them full screen went there by itself. */
        private val windowed = mutableSetOf<Int>()

        /** Each window's last bounds while it floated (what a full-screen app goes back to). */
        private val lastBounds = mutableMapOf<Int, Rect>()

        /** Windows full screen by their app's own request -> their bounds before (empty: unknown). */
        private val fullBefore = mutableMapOf<Int, Rect>()

        /** Windows of the home pages not on screen ([desktop]); kept across a rebind like [minimised]. */
        private val away = mutableSetOf<Int>()

        /** The floating windows, top-most first, for the dock (home's page reads it: windows.list / windows.changed). */
        val running = mutableStateOf<List<Running>>(emptyList())

        /** The last edge drop (home's page reads it: windows.edge). */
        val edges = mutableStateOf<Edge?>(null)
    }
}
