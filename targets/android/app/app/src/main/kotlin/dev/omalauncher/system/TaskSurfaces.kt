package dev.omalauncher.system

import android.app.ActivityManager
import android.content.Context
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.SurfaceControl
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Every desktop window's surface: task id -> the task's SurfaceControl (its leash), as WM Shell hands it to PowOS in a
 * transition (docs/DESKTOP-NATIVE.md, "Desktop windows inside the web shell", step 2). Fed by every [TaskLeash] session
 * (a drag, maximise, page slide: a task's first move records it) and by TaskLeash's permanent open remote (a freeform
 * task opened or brought to front). An entry goes when its task does (FreeformTasks.listen), when its surface is no
 * longer valid, and all of them on a display change or fold (the next open/move records them again).
 *
 * The in-task frames (step 4) parent their SurfaceControlViewHost under [get]; [listen] says when one comes or goes.
 * Thread-safe; listeners run on the main thread.
 */
object TaskSurfaces {
    private const val TAG = "PowosTaskSurfaces"

    private val surfaces = ConcurrentHashMap<Int, SurfaceControl>()
    private val listeners = CopyOnWriteArrayList<(Int, SurfaceControl?) -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var app: Context? = null
    private var stopTasks: (() -> Unit)? = null
    private var screen: String? = null

    /** Task [id]'s surface, or null: not seen in a transition yet (or dropped since). */
    fun get(id: Int): SurfaceControl? = surfaces[id]?.takeIf { it.isValid }

    /** The task ids PowOS holds a surface of. */
    fun ids(): Set<Int> = surfaces.keys.toSet()

    /** Calls [changed] (main thread) with a task id and its new surface, or null when it was dropped; a handle to stop. */
    fun listen(changed: (Int, SurfaceControl?) -> Unit): () -> Unit {
        listeners.add(changed)
        return { listeners.remove(changed) }
    }

    /**
     * Starts dropping entries as tasks vanish and on display changes; idempotent (PowosRecentsService, once SystemUI
     * connects). Without it entries still come and go by [record] and an invalid surface reads as none.
     */
    fun start(context: Context) {
        main.post {
            if (app != null) return@post
            val c = context.applicationContext
            app = c
            stopTasks = FreeformTasks.listen { prune() }
            val dm = c.getSystemService(DisplayManager::class.java)
            screen = screenKey(dm)
            dm.registerDisplayListener(
                object : DisplayManager.DisplayListener {
                    override fun onDisplayAdded(displayId: Int) {}

                    override fun onDisplayRemoved(displayId: Int) {}

                    override fun onDisplayChanged(displayId: Int) {
                        if (displayId != Display.DEFAULT_DISPLAY) return
                        val now = screenKey(dm)
                        if (now == screen) return
                        Log.i(TAG, "display changed ($screen -> $now): all dropped")
                        screen = now
                        dropAll("display change")
                    }
                },
                main,
            )
            Log.i(TAG, "watching tasks and the display")
        }
    }

    /** The leashes a transition handed over ([from]: which one, for the log). */
    fun record(
        leashes: Map<Int, SurfaceControl>,
        from: String,
    ) {
        for ((id, leash) in leashes) {
            if (!leash.isValid) continue
            val old = surfaces.put(id, leash)
            if (old === leash) continue // (SurfaceControl.isSameSurface is @hide: a re-handed copy of the same leash logs again)
            Log.i(TAG, "registered task $id ($from)${if (old != null) ", replaced" else ""}")
            say(id, leash)
        }
    }

    /** Task [id]'s entry gone ([why]: for the log). */
    fun drop(
        id: Int,
        why: String,
    ) {
        if (surfaces.remove(id) == null) return
        Log.i(TAG, "dropped task $id ($why)")
        say(id, null)
    }

    private fun dropAll(why: String) {
        for (id in surfaces.keys.toList()) drop(id, why)
    }

    /** Binder thread (the task stack listener): entries whose task is gone or whose surface died go. */
    private fun prune() {
        if (surfaces.isEmpty()) return
        val c = app ?: return
        val running =
            runCatching {
                @Suppress("DEPRECATION")
                c.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS).map { it.taskId }.toSet()
            }.onFailure { Log.w(TAG, "can't list tasks", it) }.getOrNull() ?: return
        for ((id, leash) in surfaces.entries.toList()) {
            when {
                id !in running -> drop(id, "task gone")
                !leash.isValid -> drop(id, "surface released")
            }
        }
    }

    private fun say(
        id: Int,
        surface: SurfaceControl?,
    ) {
        if (listeners.isEmpty()) return
        main.post { for (l in listeners) runCatching { l(id, surface) }.onFailure { Log.w(TAG, "a listener failed", it) } }
    }

    /** Size + rotation of the main display: a fold swaps the panel behind display 0, a rotation turns it. */
    private fun screenKey(dm: DisplayManager): String {
        val d = dm.getDisplay(Display.DEFAULT_DISPLAY) ?: return ""
        val p = Point()
        @Suppress("DEPRECATION")
        d.getRealSize(p)
        return "${p.x}x${p.y}@${d.rotation}"
    }

    /** Enough to list every desktop window (a task past it would be dropped wrongly, so it is generous). */
    private const val MAX_TASKS = 64
}
