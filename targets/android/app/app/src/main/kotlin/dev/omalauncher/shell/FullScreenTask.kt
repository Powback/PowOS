package dev.omalauncher.shell

import android.app.ActivityManager
import android.content.Context
import android.graphics.Rect
import dev.omalauncher.system.HiddenApi

/**
 * FS2: a web window's app made a full-screen app ([WebWindows.fullScreen]: its task moved from its virtual display to
 * display 0) really fills display 0 - never a floating task at its old window's size.
 *
 * The user, 11-02 21:45 ("Chrome is in a bad state"; board chrome-window-renders-at-half-size-content-in-to): Chrome's
 * window 8 on display 12 (1154x1538 dpi 294) went full screen at 21:44:38, the move reported "a full-screen app on
 * display 0", and the screen showed Chrome's 1154x1538 at (0,197), top-left, the rest black, no title bar. Its task kept
 * mLastNonFullscreenBounds=Rect(0, 197 - 1156, 1735): on display 0 it had come out NON-full-screen (OxygenOS put the
 * moved task in a floating mode at its old size, below the status bar), though startActivityFromRecents asked for
 * WINDOWING_MODE_FULLSCREEN. Nothing looked again: [WebWindows]' follow skips a full-screen window's task.
 *
 * So after the move the task's mode and bounds are read; floating (freeform, OnePlus' zoom) or smaller than the screen
 * -> windowing mode UNDEFINED (the display's full screen) and bounds cleared, as WM Shell's desktop mode does
 * ([dev.omalauncher.system.FreeformTasks.setFullScreen]). Checked at once and once more after the system settled.
 */
object FullScreenTask {
    private const val TAG = "PowosWebWindows"
    private const val FULLSCREEN = 1
    private const val FREEFORM = 5

    /** OnePlus' own floating ("zoom") window. */
    private const val ZOOM = 100

    /** The second look: OxygenOS's floating placement lands a transition after the move. */
    const val SETTLE_MS = 800L

    /** A size in px. */
    data class Size(
        val w: Int,
        val h: Int,
    )

    /**
     * A task on display 0 in windowing mode [mode] at [task] px, the screen [screen] px (0: unknown): it does not fill
     * the screen as a full-screen app must.
     */
    fun short(
        mode: Int,
        task: Size,
        screen: Size,
    ): Boolean {
        if (mode == FREEFORM || mode == ZOOM) return true
        if (mode != FULLSCREEN && mode != 0) return false
        val known = task.w > 0 && task.h > 0 && screen.w > 0 && screen.h > 0
        return known && (task.w < screen.w || task.h < screen.h)
    }

    /**
     * On a background thread: task [taskId] (just moved to display 0 as window [windowId]'s full-screen app) made full
     * screen when it isn't. True: it was short and was fixed (or the fix was tried).
     */
    fun ensure(
        context: Context,
        taskId: Int,
        windowId: Int,
        why: String,
    ): Boolean {
        val t = running(context, taskId) ?: return false
        if (WebWindowDisplays.displayOf(t) != android.view.Display.DEFAULT_DISPLAY) return false
        val (mode, b) = modeAndBounds(t) ?: return false
        val screen = screen(context)
        if (!short(mode, Size(b.width(), b.height()), Size(screen.x, screen.y))) return false
        // HACK: OxygenOS floats a task moved onto display 0 at its old size despite FULLSCREEN in the start's options;
        // corrected after the fact with a reflected WindowContainerTransaction. Real fix: none for an app (the floating
        // placement is OxygenOS's system_server); a platform-signed module would move the task with its mode in one call.
        val ok = dev.omalauncher.system.FreeformTasks.setFullScreen(context, taskId, true, null)
        WindowLog.w(TAG, "window $windowId: its full-screen app (task $taskId) landed mode $mode at $b on a ${screen.x}x${screen.y} screen ($why): made full screen: $ok")
        return true
    }

    @Suppress("DEPRECATION")
    private fun running(
        context: Context,
        taskId: Int,
    ): ActivityManager.RunningTaskInfo? =
        runCatching { context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrNull()?.firstOrNull { it.taskId == taskId }

    /** Task [t]'s windowing mode and bounds (WindowConfiguration, hidden: reflected), or null: unreadable. */
    private fun modeAndBounds(t: android.app.TaskInfo): Pair<Int, Rect>? =
        runCatching {
            HiddenApi.allow()
            val c = android.app.TaskInfo::class.java.getField("configuration").get(t) as android.content.res.Configuration
            val wc = android.content.res.Configuration::class.java.getField("windowConfiguration").get(c)!!
            (wc.javaClass.getMethod("getWindowingMode").invoke(wc) as Int) to Rect(wc.javaClass.getMethod("getBounds").invoke(wc) as Rect)
        }.getOrNull()

    /** Display 0's real size now (px). */
    private fun screen(context: Context): android.graphics.Point {
        val p = android.graphics.Point()
        runCatching {
            @Suppress("DEPRECATION")
            context.getSystemService(android.hardware.display.DisplayManager::class.java).getDisplay(android.view.Display.DEFAULT_DISPLAY).getRealSize(p)
        }
        return p
    }

    private const val MAX_TASKS = 64
}
