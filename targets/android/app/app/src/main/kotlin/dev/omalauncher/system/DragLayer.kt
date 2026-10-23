package dev.omalauncher.system

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/**
 * A floating window's frame while a finger moves or resizes it ([WindowFrame]): one screen-sized overlay that draws
 * the frame where the finger has it - the bar and the grip as they look, an outline of the window - redrawn in this
 * process every frame, no window manager call per move (moving the frame's own windows was two relayouts per touch
 * event: it lagged the finger). The app's window catches up behind it (FreeformTasks.resize, the newest target only);
 * at the finger's lift the frame's windows go there once and this goes away.
 *
 * Measured per drag (logcat PowosWindowDrag): touch event -> the frame showing it handed to the compositor.
 */
@SuppressLint("ViewConstructor")
internal class DragLayer(
    private val context: Context,
    private val bar: Bitmap?,
    private val grip: Bitmap?,
    /** The bar's window above the window's top (its glass and touch strip), px. */
    private val barHeight: Int,
    /** The grip's offset from the window's lower right corner to its own upper left, px. */
    private val gripOffset: Int,
    private val corner: Float,
) : View(context) {
    private val wm = context.getSystemService(WindowManager::class.java)
    private val density = context.resources.displayMetrics.density
    private var target = Rect()
    private var added = false

    /**
     * The window's outline drawn (the content isn't following: where it will go). Off once the app's own content moves
     * with the frame ([TaskLeash]): no ghost of it.
     */
    var outline = true
        set(v) {
            field = v
            invalidate()
        }
    private val outlinePaint =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1.5f * density
            color = Color.argb(150, 255, 255, 255)
        }
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG)

    /**
     * Called once, on the main thread, when the layer's first frame is on its way to the screen: only then may the
     * frame's own windows step aside (hidden at once, the bar blinked out for the 2-3 frames a new window takes).
     */
    var onShown: (() -> Unit)? = null
    private var shownSaid = false

    /** The newest touch event's time not drawn yet (System.nanoTime's clock), 0 if none. */
    private var pendingEventNs = 0L
    private val latencies = ArrayList<Long>()

    /** The frame at window bounds [r], for the touch event at [eventNs] (uptime ns): drawn on the next frame. */
    fun move(
        r: Rect,
        eventNs: Long,
    ) {
        if (!added) show()
        target = Rect(r)
        if (pendingEventNs == 0L) pendingEventNs = eventNs
        invalidate()
    }

    private fun show() {
        val p =
            WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                setTitle("PowOS window drag")
                fitInsetsTypes = 0
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            }
        runCatching {
            wm.addView(this, p)
            added = true
        }.onFailure { Log.w(TAG, "no drag layer", it) }
    }

    override fun onDraw(canvas: Canvas) {
        val r = target
        if (outline) canvas.drawRoundRect(RectF(r), corner, corner, outlinePaint)
        bar?.let { canvas.drawBitmap(it, r.left.toFloat(), (r.top - barHeight).toFloat(), bitmapPaint) }
        grip?.let { canvas.drawBitmap(it, (r.right - gripOffset).toFloat(), (r.bottom - gripOffset).toFloat(), bitmapPaint) }
        val ev = pendingEventNs
        pendingEventNs = 0L
        val first = !shownSaid
        shownSaid = true
        if (ev != 0L || first) {
            viewTreeObserver.registerFrameCommitCallback {
                if (ev != 0L) latencies.add(System.nanoTime() - ev)
                if (first) post { onShown?.invoke() }
            }
        }
    }

    /** The finger lifted: gone, and the drag's latencies logged. */
    fun hide(what: String) {
        if (added) runCatching { wm.removeViewImmediate(this) }
        added = false
        report(TAG, what, latencies)
        latencies.clear()
    }

    companion object {
        private const val TAG = "PowosWindowDrag"

        /** One line per drag: how long a touch event took to be on a frame (handed to the compositor). */
        fun report(
            tag: String,
            what: String,
            ns: List<Long>,
        ) {
            if (ns.isEmpty()) return
            val ms = ns.map { it / 1_000_000.0 }.sorted()
            Log.i(tag, "$what: ${ms.size} frames, touch->frame median %.1f ms, p90 %.1f ms, max %.1f ms".format(ms[ms.size / 2], ms[ms.size * 9 / 10], ms.last()))
        }
    }
}
