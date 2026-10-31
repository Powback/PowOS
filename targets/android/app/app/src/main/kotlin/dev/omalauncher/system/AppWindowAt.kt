package dev.omalauncher.system

import android.app.ActivityManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.Rect
import android.os.SystemClock
import android.util.Log

/**
 * Spec G-W: a touch that STARTS inside any app window belongs to that app. Which app's window (if any) is under a
 * point, hit-tested against WM's own task bounds - every visible app task, not only the windows PowOS frames
 * ([WindowFrames] skips OnePlus's own floating windows, fixed-size compat apps and windows over the Plasma app), and a
 * full-screen app on top covers the whole screen. Home's shade pull-down ([ShadeHost]) and launcher swipe-up
 * ([PullHost]) ask it on the finger's down: the user, 2026-10-29, "the notification screen and launch[er] ... center is
 * also activating when I try to scroll up and down. This is not our windows, this is the native floating windows."
 */
object AppWindowAt {
    private const val TAG = "PowosGestures"
    private const val MAX_TASKS = 24

    /** WindowConfiguration.ACTIVITY_TYPE_UNDEFINED / _STANDARD: an app (not home, recents, the assistant or a dream). */
    private val APP_TYPES = setOf(0, 1)

    private var lastAt = 0L
    private var lastX = Float.NaN
    private var lastY = Float.NaN
    private var lastPkg: String? = null

    /** Some app window is under ([x], [y]): one PowOS frames (its bar included), or any app task by WM's bounds. */
    fun covered(
        context: Context,
        x: Float,
        y: Float,
    ): Boolean = WindowFrames.current?.covers(x, y) == true || at(context, x, y) != null

    /**
     * The package of the visible app window covering ([x], [y]) (display px), or null for none / unreadable. One
     * binder call per finger down: the shade's and the launcher's consumers both ask on the same down, so a repeat at
     * the same point within 100 ms reuses the answer (and logs once).
     */
    fun at(
        context: Context,
        x: Float,
        y: Float,
    ): String? {
        val now = SystemClock.uptimeMillis()
        if (x == lastX && y == lastY && now - lastAt < 100) return lastPkg
        val pkg = runCatching { find(context, x.toInt(), y.toInt()) }.onFailure { Log.w(TAG, "can't hit-test app windows", it) }.getOrNull()
        lastAt = now
        lastX = x
        lastY = y
        lastPkg = pkg
        if (pkg != null) Log.i(TAG, "not pulling: app window $pkg at ${x.toInt()},${y.toInt()}")
        return pkg
    }

    private fun find(
        context: Context,
        x: Int,
        y: Int,
    ): String? {
        HiddenApi.allow()
        @Suppress("DEPRECATION")
        val tasks = context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS)
        val display = displayOf(context)
        return tasks.firstOrNull { runCatching { onDisplay(it, display) && covers(it, x, y) }.getOrDefault(false) }?.let { (it.baseActivity ?: it.topActivity)?.packageName ?: "task ${it.taskId}" }
    }

    /**
     * Where Android's app handle ("•••" at the top centre of a split or full-screen app; OnePlus draws one on each half
     * of a split) sits on the status bar strip: one rect per visible app task that reaches the screen's top, centred on
     * its bounds, [handleW] wide and [strip] high (display px). Floating windows have none (PowOS frames them, their
     * caption is 1 px: [OemCaption]). The status bar leaves these to the app ([ShadeHost.barClaims]): the user,
     * 2026-10-30, "Dot dot dot menu doesn't open when I'm in split screen" - PowOS's strip took the tap.
     *
     * HACK: the handle's place is derived (task bounds + a fixed width), not read: SystemUI's handle window has no
     * public bounds. Real fix: the handle's own input window's frame (WM Shell's AppHandle) once PowOS is the window
     * decor provider (see [OemCaption]).
     */
    fun handles(
        context: Context,
        strip: Int,
        handleW: Int,
    ): List<Rect> =
        runCatching {
            HiddenApi.allow()
            @Suppress("DEPRECATION")
            val tasks = context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS)
            val display = displayOf(context)
            tasks.mapNotNull { t -> runCatching { if (onDisplay(t, display)) handleOf(t, strip, handleW) else null }.getOrNull() }
        }.onFailure { Log.w(TAG, "can't read app handles", it) }.getOrDefault(emptyList())

    private fun handleOf(
        t: ActivityManager.RunningTaskInfo,
        strip: Int,
        handleW: Int,
    ): Rect? {
        if (!android.app.TaskInfo::class.java.getField("isVisible").getBoolean(t)) return null
        val c = android.app.TaskInfo::class.java.getField("configuration").get(t) as Configuration
        val wc = Configuration::class.java.getField("windowConfiguration").get(c)!!
        if (wc.javaClass.getMethod("getActivityType").invoke(wc) as Int !in APP_TYPES) return null
        if (wc.javaClass.getMethod("getWindowingMode").invoke(wc) as Int == FREEFORM) return null
        val b = wc.javaClass.getMethod("getBounds").invoke(wc) as Rect
        if (b.isEmpty || b.top >= strip) return null
        return Rect(b.centerX() - handleW / 2, 0, b.centerX() + handleW / 2, strip)
    }

    /** The display home's touch is on: [context]'s own, or the default display for a non-visual context. */
    private fun displayOf(context: Context): Int =
        runCatching { context.display?.displayId }.getOrNull() ?: android.view.Display.DEFAULT_DISPLAY

    /**
     * Task [t] lives on [display]. Bounds are in the task's own display's coordinates, so a task on another display -
     * a PowOS web window's virtual display (Chrome on 232, Settings on 228; [WindowFrames] already claims those) -
     * "contains" home points near the origin and stole page 1's pull-down: the user, 2026-10-31, "Can't activate the
     * notifications in mobile mode ... like there's a floating window there that's not visible." Unreadable = keep it.
     */
    private fun onDisplay(
        t: ActivityManager.RunningTaskInfo,
        display: Int,
    ): Boolean =
        runCatching { android.app.TaskInfo::class.java.getField("displayId").getInt(t) == display }.getOrDefault(true)

    /** WindowConfiguration.WINDOWING_MODE_FREEFORM. */
    private const val FREEFORM = 5

    /** Task [t] is a visible app whose bounds (WM's, whatever its windowing mode) contain ([x], [y]). */
    private fun covers(
        t: ActivityManager.RunningTaskInfo,
        x: Int,
        y: Int,
    ): Boolean {
        val visible = runCatching { android.app.TaskInfo::class.java.getField("isVisible").getBoolean(t) }.getOrDefault(false)
        if (!visible) return false
        val c = android.app.TaskInfo::class.java.getField("configuration").get(t) as Configuration
        val wc = Configuration::class.java.getField("windowConfiguration").get(c)!!
        if (wc.javaClass.getMethod("getActivityType").invoke(wc) as Int !in APP_TYPES) return false
        return (wc.javaClass.getMethod("getBounds").invoke(wc) as Rect).contains(x, y)
    }
}
