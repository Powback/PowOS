package dev.omalauncher.system

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Folded, no app is a floating window: every freeform task is made full screen on the cover screen.
 *
 * Android (OxygenOS 16) keeps a freeform task freeform through a fold, at its inner-screen bounds: a game window opened
 * as the phone unfolded (t2741, 2026-10-23 23:48: [556,366][1916,2074]) stayed so on the 1116 px cover screen, mostly
 * off it and listed invisible, and its switcher card grew to that box (the "com.powos.app" label floating over home).
 * Unfolded again, WindowFrames.adopt makes Android apps windows again, and a Linux window floats when it is raised
 * (WindowTasks.raiseTask -> AppWindows.taskOptions).
 */
object FoldedWindows {
    private const val TAG = "PowosFoldedWindows"

    /** The display settles after the configuration change (the hinge commits just after it). */
    private const val SETTLE_MS = 400L

    private val main = Handler(Looper.getMainLooper())

    /** The display changed (a fold, a rotation): folded, the floating windows full screen, once it settled. */
    fun displayChanged(context: Context) {
        val app = context.applicationContext
        main.postDelayed({ fullScreenIfFolded(app) }, SETTLE_MS)
    }

    /** Folded ([AppWindows.floating] false): every freeform task full screen. True when one changed. */
    fun fullScreenIfFolded(context: Context): Boolean {
        if (AppWindows.floating(context)) return false
        val windows = runCatching { FreeformTasks.cached(context) }.getOrDefault(emptyList())
        windows.forEach { w ->
            val ok = FreeformTasks.setFullScreen(context, w.id, true, null)
            Log.i(TAG, "folded: task ${w.id} (${w.pkg}) at ${w.bounds.toShortString()} ${if (ok) "now full screen" else "NOT made full screen"}")
        }
        return windows.isNotEmpty()
    }

    /** Folded, task [id] full screen before it is brought back (a switcher card, the dock): never a freeform task there. */
    fun beforeOpen(
        context: Context,
        id: Int,
    ) {
        if (AppWindows.floating(context)) return
        if (runCatching { FreeformTasks.cached(context) }.getOrDefault(emptyList()).none { it.id == id }) return
        val ok = FreeformTasks.setFullScreen(context, id, true, null)
        Log.i(TAG, "folded: task $id opened ${if (ok) "full screen" else "while still a window (NOT made full screen)"}")
    }
}
