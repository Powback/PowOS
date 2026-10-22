package dev.omalauncher.system

import android.app.ActivityManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.util.Log

/**
 * Android's floating (freeform) app windows ([AppWindows] opens them): which are on screen and where, and moving,
 * resizing, raising and closing them - what PowOS's own window frames ([WindowFrames]) drive, since OxygenOS draws no
 * caption for them. As the recents provider PowOS sees every task and holds MANAGE_ACTIVITY_TASKS (resizeTask, the
 * task stack listener) and REORDER_TASKS.
 *
 * HACK: TaskInfo.configuration / Configuration.windowConfiguration (a task's bounds and windowing mode),
 * IActivityTaskManager.resizeTask / registerTaskStackListener are hidden: reflected past the checks ([HiddenApi]).
 * ITaskStackListener isn't in the SDK, so its binder is a plain Binder that takes every call as "something changed".
 * Real fix: none for an app - WM Shell's desktop mode (the caption it would draw) is SystemUI's, off on this ROM.
 */
object FreeformTasks {
    private const val TAG = "PowosFreeform"

    /** WindowConfiguration.WINDOWING_MODE_FREEFORM. */
    private const val FREEFORM = 5

    /** ActivityTaskManager.RESIZE_MODE_USER: the window kept (no relaunch) while it's moved or resized. */
    private const val RESIZE_MODE_USER = 1

    /** A floating window: its task, its app (package), where it is (screen px) and whether it shows now. */
    data class Window(
        val id: Int,
        val pkg: String?,
        val bounds: Rect,
        val visible: Boolean,
        /** The density its app lays itself out at now (its task's configuration). */
        val dpi: Int = 0,
        /** Its task's label (TaskDescription): a PowOS (Linux) window's caption. */
        val label: String? = null,
    )

    /** The floating windows, top-most first. */
    fun list(context: Context): List<Window> {
        HiddenApi.allow()
        // getRunningTasks is deprecated for apps (their own tasks only); the recents provider sees them all.
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        return tasks.mapNotNull { t ->
            val wc = runCatching { windowConfiguration(t) }.getOrNull() ?: return@mapNotNull null
            if (wc.javaClass.getMethod("getWindowingMode").invoke(wc) != FREEFORM) return@mapNotNull null
            val bounds = Rect(wc.javaClass.getMethod("getBounds").invoke(wc) as Rect)
            val visible = runCatching { android.app.TaskInfo::class.java.getField("isVisible").getBoolean(t) }.getOrDefault(true)
            val dpi = runCatching { (android.app.TaskInfo::class.java.getField("configuration").get(t) as Configuration).densityDpi }.getOrDefault(0)
            Window(t.taskId, (t.baseActivity ?: t.topActivity)?.packageName, bounds, visible, dpi, t.taskDescription?.label?.toString())
        }
    }

    private fun windowConfiguration(t: ActivityManager.RunningTaskInfo): Any {
        val c = android.app.TaskInfo::class.java.getField("configuration").get(t) as Configuration
        return Configuration::class.java.getField("windowConfiguration").get(c)!!
    }

    /** Task [id]'s window moved/resized to [bounds] (screen px). */
    fun resize(
        id: Int,
        bounds: Rect,
    ): Boolean =
        runCatching {
            HiddenApi.allow()
            atm().javaClass.getMethod("resizeTask", Int::class.javaPrimitiveType, Rect::class.java, Int::class.javaPrimitiveType)
                .invoke(atm(), id, bounds, RESIZE_MODE_USER) as Boolean
        }.onFailure { Log.w(TAG, "can't resize task $id", it) }.getOrDefault(false)

    /** Task [id]'s window above the others (a touch on its frame). */
    fun raise(
        context: Context,
        id: Int,
    ): Boolean =
        runCatching { context.getSystemService(ActivityManager::class.java).moveTaskToFront(id, 0) }
            .onFailure { Log.w(TAG, "can't raise task $id", it) }.isSuccess

    /**
     * Task [id]'s window to the bottom, under home (out of sight, still running): what WM Shell's desktop mode does to
     * minimise (WindowContainerTransaction.reorder(token, onTop = false) through WindowOrganizer). HACK: the token
     * (TaskInfo.token) and the transaction's reorder are hidden, reflected. Real fix: none for an app.
     */
    fun minimise(
        context: Context,
        id: Int,
    ): Boolean =
        transact(context, id) { wct, token -> wct.javaClass.getMethod("reorder", token.javaClass, Boolean::class.javaPrimitiveType).invoke(wct, token, false) }
            .onFailure { Log.w(TAG, "can't minimise task $id", it) }.isSuccess

    /**
     * Task [id]'s content drawn at [dpi] (0: the screen's own again): a real per-task density, the app lays itself out
     * for it (WindowContainerTransaction.setDensityDpi, what WM Shell's desktop mode does to its windows; checked on
     * this ROM 2026-10-22: the task's configuration says the new dpi and its screen width in dp follows). HACK: hidden,
     * reflected like [minimise]. Real fix: none for an app.
     */
    fun density(
        context: Context,
        id: Int,
        dpi: Int,
    ): Boolean =
        transact(context, id) { wct, token -> wct.javaClass.getMethod("setDensityDpi", token.javaClass, Int::class.javaPrimitiveType).invoke(wct, token, dpi) }
            .onFailure { Log.w(TAG, "can't set task $id to $dpi dpi", it) }.isSuccess

    /** One WindowContainerTransaction on task [id]'s container (any windowing mode), applied through WindowOrganizer. */
    private fun transact(
        context: Context,
        id: Int,
        change: (Any, Any) -> Unit,
    ): Result<Unit> =
        runCatching {
            HiddenApi.allow()
            @Suppress("DEPRECATION")
            val info = context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS).firstOrNull { it.taskId == id } ?: error("no task $id")
            val token = android.app.TaskInfo::class.java.getField("token").get(info)!!
            val wctClass = Class.forName("android.window.WindowContainerTransaction")
            val wct = wctClass.getConstructor().newInstance()
            change(wct, token)
            val organizer = Class.forName("android.window.WindowOrganizer")
            organizer.getMethod("applyTransaction", wctClass).invoke(organizer.getConstructor().newInstance(), wct)
            Unit
        }

    /**
     * Calls [changed] (on a binder thread) whenever Android's tasks change - opened, raised, moved, closed; a handle to
     * stop it, or null where the listener can't be registered.
     */
    fun listen(changed: () -> Unit): (() -> Unit)? {
        val binder =
            object : Binder() {
                override fun onTransact(
                    code: Int,
                    data: Parcel,
                    reply: Parcel?,
                    flags: Int,
                ): Boolean {
                    if (code == INTERFACE_TRANSACTION) return super.onTransact(code, data, reply, flags)
                    changed()
                    return true
                }
            }
        return runCatching {
            HiddenApi.allow()
            val type = Class.forName("android.app.ITaskStackListener")
            val listener = Class.forName("android.app.ITaskStackListener\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, binder)
            atm().javaClass.getMethod("registerTaskStackListener", type).invoke(atm(), listener)
            Log.i(TAG, "task stack listener on")
            val stop: () -> Unit = {
                runCatching { atm().javaClass.getMethod("unregisterTaskStackListener", type).invoke(atm(), listener) }
            }
            stop
        }.onFailure { Log.w(TAG, "no task stack listener", it) }.getOrNull()
    }

    private const val MAX_TASKS = 24

    private fun atm(): Any = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
}
