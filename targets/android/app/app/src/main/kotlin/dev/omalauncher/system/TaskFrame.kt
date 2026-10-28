package dev.omalauncher.system

import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.SurfaceControl
import android.view.SurfaceControlViewHost

/**
 * A window's title bar IN the task's own layer (docs/DESKTOP-NATIVE.md, "Desktop windows inside the web shell", step 4):
 * a SurfaceControlViewHost PowOS owns, parented under the task's SurfaceControl ([TaskSurfaces]), at the top of the
 * task inside its bounds - so it z-orders with its window, is covered by the window above, and rides the leash in a
 * drag or page slide by construction, instead of WindowFrame's TYPE_APPLICATION_OVERLAY bar above every task.
 *
 * It shows the same web bar as WindowFrame's ([FrameChrome] "window"); its buttons act as that bar's do
 * ([WindowFrame.barAction]: minimise, maximise = WindowFrames.fullScreen, close), and the rest of a touch goes to the
 * frame's own drag ([WindowFrame.barTouch]: a drag moves the window through its TaskLeash session; a double tap or a
 * mouse double click - two quick DOWN/UP pairs - is WindowFrames.maximise, in place, and back). The app's content
 * starts under it: a captionBar insets source of its height ([FreeformTasks.captionInsets], step 5).
 *
 * Shown since SystemUI does the same for its own caption (SurfaceFlinger, 2026-10-28: "Decor container of Task=N", an
 * SCVH under "Task=N"; the task layer crops to its bounds, so the bar sits inside them).
 *
 * Off unless `settings put global powos_bar_in_task 1` (step 6 makes it the default and drops the overlay bar); until
 * then a window shows both bars. Logcat PowosTaskFrame. Main thread.
 */
class TaskFrame private constructor(
    private val context: Context,
    val id: Int,
    private val frame: WindowFrame,
    private var leash: SurfaceControl,
    private var width: Int,
) {
    private val height = (BAR_DP * context.resources.displayMetrics.density).toInt().coerceAtLeast(1)
    private val chrome = FrameChrome(context, "window", frame.barApp) { frame.barAction(it) }
    private val host = SurfaceControlViewHost(context, context.display!!, null as android.os.IBinder?)

    init {
        val web = chrome.web
        // HACK: no compositor blur under an SCVH (WindowBlur needs a window of WM's); the glass is the page's own tint
        // over the app's top rows. Real fix: a blur-behind on the SCVH's layer (SurfaceControl.Transaction.setBackgroundBlurRadius).
        web.setBackgroundColor(Color.TRANSPARENT)
        // The WebView never gets the touch (as WindowFrame's bar): the frame's drag takes all of it, buttons by DOM rects.
        web.setOnTouchListener { _, e -> frame.barTouch(e) { x, y -> chrome.buttonAt(x, y) } }
        web.onResume()
        host.setView(web, width, height)
        val sc = host.surfacePackage?.surfaceControl ?: error("no surface package")
        SurfaceControl.Transaction().reparent(sc, leash).setPosition(sc, 0f, 0f).setLayer(sc, Int.MAX_VALUE).setVisibility(sc, true).apply()
        insets()
        Log.i(TAG, "task $id: bar in its own layer (${width}x$height)")
    }

    private fun insets() {
        val ok = FreeformTasks.captionInsets(context, id, frame.bounds, height)
        Log.i(TAG, "task $id: caption inset $height px ${if (ok) "set" else "NOT set"}")
    }

    /** The task's surface or width changed: re-parented / re-laid out. */
    private fun update(to: SurfaceControl, w: Int) {
        if (to !== leash) {
            leash = to
            host.surfacePackage?.surfaceControl?.let { SurfaceControl.Transaction().reparent(it, to).setLayer(it, Int.MAX_VALUE).apply() }
            Log.i(TAG, "task $id: moved under its new surface")
        }
        if (w != width) {
            width = w
            host.relayout(w, height)
            insets()
        }
    }

    fun maximised(on: Boolean) = chrome.maximised(on)

    private fun release() {
        runCatching { host.release() }
        chrome.destroy()
        Log.i(TAG, "task $id: released")
    }

    companion object {
        private const val TAG = "PowosTaskFrame"

        /** The bar's height inside the task (dp): the same web bar and touch strip as the overlay's. */
        private const val BAR_DP = WindowFrame.BAR_DP + WindowFrame.HIT_DP

        private val main = Handler(Looper.getMainLooper())
        private val frames = HashMap<Int, TaskFrame>()
        private var listening = false

        fun enabled(context: Context) = android.provider.Settings.Global.getInt(context.contentResolver, "powos_bar_in_task", 0) == 1

        /**
         * Task [id]'s in-task bar made, moved or dropped to match its surface ([TaskSurfaces]) and its frame
         * (WindowFrames: bounds, app). Called on a frame's layout, on a TaskLeash session's start, and when a surface
         * comes or goes. Main thread.
         */
        fun sync(context: Context, id: Int) {
            if (!enabled(context)) return
            if (!listening) {
                listening = true
                TaskSurfaces.listen { task, _ -> sync(context, task) }
            }
            val leash = TaskSurfaces.get(id)
            val frame = WindowFrames.current?.frame(id)
            // A window that draws its own title bar (a Linux window's CSD) gets none of ours.
            if (leash == null || frame == null || frame.ownBar || frame.bounds.width() <= 0) return release(id)
            val w = frame.bounds.width()
            frames[id]?.let { return it.update(leash, w) }
            runCatching { frames[id] = TaskFrame(context, id, frame, leash, w) }
                .onFailure { Log.w(TAG, "task $id: can't put a bar in its layer", it) }
        }

        fun maximised(id: Int, on: Boolean) {
            frames[id]?.maximised(on)
        }

        fun release(id: Int) {
            if (Looper.myLooper() != Looper.getMainLooper()) {
                main.post { release(id) }
                return
            }
            frames.remove(id)?.release()
        }
    }
}
