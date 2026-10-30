package dev.omalauncher.shell

import android.app.ActivityManager
import android.app.TaskInfo
import android.content.Context
import java.util.concurrent.ConcurrentHashMap

/**
 * THE predicate "is this window a web window?" (docs/WEB_WINDOWS.md): a task on one of the virtual displays [WebWindows]
 * made for its windows. Only those stand the old floating-window path down (WindowFrames' bars and grips, adopting,
 * freeform launch options, TaskSurfaces, PageSlide): home's page owns them. Every other window - a Linux/KWin window's
 * task (PowosWindowActivity: Dolphin, Steam, games), an Android app opened by any other path - keeps the old floating
 * behaviour exactly as with `powos_web_windows` = 0, until Linux windows get their own web-window path (S6).
 *
 * The 2026-10-30 bug it fixes: d41c991b made the whole old path stand down while the setting was on
 * (AppWindows.floating false), so Dolphin opened full screen instead of in a floating window.
 */
object WebWindowDisplays {
    private val ids = ConcurrentHashMap.newKeySet<Int>()

    /** Display id -> the web window (WebWindows' id) it holds. */
    private val windows = ConcurrentHashMap<Int, Int>()

    /**
     * A web window's app made a full-screen app (its bar's full screen button, [WebWindows.fullScreen]): task id -> the
     * web window it came out of. Its task is on display 0 then, so [isWebWindow] says no (the old paths treat it as any
     * full-screen app); the switcher and the dock still know whose it is.
     */
    private val full = ConcurrentHashMap<Int, Int>()

    /** [WebWindows]: display [displayId] holds web window [windowId] now (its helper made it). */
    fun add(
        displayId: Int,
        windowId: Int,
    ) {
        if (displayId < 0) return
        ids += displayId
        windows[displayId] = windowId
    }

    /** [WebWindows]: display [displayId] is gone (window closed, display removed, helper gone). */
    fun remove(displayId: Int) {
        ids -= displayId
        windows.remove(displayId)
    }

    /** The web window display [displayId] holds, or null. */
    fun windowOn(displayId: Int): Int? = windows[displayId]

    /** [WebWindows]: task [taskId] of window [windowId] is a full-screen app now ([on]), or back in its window. */
    fun fullScreen(
        taskId: Int,
        windowId: Int,
        on: Boolean,
    ) {
        if (on) full[taskId] = windowId else full.remove(taskId)
    }

    /** [WebWindows]: window [windowId] closed: none of its tasks is a full-screen web window any more. */
    fun windowGone(windowId: Int) {
        full.values.removeAll { it == windowId }
    }

    /** The web window task [taskId] came out of while it's a full-screen app, or null. */
    fun fullScreenWindow(taskId: Int): Int? = full[taskId]

    /** Display [displayId] is a web window's. */
    fun isWebWindowDisplay(displayId: Int): Boolean = displayId in ids

    /** Task [t] is a web window (it lives on a web window's display; TaskInfo.displayId is hidden: unreadable = no). */
    fun isWebWindow(t: TaskInfo): Boolean {
        if (ids.isEmpty()) return false
        return runCatching { TaskInfo::class.java.getField("displayId").getInt(t) in ids }.getOrDefault(false)
    }

    /** Task [t]'s display (TaskInfo.displayId, hidden), or -1. */
    fun displayOf(t: TaskInfo): Int = runCatching { TaskInfo::class.java.getField("displayId").getInt(t) }.getOrDefault(-1)

    /**
     * The web window task [taskId] belongs to: on its display (floating) or a full-screen app out of one. Null: no web
     * window's. [running] is a getRunningTasks list the caller has already (else looked up here).
     */
    fun windowOf(
        context: Context,
        taskId: Int,
        running: List<ActivityManager.RunningTaskInfo>? = null,
    ): Int? {
        full[taskId]?.let { return it }
        if (windows.isEmpty()) return null
        @Suppress("DEPRECATION")
        val tasks = running ?: runCatching { context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        return tasks.firstOrNull { it.taskId == taskId }?.let { windows[displayOf(it)] }
    }

    /** Task [taskId] is a web window (a running-tasks lookup; none open: no binder call). */
    fun isWebWindow(
        context: Context,
        taskId: Int,
    ): Boolean {
        if (ids.isEmpty()) return false
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        return tasks.any { it.taskId == taskId && isWebWindow(it) }
    }

    private const val MAX_TASKS = 64
}
