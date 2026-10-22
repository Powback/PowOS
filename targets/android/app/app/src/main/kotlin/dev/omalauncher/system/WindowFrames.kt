package dev.omalauncher.system

import android.content.Context
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
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

    fun start(): Boolean {
        stopListening = FreeformTasks.listen { main.removeCallbacks(refreshNow); main.postDelayed(refreshNow, SETTLE_MS) }
        current = this
        refresh()
        return stopListening != null
    }

    fun stop() {
        stopListening?.invoke()
        stopListening = null
        main.removeCallbacks(refreshNow)
        frames.values.forEach { it.remove() }
        frames.clear()
        if (current === this) current = null
    }

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
        track(all, floating)
        val show = if (keyguard || Switcher.open || !floating) emptyList() else uncovered(all.filter { it.visible && it.id !in minimised && it.id !in away })
        val ids = show.map { it.id }.toSet()
        frames.keys.filter { it !in ids }.forEach { frames.remove(it)?.remove() }
        // Bottom-most first, so a new frame's windows stack over the ones under it.
        show.asReversed().forEach { w -> frames.getOrPut(w.id) { WindowFrame(context, w.id, w.pkg, ::minimise, ::edge, ::maximise) }.apply { showMaximised(w.id in maximised) }.place(w.bounds) }
    }

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
        dense(if (floating) all else emptyList())
        maximised.keys.retainAll { id -> all.any { it.id == id && it.bounds == maximised[id]?.second } }
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
        val target = back?.first ?: AppWindows.area(context)
        if (back == null) maximised[id] = Rect(now) to Rect(target)
        FreeformTasks.raise(context, id)
        FreeformTasks.resize(id, target)
        main.removeCallbacks(refreshNow)
        main.postDelayed(refreshNow, SETTLE_MS)
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
        if (!FreeformTasks.minimise(context, id)) return
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
                Running(w.id, w.pkg, label ?: w.pkg.orEmpty(), w.id in minimised, w.id in away)
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
    )

    companion object {
        private const val TAG = "PowosWindowFrames"
        private const val SETTLE_MS = 80L
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

        /** Maximised windows: task -> (its bounds before, its maximised bounds). */
        private val maximised = mutableMapOf<Int, Pair<Rect, Rect>>()

        /** Windows of the home pages not on screen ([desktop]); kept across a rebind like [minimised]. */
        private val away = mutableSetOf<Int>()

        /** The floating windows, top-most first, for the dock (home's page reads it: windows.list / windows.changed). */
        val running = mutableStateOf<List<Running>>(emptyList())

        /** The last edge drop (home's page reads it: windows.edge). */
        val edges = mutableStateOf<Edge?>(null)
    }
}
