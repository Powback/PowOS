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

    /** WindowConfiguration.WINDOWING_MODE_FULLSCREEN and ACTIVITY_TYPE_STANDARD (an app, not home/recents/assistant). */
    private const val FULLSCREEN = 1
    private const val ACTIVITY_TYPE_STANDARD = 1

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
        val z = stackOrder()?.withIndex()?.associate { (i, id) -> id to i }
        return (if (z == null) tasks else tasks.sortedBy { z[it.taskId] ?: Int.MAX_VALUE }).mapNotNull { t ->
            val wc = runCatching { windowConfiguration(t) }.onFailure { if (!unreadable) Log.w(TAG, "can't read task ${t.taskId}'s window", it) }.getOrNull()
            unreadable = wc == null
            if (wc == null) return@mapNotNull null
            if (wc.javaClass.getMethod("getWindowingMode").invoke(wc) != FREEFORM) return@mapNotNull null
            val bounds = Rect(wc.javaClass.getMethod("getBounds").invoke(wc) as Rect)
            val visible = runCatching { android.app.TaskInfo::class.java.getField("isVisible").getBoolean(t) }.getOrDefault(true)
            val dpi = runCatching { (android.app.TaskInfo::class.java.getField("configuration").get(t) as Configuration).densityDpi }.getOrDefault(0)
            Window(t.taskId, (t.baseActivity ?: t.topActivity)?.packageName, bounds, visible, dpi, t.taskDescription?.label?.toString())
        }
    }

    /**
     * Task ids top-most first as WM stacks them (IActivityTaskManager.getAllRootTaskInfos walks the root tasks top to
     * bottom; a floating window's task is its own root), or null. getRunningTasks sorts by last-active time instead: a
     * window raised by a reorder (restore, a desktop switch) kept its old place there, so the frames stacked a lower
     * window's bar over the front one's (a drag on Calculator's bar moved Chrome, 2026-10-23) and the dock's "window in
     * front" was the wrong one. HACK: hidden, reflected like [minimise] (MANAGE_ACTIVITY_TASKS, held as the recents
     * provider). Real fix: none for an app.
     */
    private fun stackOrder(): List<Int>? =
        runCatching {
            val roots = atm().javaClass.getMethod("getAllRootTaskInfos").invoke(atm()) as List<*>
            roots.map { android.app.TaskInfo::class.java.getField("taskId").getInt(it) }
        }.onFailure { if (!noOrder) Log.w(TAG, "no stacking order: windows in last-active order", it) }
            .also { noOrder = it.isFailure }.getOrNull()

    @Volatile private var noOrder = false

    /**
     * The app tasks showing full screen now (an ordinary activity: not home, recents, the assistant or a dream), top-most
     * first, as task id -> its package: on the unfolded home every app is a window ([toWindow] makes one of them).
     */
    fun fullScreen(context: Context): List<Pair<Int, String?>> {
        HiddenApi.allow()
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        return tasks.filter { isFullScreenApp(it) }.map { it.taskId to (it.baseActivity ?: it.topActivity)?.packageName }
    }

    private fun isFullScreenApp(t: ActivityManager.RunningTaskInfo): Boolean {
        val wc = runCatching { windowConfiguration(t) }.getOrNull() ?: return false
        val mode = wc.javaClass.getMethod("getWindowingMode").invoke(wc)
        val type = wc.javaClass.getMethod("getActivityType").invoke(wc)
        val visible = runCatching { android.app.TaskInfo::class.java.getField("isVisible").getBoolean(t) }.getOrDefault(false)
        return mode == FULLSCREEN && type == ACTIVITY_TYPE_STANDARD && visible
    }

    /**
     * Task [id] (full screen) made a floating window at [bounds] (screen px): WindowContainerTransaction.setWindowingMode
     * + setBounds through WindowOrganizer, as WM Shell's desktop mode moves a task into a desktop. For an app opened
     * WITHOUT PowOS's launch options (another app, a notification of the system's, `am start`): Android puts a task
     * started with no source window full screen. HACK: hidden, reflected like [minimise]. Real fix: none for an app.
     */
    fun toWindow(
        context: Context,
        id: Int,
        bounds: Rect,
    ): Boolean =
        transact(context, id) { wct, token ->
            wct.javaClass.getMethod("setWindowingMode", token.javaClass, Int::class.javaPrimitiveType).invoke(wct, token, FREEFORM)
            wct.javaClass.getMethod("setBounds", token.javaClass, Rect::class.java).invoke(wct, token, bounds)
        }.onFailure { Log.w(TAG, "can't make task $id a window", it) }.isSuccess

    /**
     * Task [id] over the whole screen ([on]: the app asked for full screen - a video, a game) or a floating window
     * again at [bounds]. What WM Shell's desktop mode does to move a task to full screen and back (DesktopTasksController:
     * windowing mode UNDEFINED = the display's full screen, bounds cleared; back: FREEFORM + its bounds), as a change
     * transition so WM Shell puts the app's content (its leash) where the task is. HACK: hidden, reflected like
     * [minimise]. Real fix: none for an app.
     */
    fun setFullScreen(
        context: Context,
        id: Int,
        on: Boolean,
        bounds: Rect?,
    ): Boolean {
        val mode = if (on) UNDEFINED else FREEFORM
        val to = if (on) Rect() else bounds ?: Rect()
        return runCatching { apply(token(context, id), transition = true) { wct, token -> modeAndBounds(wct, token, mode, to) } }
            .onFailure { Log.w(TAG, "can't put task $id in windowing mode $mode", it) }.isSuccess
    }

    private fun modeAndBounds(
        wct: Any,
        token: Any,
        mode: Int,
        bounds: Rect,
    ) {
        wct.javaClass.getMethod("setWindowingMode", token.javaClass, Int::class.javaPrimitiveType).invoke(wct, token, mode)
        wct.javaClass.getMethod("setBounds", token.javaClass, Rect::class.java).invoke(wct, token, bounds)
    }

    /** WindowConfiguration.WINDOWING_MODE_UNDEFINED: the display's own (full screen). */
    private const val UNDEFINED = 0

    /** The last task's window couldn't be read (logged once, not on every refresh). */
    @Volatile private var unreadable = false

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
    ): Result<Unit> = runCatching { apply(token(context, id), change = change) }

    /** Task [id]'s WindowContainerToken (TaskInfo.token, hidden). */
    private fun token(
        context: Context,
        id: Int,
    ): Any {
        HiddenApi.allow()
        @Suppress("DEPRECATION")
        val info = context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS).firstOrNull { it.taskId == id } ?: error("no task $id")
        return android.app.TaskInfo::class.java.getField("token").get(info)!!
    }

    /**
     * Applies [change] to the window of [token]. [transition]: as a change transition (WindowOrganizer.startNewTransition,
     * TRANSIT_CHANGE) that WM Shell plays, so its leash - where the app's content is drawn - goes to the new bounds too.
     * A bare applyTransaction moves the task in WM only: WM Shell owns the task's surface position, and the content
     * stayed drawn where the window had been until a minimise and restore (e2e r3 2026-10-23: bar at 887, the app at
     * 556 after a bar drag).
     */
    private fun apply(
        token: Any,
        transition: Boolean = false,
        change: (Any, Any) -> Unit,
    ) {
        val wctClass = Class.forName("android.window.WindowContainerTransaction")
        val wct = wctClass.getConstructor().newInstance()
        change(wct, token)
        val organizer = Class.forName("android.window.WindowOrganizer")
        val o = organizer.getConstructor().newInstance()
        if (transition) {
            val started = runCatching { organizer.getMethod("startNewTransition", Int::class.javaPrimitiveType, wctClass).invoke(o, TRANSIT_CHANGE, wct) }
            if (started.isSuccess) return
            Log.w(TAG, "no change transition, the bounds without one", started.exceptionOrNull())
        }
        organizer.getMethod("applyTransaction", wctClass).invoke(o, wct)
    }

    /**
     * A finger moving or resizing task [id]'s window: its bounds set straight through WindowOrganizer each move, as WM
     * Shell's desktop mode does (FluidResizeTaskPositioner: WindowContainerTransaction.setBounds, drag-resizing on
     * while it's resized), so the app lays itself out at the new size as the finger goes. Through resizeTask the app's
     * content took the new size only after the finger lifted (the user, 2026-10-23); likely its change transition per
     * call queueing - logcat PowosWindowResize has the live path's numbers per drag.
     * HACK: the token and the transaction's setBounds/setDragResizing are hidden, reflected like [minimise]; a
     * failure falls back to [resize]. Real fix: none for an app.
     */
    class Live(
        context: Context,
        private val id: Int,
        private val resizing: Boolean,
    ) {
        private val token = runCatching { token(context, id) }.onFailure { Log.w(TAG, "no live bounds for task $id", it) }.getOrNull()
        private var started = false

        /** The window to [bounds] now: true when applied (a fallback to resizeTask says false). */
        fun to(bounds: Rect): Boolean = set(bounds, drag = true)

        /** The finger lifted, the window at [bounds]: drag-resizing off. */
        fun end(bounds: Rect) {
            if (!set(bounds, drag = false)) resize(id, bounds)
        }

        private fun set(
            bounds: Rect,
            drag: Boolean,
        ): Boolean {
            val t = token ?: return resize(id, bounds).let { false }
            return runCatching {
                // A move's one call (the finger lifted) as a transition: WM Shell puts the app's content where the window
                // is. Never a resize's: its end in a transition left the app at its old size in a white new-size
                // window and WM at the old bounds (the user, 13:43 2026-10-23); resizes stay plain transactions.
                apply(t, transition = !drag && !resizing) { wct, tok ->
                    wct.javaClass.getMethod("setBounds", tok.javaClass, Rect::class.java).invoke(wct, tok, bounds)
                    if (resizing && drag != started) wct.javaClass.getMethod("setDragResizing", tok.javaClass, Boolean::class.javaPrimitiveType).invoke(wct, tok, drag)
                }
                started = drag
                true
            }.onFailure { Log.w(TAG, "can't set task $id's bounds", it) }.getOrElse { resize(id, bounds).let { false } }
        }
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

    /** WindowManager.TRANSIT_CHANGE (hidden). */
    private const val TRANSIT_CHANGE = 6

    private fun atm(): Any = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
}
