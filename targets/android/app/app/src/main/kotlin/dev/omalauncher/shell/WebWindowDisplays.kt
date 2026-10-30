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

    /** [WebWindows]: display [displayId] holds a web window now (its helper made it). */
    fun add(displayId: Int) {
        if (displayId >= 0) ids += displayId
    }

    /** [WebWindows]: display [displayId] is gone (window closed, display removed, helper gone). */
    fun remove(displayId: Int) {
        ids -= displayId
    }

    /** Display [displayId] is a web window's. */
    fun isWebWindowDisplay(displayId: Int): Boolean = displayId in ids

    /** Task [t] is a web window (it lives on a web window's display; TaskInfo.displayId is hidden: unreadable = no). */
    fun isWebWindow(t: TaskInfo): Boolean {
        if (ids.isEmpty()) return false
        return runCatching { TaskInfo::class.java.getField("displayId").getInt(t) in ids }.getOrDefault(false)
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
