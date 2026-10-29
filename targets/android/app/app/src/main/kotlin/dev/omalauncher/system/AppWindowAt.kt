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
        return tasks.firstOrNull { runCatching { covers(it, x, y) }.getOrDefault(false) }?.let { (it.baseActivity ?: it.topActivity)?.packageName ?: "task ${it.taskId}" }
    }

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
