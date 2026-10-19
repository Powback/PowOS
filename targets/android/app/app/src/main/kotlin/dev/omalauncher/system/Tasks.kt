package dev.omalauncher.system

import android.app.ActivityManager
import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.hardware.HardwareBuffer
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * Android's recent tasks, for the switcher (shell/ui/switcher.tsx): the list, a task's last frame, switching to one,
 * removing one. As the recents provider (config_recentsComponentName, docs/NATIVE-SYSTEM-UI.md) PowOS sees every
 * user's task (ActivityTaskManager's isCallerRecents), and holds READ_FRAME_BUFFER, START_TASKS_FROM_RECENTS and
 * REMOVE_TASKS. Not the recents provider: the list holds PowOS's own tasks only and the rest fails - the switcher is
 * only reached as the provider.
 */
object Tasks {
    private const val TAG = "PowosTasks"

    /** A recent task: its id, the app it's of (package, base activity) and its title. */
    data class Task(
        val id: Int,
        val component: ComponentName?,
        val label: String?,
    )

    /** Recent tasks, newest first: what's listed in the switcher (home and the switcher itself aren't). */
    fun list(
        context: Context,
        max: Int = 40,
    ): List<Task> {
        val am = context.getSystemService(ActivityManager::class.java)
        // getRecentTasks is deprecated for apps, which see only their own tasks; the recents provider sees them all.
        @Suppress("DEPRECATION")
        val tasks = am.getRecentTasks(max, ActivityManager.RECENT_IGNORE_UNAVAILABLE)
        return tasks.map { t ->
            val component = t.baseIntent.component ?: t.baseActivity ?: t.topActivity
            Task(t.taskId, component, t.taskDescription?.label)
        }
    }

    /** The task the user was in (shown when the switcher opened): the newest one that's visible, or null (home). */
    fun visible(context: Context): Int? {
        val am = context.getSystemService(ActivityManager::class.java)
        @Suppress("DEPRECATION")
        return am.getRecentTasks(4, ActivityManager.RECENT_IGNORE_UNAVAILABLE).firstOrNull { it.isVisible }?.taskId
    }

    /**
     * Brings task [id] back as it was (startActivityFromRecents: a task whose process is gone is restarted where it
     * left off). False if there's no such task.
     */
    fun open(
        context: Context,
        id: Int,
        options: ActivityOptions = ActivityOptions.makeBasic(),
    ): Boolean {
        val result =
            runCatching {
                HiddenApi.allow()
                atm().javaClass.getMethod("startActivityFromRecents", Int::class.javaPrimitiveType, android.os.Bundle::class.java)
                    .invoke(atm(), id, options.toBundle()) as Int
            }.onFailure { Log.w(TAG, "can't start task $id from recents", it) }.getOrNull()
        // START_SUCCESS (0) and the other non-negative codes (delivered to top, task to front) are a switch.
        if (result != null) return result >= 0
        // Not reachable (not the recents provider): a task still running can be brought to the front publicly.
        return runCatching { context.getSystemService(ActivityManager::class.java).moveTaskToFront(id, 0) }.isSuccess
    }

    /** Removes task [id] from recents (and ends its activities, as the stock switcher's swipe away). */
    fun remove(id: Int): Boolean =
        runCatching {
            HiddenApi.allow()
            atm().javaClass.getMethod("removeTask", Int::class.javaPrimitiveType).invoke(atm(), id) as Boolean
        }.onFailure { Log.w(TAG, "can't remove task $id", it) }.getOrDefault(false)

    /**
     * Takes task [id]'s snapshot now (its window as it is this moment) into the system's cache, which [snapshot] then
     * serves: the switcher's card of the app it was opened over shows the app as it was left, not as it was last time.
     * As WM Shell's recents controller does for Quickstep (screenshotTask: IActivityTaskManager.takeTaskSnapshot(id,
     * updateCache)). Blocking (a screen capture in the system server): off the main thread.
     */
    fun capture(id: Int): Boolean =
        runCatching {
            HiddenApi.allow()
            val m = atm().javaClass.methods.first { it.name == "takeTaskSnapshot" }
            val args: Array<Any?> = if (m.parameterTypes.size >= 2) arrayOf(id, true) else arrayOf(id)
            m.invoke(atm(), *args) != null
        }.onFailure { Log.w(TAG, "can't take task $id's snapshot", it) }.getOrDefault(false)

    /**
     * Task [id]'s last frame (the system's task snapshot) as a JPEG at most [width] px wide, or null if it has none.
     * The low-resolution copy first (it's what the system keeps on disk for the switcher), else the full one.
     */
    fun snapshot(
        id: Int,
        width: Int = 720,
    ): ByteArray? {
        val bitmap = runCatching { snapshotBitmap(id, true) ?: snapshotBitmap(id, false) }.onFailure { Log.w(TAG, "no snapshot of task $id", it) }.getOrNull() ?: return null
        val scaled = if (bitmap.width > width) Bitmap.createScaledBitmap(bitmap, width, bitmap.height * width / bitmap.width, true) else bitmap
        return ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 82, it) }.toByteArray()
    }

    private fun snapshotBitmap(
        id: Int,
        lowResolution: Boolean,
    ): Bitmap? {
        HiddenApi.allow()
        val snap = atm().javaClass.getMethod("getTaskSnapshot", Int::class.javaPrimitiveType, Boolean::class.javaPrimitiveType).invoke(atm(), id, lowResolution) ?: return null
        val buffer = snap.javaClass.getMethod("getHardwareBuffer").invoke(snap) as HardwareBuffer? ?: return null
        val space = runCatching { snap.javaClass.getMethod("getColorSpace").invoke(snap) as ColorSpace? }.getOrNull()
        return try {
            // A hardware bitmap can't be compressed: copied into memory first.
            Bitmap.wrapHardwareBuffer(buffer, space)?.copy(Bitmap.Config.ARGB_8888, false)
        } finally {
            buffer.close()
        }
    }

    /**
     * ActivityTaskManager's binder (IActivityTaskManager): the task calls that have no public API. HACK: hidden API,
     * reflected past its checks ([HiddenApi], which says why and what the real fix would be).
     */
    private fun atm(): Any = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
}
