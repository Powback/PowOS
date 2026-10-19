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
     * Tasks [first] (left / top) and [second] side by side, half and half: WM Shell's split screen, as Quickstep's
     * split from overview (ISplitScreen.startTasks). False when WM Shell can't be asked.
     *
     * HACK: ISplitScreen is WM Shell's, hidden and not in the SDK: its call is written by hand as the generated AIDL
     * would (this phone's SystemUI: startTasks is transaction 11; SNAP_TO_2_50_50 is 1; InstanceId's parcel is its
     * int). Real fix: none for an app - Quickstep compiles against the platform's copy.
     */
    fun split(
        first: Int,
        second: Int,
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
                data.writeInt(SPLIT_POSITION_TOP_OR_LEFT)
                data.writeInt(SNAP_TO_2_50_50)
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
     * Task [id] in a floating window (freeform: the OS's pop-up view), in the middle of the screen. HACK:
     * ActivityOptions.setLaunchWindowingMode is hidden (reflected); real fix: none for an app.
     */
    fun float(
        context: Context,
        id: Int,
    ): Boolean {
        val screen = context.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds
        val w = screen.width() * 3 / 4
        val h = screen.height() / 2
        val options = ActivityOptions.makeBasic().setLaunchBounds(android.graphics.Rect(screen.centerX() - w / 2, screen.centerY() - h / 2, screen.centerX() + w / 2, screen.centerY() + h / 2))
        runCatching {
            HiddenApi.allow()
            ActivityOptions::class.java.getMethod("setLaunchWindowingMode", Int::class.javaPrimitiveType).invoke(options, WINDOWING_MODE_FREEFORM)
        }.onFailure { Log.w(TAG, "no freeform launch", it) }
        return open(context, id, options)
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
    private const val SPLIT_POSITION_TOP_OR_LEFT = 0
    private const val SNAP_TO_2_50_50 = 1
    private const val WINDOWING_MODE_FREEFORM = 5

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
