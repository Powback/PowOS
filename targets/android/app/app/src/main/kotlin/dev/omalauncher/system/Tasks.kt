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

    /** Every task removal / window close PowOS makes logs one line under this tag, with its caller (`logcat -s PowosTaskRemove`). */
    const val REMOVE_TAG = "PowosTaskRemove"

    /** Tasks PowOS asked to remove lately (task id -> uptime): a removal the system reports that isn't here was someone else's. */
    private val asked = java.util.concurrent.ConcurrentHashMap<Int, Long>()

    /**
     * One [REMOVE_TAG] line for [what] ("removeTask", "finishAndRemoveTask", "Tasks.remove", "closeForTask", "drop",
     * "close") of task [id] (-1: none known) and [why], with the PowOS frames of the call stack that made it. A real
     * task removal ([removes]) is remembered for [removedBy].
     */
    fun logRemove(
        what: String,
        id: Int,
        why: String,
        removes: Boolean = false,
    ) {
        if (removes && id >= 0) asked[id] = android.os.SystemClock.uptimeMillis()
        val frames =
            Throwable().stackTrace.asSequence()
                .drop(1)
                .filter { (it.className.startsWith("dev.omalauncher") || it.className.startsWith("andro.marchy")) && !it.methodName.startsWith("logRemove") }
                .take(6)
                .joinToString(" < ") { "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" }
        Log.i(REMOVE_TAG, "$what task=$id ($why) thread=${Thread.currentThread().name} by $frames")
    }

    /** Task [id] gone: "PowOS (N ms after it asked)" when PowOS removed it lately, else "not PowOS" (the system, the app, OnePlus). */
    fun removedBy(id: Int): String {
        val at = asked.remove(id) ?: return "not PowOS (no PowOS removal of it logged)"
        return "PowOS (${android.os.SystemClock.uptimeMillis() - at} ms after it asked)"
    }

    /** A recent task: its id, the app it's of (package, base activity) and its title. */
    data class Task(
        val id: Int,
        val component: ComponentName?,
        val label: String?,
        /** When it was last in front (SystemClock.uptimeMillis): its snapshot is new only when this is. */
        val lastActive: Long = 0,
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
            Task(t.taskId, component, t.taskDescription?.label, lastActive(t))
        }
    }

    /** TaskInfo.lastActiveTime (a hidden field; 0 where it can't be read). */
    private fun lastActive(t: ActivityManager.RecentTaskInfo): Long =
        runCatching { android.app.TaskInfo::class.java.getField("lastActiveTime").getLong(t) }.getOrDefault(0L)

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
        // A floating window that is there already (unfolded home): raised alone. startActivityFromRecents of a freeform
        // task on this ROM is a TO_FRONT transition that sends every other floating task TO_BACK - the other windows
        // vanished (logcat 2026-10-24 #901: TO_FRONT t2915, t2909 m=TO_BACK), where moveTaskToFront of the same kind of
        // task moved only that one (#902: t2909 TO_FRONT, nothing else in the change). The dock, the switcher, a launcher
        // tap on an open Linux window and the quick switch all come through here. A task of another mode (full screen,
        // folded, gone) still takes startActivityFromRecents: it restarts a dead task and applies [options]' bounds.
        if (AppWindows.floating(context) && FreeformTasks.list(context).any { it.id == id } && FreeformTasks.raise(context, id)) {
            Log.i(TAG, "task $id raised (moveTaskToFront: the other floating windows stay)")
            return true
        }
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

    /** WM Shell's ISplitScreen (ILauncherProxy.onInitialize hands it over): the switcher's split screen. */
    @Volatile
    var splitScreen: android.os.IBinder? = null

    /**
     * Tasks [first] (left / top) and [second] side by side, half and half (left / right on the unfolded screen: SplitSideBySide): WM Shell's split screen, as Quickstep's
     * split from overview (ISplitScreen.startTasks). False when WM Shell can't be asked.
     *
     * HACK: ISplitScreen is WM Shell's, hidden and not in the SDK: its call is written by hand as the generated AIDL
     * would (this phone's SystemUI: startTasks is transaction 11; SNAP_TO_2_50_50 is 1; InstanceId's parcel is its
     * int). Real fix: none for an app - Quickstep compiles against the platform's copy.
     */
    fun split(
        first: Int,
        second: Int,
        position: Int = SPLIT_POSITION_TOP_OR_LEFT,
        snap: Int = SNAP_TO_2_50_50,
    ): Boolean {
        val binder = splitScreen ?: return false.also { Log.w(TAG, "no ISplitScreen from SystemUI") }
        return runCatching {
            val data = android.os.Parcel.obtain()
            try {
                data.writeInterfaceToken("com.android.wm.shell.splitscreen.ISplitScreen")
                data.writeInt(first)
                data.writeTypedObject(null as android.os.Bundle?, 0)
                data.writeInt(second)
                data.writeTypedObject(null as android.os.Bundle?, 0)
                // [first] goes to [position] (SplitDrawer puts a tucked app back on its own edge); [snap] is the divider.
                data.writeInt(position)
                data.writeInt(snap)
                // No remote transition (WM Shell animates it); an InstanceId (its parcel: present, then its id).
                data.writeInt(0)
                data.writeInt(1)
                data.writeInt((System.nanoTime() and 0xFFFFF).toInt().coerceAtLeast(1))
                binder.transact(SPLIT_START_TASKS, data, null, android.os.IBinder.FLAG_ONEWAY)
            } finally {
                data.recycle()
            }
        }.onFailure { Log.w(TAG, "can't split $first and $second", it) }.isSuccess
    }

    /**
     * The switcher's split ([split]) of two real apps only: never PowOS home itself as a side (10-31 logcat
     * `split=[com.powos.app, com.discord]`: a pick of home's own task, or of a PowOS app in home, split home in half),
     * never one task twice, never a task no longer listed. False (nothing split) otherwise.
     */
    fun splitApps(
        context: Context,
        first: Int,
        second: Int,
    ): Boolean {
        val listed = list(context).associateBy { it.id }
        val bad =
            listOf(first, second).firstOrNull { id ->
                val pkg = listed[id]?.component?.packageName
                id < 0 || pkg == null || pkg == context.packageName
            }
        if (first == second || bad != null) {
            Log.w(TAG, "split of $first and $second refused: ${if (first == second) "the same task" else "task $bad is home or not an app"}")
            return false
        }
        return split(first, second)
    }

    /** Task [id] in a floating window (freeform: the OS's pop-up view), in the middle of the screen. */
    fun float(
        context: Context,
        id: Int,
    ): Boolean {
        val screen = context.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds
        val w = screen.width() * 3 / 4
        val h = screen.height() / 2
        FreeformTasks.markOwnFloat(id)
        // The switcher's "Floating window" (and the split drawer's): the user's own pick, a native floating window that
        // stays one (D1) - never turned into a web window; "Desktop window" is the path for that.
        FreeformTasks.markNativeFloat(id)
        return open(context, id, freeformOptions(android.graphics.Rect(screen.centerX() - w / 2, screen.centerY() - h / 2, screen.centerX() + w / 2, screen.centerY() + h / 2)))
    }

    /**
     * Launch options ([base]'s, else plain) for a floating (freeform) window at [bounds] (screen px). HACK: ActivityOptions.setLaunchWindowingMode
     * is hidden (reflected); real fix: none for an app. Without freeform support (enable_freeform_support off) Android
     * opens the app full screen anyway.
     */
    fun freeformOptions(
        bounds: android.graphics.Rect,
        base: ActivityOptions? = null,
    ): ActivityOptions {
        val options = (base ?: ActivityOptions.makeBasic()).setLaunchBounds(bounds)
        runCatching {
            HiddenApi.allow()
            ActivityOptions::class.java.getMethod("setLaunchWindowingMode", Int::class.javaPrimitiveType).invoke(options, WINDOWING_MODE_FREEFORM)
        }.onFailure { Log.w(TAG, "no freeform launch", it) }
        return options
    }

    /** Task [id]'s app's info screen (Settings). */
    fun info(
        context: Context,
        id: Int,
    ): Boolean {
        val pkg = list(context).firstOrNull { it.id == id }?.component?.packageName ?: return false
        return runCatching {
            context.startActivity(
                android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", pkg, null))
                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }.isSuccess
    }

    /** Task [id]'s last frame saved as a screenshot (Pictures/Screenshots); its name, or null. */
    fun screenshot(
        context: Context,
        id: Int,
    ): String? {
        val jpeg = snapshot(id, Int.MAX_VALUE) ?: return null
        val name = "Screenshot_${java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US).format(java.util.Date())}.jpg"
        return runCatching {
            val values =
                android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                    put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Screenshots")
                }
            val uri = context.contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return null
            context.contentResolver.openOutputStream(uri)?.use { it.write(jpeg) }
            name
        }.onFailure { Log.w(TAG, "can't save task $id's screenshot", it) }.getOrNull()
    }

    private const val SPLIT_START_TASKS = 11
    // SplitScreenConstants (this phone's SystemUI, dexdump): positions and the 2-app snap targets (left/top share).
    const val SPLIT_POSITION_TOP_OR_LEFT = 0
    const val SPLIT_POSITION_BOTTOM_OR_RIGHT = 1
    const val SNAP_TO_2_33_66 = 0
    const val SNAP_TO_2_50_50 = 1
    const val SNAP_TO_2_66_33 = 2
    private const val WINDOWING_MODE_FREEFORM = 5

    /**
     * Removes task [id] from recents (and ends its activities, as the stock switcher's swipe away) - any app's, one
     * whose widget is on home too: the widget is RemoteViews PowOS hosts, it outlives the provider's process
     * (AppWidgets keeps the last ones and heals). PowOS's own (the assistant, a window) is finished as a task of ours -
     * its activities only, never the process that hosts home, its widgets and the gestures.
     */
    fun remove(
        context: Context,
        id: Int,
    ): Boolean {
        // A web window's task (on its display, or its full-screen app): the window closes, its task and display with it -
        // one close path with the window's own close button (WebWindows.closeForTask).
        logRemove("Tasks.remove", id, "asked")
        if (dev.omalauncher.shell.WebWindows.closeForTask(context, id)) return true
        val task = list(context).firstOrNull { it.id == id }
        val pkg = task?.component?.packageName
        logRemove(if (pkg == context.packageName) "finishAndRemoveTask" else "removeTask", id, "Tasks.remove of $pkg (no web window's)", removes = true)
        // Its window too, if a web window still thinks it holds it (a stale task map): never a ghost frame.
        dev.omalauncher.shell.WebWindows.taskRemovedByPowos(id)
        if (pkg == context.packageName) {
            // A Linux window's task (PowosWindowActivity): the user closed it (swiped its card, the frame's close), so
            // the app goes too - KWin closes its window, then ends its process tree if it stays (WindowTasks.quit).
            andro.marchy.WindowTasks.quitting(id)
            val own = context.getSystemService(ActivityManager::class.java).appTasks.firstOrNull { runCatching { it.taskInfo?.taskId }.getOrNull() == id }
            if (own != null) return runCatching { own.finishAndRemoveTask() }.onFailure { Log.w(TAG, "can't finish own task $id", it) }.isSuccess
            Log.w(TAG, "task $id is PowOS's own but not among its app tasks: removeTask")
        }
        return runCatching {
            HiddenApi.allow()
            (atm().javaClass.getMethod("removeTask", Int::class.javaPrimitiveType).invoke(atm(), id) as Boolean).also { if (!it) Log.w(TAG, "removeTask($id) said no (pkg $pkg, listed ${task != null})") }
        }.onFailure { Log.w(TAG, "can't remove task $id", it) }.getOrDefault(false)
    }

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
