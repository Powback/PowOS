package dev.omalauncher.system

import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.SurfaceControl
import android.view.SurfaceControlViewHost
import android.view.View

/**
 * Feasibility probe for title bars that live IN the task's own layer (board task floating-window-title-bars-z-ordered-
 * with-their): a surface PowOS owns, parented under the task's SurfaceControl, so it z-orders with its window, is
 * covered by the window above, and rides the leash in a page slide by construction - instead of WindowFrame's
 * TYPE_APPLICATION_OVERLAY bar windows that sit above every task.
 *
 * What the phone already showed (SurfaceFlinger dump, 2026-10-28): SystemUI (uid 10262, not system_server) parents its
 * "Decor container of Task=N" (a SurfaceControlViewHost, z=30000, with its own input window) under "Task=N"; the task
 * layer crops to the task's bounds (geomCrop 0 0 w h), so a bar must sit INSIDE the bounds, with the app's content
 * inset below it (a captionBar insets source), not above the window as the overlay bar does now.
 *
 * What this probe proves on device: PowOS can parent its own SurfaceControlViewHost under a task leash it got from a
 * transition it plays ([TaskLeash.Session]), the child survives the transition's end, draws inside the crop, and gets
 * touches. Off unless `settings put global powos_bar_in_task 1`; then the next TaskLeash session (a drag, maximise or
 * page slide) puts a 1-bar-high tinted strip at the top of each of its tasks, once per task. Logcat PowosTaskBar;
 * SurfaceFlinger: a SurfaceControlViewHost layer of this app (pid) under "Task=N". [release] on the frame's removal.
 *
 * HACK: a probe, not the bar - solid tint, no chrome, no insets source (it covers the app's top rows). Real fix: the
 * frame's FrameChrome in this host, WCT addInsetsSource(captionBar) of its height, the overlay bar dropped.
 */
object TaskBarProbe {
    private const val TAG = "PowosTaskBar"
    private val main = Handler(Looper.getMainLooper())
    private val hosts = HashMap<Int, SurfaceControlViewHost>()

    fun enabled(context: Context) =
        android.provider.Settings.Global.getInt(context.contentResolver, "powos_bar_in_task", 0) == 1

    /** Under [leash] (task [id]'s own surface, from a transition PowOS plays), once per task. Main thread. */
    fun attach(context: Context, id: Int, leash: SurfaceControl, width: Int) {
        if (!enabled(context) || id in hosts || width <= 0 || !leash.isValid) return
        runCatching {
            val display = context.display ?: return
            val h = (WindowFrame.BAR_DP * context.resources.displayMetrics.density).toInt().coerceAtLeast(1)
            val host = SurfaceControlViewHost(context, display, null as android.os.IBinder?)
            val view = View(context).apply {
                setBackgroundColor(Color.argb(160, 120, 170, 255))
                setOnTouchListener { _, e -> if (e.actionMasked == MotionEvent.ACTION_DOWN) Log.i(TAG, "task $id: touch at ${e.x.toInt()},${e.y.toInt()}"); true }
            }
            host.setView(view, width, h)
            val sc = host.surfacePackage?.surfaceControl ?: error("no surface package")
            SurfaceControl.Transaction().reparent(sc, leash).setPosition(sc, 0f, 0f).setLayer(sc, Int.MAX_VALUE).setVisibility(sc, true).apply()
            hosts[id] = host
            Log.i(TAG, "task $id: bar attached under its leash (${width}x$h)")
        }.onFailure { Log.w(TAG, "task $id: can't attach", it) }
    }

    fun release(id: Int) {
        main.post { hosts.remove(id)?.let { runCatching { it.release() }; Log.i(TAG, "task $id: released") } }
    }
}
