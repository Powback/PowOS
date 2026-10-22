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
        minimised.retainAll(all.map { it.id }.toSet())
        val floating = AppWindows.floating(context)
        // Folded, apps aren't windows: the dock shows none.
        publish(if (floating) all else emptyList())
        val show = if (keyguard || Switcher.open || !floating) emptyList() else uncovered(all.filter { it.visible && it.id !in minimised })
        val ids = show.map { it.id }.toSet()
        frames.keys.filter { it !in ids }.forEach { frames.remove(it)?.remove() }
        // Bottom-most first, so a new frame's windows stack over the ones under it.
        show.asReversed().forEach { w -> frames.getOrPut(w.id) { WindowFrame(context, w.id, w.pkg, ::minimise) }.place(w.bounds) }
    }

    /** The windows (top-most first) whose title bar isn't under a window above them: a covered bar would float over it. */
    private fun uncovered(windows: List<FreeformTasks.Window>): List<FreeformTasks.Window> {
        val bar = (WindowFrame.BAR_DP * context.resources.displayMetrics.density).toInt()
        return windows.filterIndexed { i, w ->
            val strip = Rect(w.bounds.left, w.bounds.top - bar, w.bounds.right, w.bounds.top)
            windows.take(i).none { Rect.intersects(it.bounds, strip) }
        }
    }

    /** Task [id]'s window off the screen, into the dock. */
    fun minimise(id: Int) {
        if (!FreeformTasks.minimise(context, id)) return
        minimised.add(id)
        refresh()
    }

    /** Task [id]'s window back where it was, on top (a tap on it in the dock). */
    fun restore(id: Int): Boolean {
        minimised.remove(id)
        val ok = FreeformTasks.raise(context, id) || Tasks.open(context, id)
        main.postDelayed(refreshNow, SETTLE_MS)
        return ok
    }

    /** [pkg]'s floating window back (a tap on its app anywhere on home), if it has one and apps float: false if not. */
    fun restoreApp(pkg: String): Boolean {
        if (!AppWindows.floating(context)) return false
        val w = running.value.firstOrNull { it.pkg == pkg } ?: return false
        return restore(w.id)
    }

    private fun publish(all: List<FreeformTasks.Window>) {
        val pm = context.packageManager
        val next =
            all.map { w ->
                val label = w.pkg?.let { p -> runCatching { pm.getApplicationLabel(pm.getApplicationInfo(p, 0)).toString() }.getOrNull() }
                Running(w.id, w.pkg, label ?: w.pkg.orEmpty(), w.id in minimised)
            }
        if (next != running.value) running.value = next
    }

    /** A floating window for the dock: its task, app, name and whether it's minimised. */
    data class Running(
        val id: Int,
        val pkg: String?,
        val label: String,
        val minimised: Boolean,
    )

    companion object {
        private const val TAG = "PowosWindowFrames"
        private const val SETTLE_MS = 80L
        private const val SYSUI_KEYGUARD_SHOWING = 1L shl 6
        private const val SYSUI_KEYGUARD_OCCLUDED = 1L shl 9

        @Volatile
        var current: WindowFrames? = null
            private set

        /** Minimised windows' tasks (kept across a service rebind: the windows are still minimised). */
        private val minimised = mutableSetOf<Int>()

        /** The floating windows, top-most first, for the dock (home's page reads it: windows.list / windows.changed). */
        val running = mutableStateOf<List<Running>>(emptyList())
    }
}
