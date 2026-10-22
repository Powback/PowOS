package dev.omalauncher.system

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import dev.omalauncher.shell.WindowBlur
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * One floating app window's frame, PowOS's own (OxygenOS draws none): a thin glass title bar above the window - its app's
 * icon and name, minimise, maximise and close - that a finger drags to move it, and a grip on its lower right corner that resizes
 * it. Two small overlay windows (TYPE_APPLICATION_OVERLAY: over apps, under the status bar and the shade) placed on the
 * task's bounds; the task follows the finger through [FreeformTasks.resize], at most one call in flight.
 * Design language (powos-design): the glass is the compositor's blur plus a dark tint, no borders, small marks. The bar
 * is [BAR_DP] (the user, 2026-10-23: half the old 40); its window reaches [HIT_DP] higher, unblurred and clear, so the
 * buttons and the drag keep a finger-sized target.
 */
@SuppressLint("ClickableViewAccessibility", "ViewConstructor")
class WindowFrame(
    private val context: Context,
    val id: Int,
    /** Its app: the bar's icon and name. */
    app: App,
    private val onMinimise: (Int) -> Unit,
    /** Let go at the screen's left (-1) or right (1) edge: the window goes to that home page (WindowFrames.edge). */
    private val onEdge: (Int, Int) -> Unit = { _, _ -> },
    /** The maximise button: over the windows' whole area, or back (WindowFrames.maximise). */
    private val onMaximise: (Int) -> Unit = {},
) {
    private val wm = context.getSystemService(WindowManager::class.java)
    private val density = context.resources.displayMetrics.density

    private fun dp(v: Float): Int = (v * density).toInt()

    /** Where the task is (screen px): the frame follows it, and the finger moves it. */
    var bounds = Rect()
        private set

    /** A finger is moving or resizing it: the task's own reports wait (they lag the finger). */
    var dragging = false
        private set

    private lateinit var maxButton: GlyphView
    private val bar = barView(app.pkg, app.title)
    private val grip = GripView(context)
    private val barParams = params("PowOS window bar $id")
    private val gripParams = params("PowOS window grip $id")
    private var added = false

    private val barBlur = WindowBlur({ bar.rootView }, BLUR_DP, cornersDp = floatArrayOf(CORNER_DP, CORNER_DP, 0f, 0f), topDp = HIT_DP)
    private val gripBlur = WindowBlur({ grip.rootView }, BLUR_DP, cornersDp = FloatArray(4) { GRIP_DP / 2 })

    init {
        bar.setOnTouchListener(Drag(move = true))
        grip.setOnTouchListener(Drag(move = false))
    }

    /** The task is at [r] now (its report): the frame there, unless a finger is moving it. */
    fun place(r: Rect) {
        if (dragging || (r == bounds && added)) return
        layout(r)
    }

    private fun layout(r: Rect) {
        bounds = Rect(r)
        val h = dp(BAR_DP + HIT_DP)
        barParams.apply {
            x = r.left
            y = r.top - h
            width = r.width()
            height = h
        }
        val g = dp(GRIP_DP)
        gripParams.apply {
            x = r.right - g + dp(GRIP_OUT_DP)
            y = r.bottom - g + dp(GRIP_OUT_DP)
            width = g
            height = g
        }
        if (!added) {
            runCatching {
                wm.addView(bar, barParams)
                wm.addView(grip, gripParams)
                added = true
                barBlur.set(1f)
                gripBlur.set(1f)
            }.onFailure { android.util.Log.w("PowosWindowFrame", "can't add the frame of task $id", it) }
        } else {
            runCatching {
                wm.updateViewLayout(bar, barParams)
                wm.updateViewLayout(grip, gripParams)
            }
        }
    }

    /** Maximised or not: its button shows "restore" (two squares) or "maximise" (one). */
    fun showMaximised(on: Boolean) {
        val glyph = if (on) Glyph.RESTORE else Glyph.MAXIMISE
        if (maxButton.glyph == glyph) return
        maxButton.glyph = glyph
        maxButton.contentDescription = glyph.name.lowercase()
        maxButton.invalidate()
    }

    fun remove() {
        if (!added) return
        added = false
        runCatching { wm.removeViewImmediate(bar) }
        runCatching { wm.removeViewImmediate(grip) }
    }

    private fun params(title: String) =
        WindowManager.LayoutParams(
            0,
            0,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            setTitle(title)
            fitInsetsTypes = 0
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }

    private fun appLabel(pkg: String?): String {
        val pm = context.packageManager
        return pkg?.let { runCatching { pm.getApplicationLabel(pm.getApplicationInfo(it, 0)).toString() }.getOrNull() } ?: pkg.orEmpty()
    }

    private fun appIcon(pkg: String?) = pkg?.let { p -> runCatching { context.packageManager.getApplicationIcon(p) }.getOrNull() }

    /**
     * The bar's window: the glass bar at its bottom ([BAR_DP]), a clear strip over it ([HIT_DP]); a touch in the strip
     * is the bar's - its button below the finger, else the drag (the buttons span the window's height).
     */
    private fun barView(
        pkg: String?,
        title: String?,
    ): LinearLayout {
        val label = title?.takeIf { it.isNotBlank() } ?: appLabel(pkg)
        return LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
            setPadding(dp(10f), 0, dp(2f), 0)
            background = BarGlass(dp(HIT_DP).toFloat(), CORNER_DP * density)
            val strip = dp(HIT_DP)
            appIcon(pkg)?.let { icon ->
                addView(
                    ImageView(context).apply { setImageDrawable(icon) },
                    LinearLayout.LayoutParams(dp(ICON_DP), dp(ICON_DP)).apply {
                        marginEnd = dp(8f)
                        bottomMargin = (dp(BAR_DP) - dp(ICON_DP)) / 2
                    },
                )
            }
            addView(
                TextView(context).apply {
                    text = label
                    setTextColor(INK)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                    typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                    gravity = Gravity.CENTER_VERTICAL
                },
                LinearLayout.LayoutParams(0, dp(BAR_DP), 1f),
            )
            val full = dp(BAR_DP) + strip
            addView(button(Glyph.MINIMISE) { onMinimise(id) }, LinearLayout.LayoutParams(dp(BUTTON_DP), full))
            maxButton = button(Glyph.MAXIMISE) { onMaximise(id) }
            addView(maxButton, LinearLayout.LayoutParams(dp(BUTTON_DP), full))
            addView(button(Glyph.CLOSE) { Tasks.remove(context, id) }, LinearLayout.LayoutParams(dp(BUTTON_DP), full))
        }
    }

    /** The bar's glass tint, below the window's clear touch strip ([top] px), its upper corners rounded. */
    private class BarGlass(
        private val top: Float,
        private val corner: Float,
    ) : android.graphics.drawable.Drawable() {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = TINT }
        private val path = android.graphics.Path()

        override fun draw(canvas: Canvas) {
            val b = bounds
            path.reset()
            path.addRoundRect(b.left.toFloat(), b.top + top, b.right.toFloat(), b.bottom.toFloat(), floatArrayOf(corner, corner, corner, corner, 0f, 0f, 0f, 0f), android.graphics.Path.Direction.CW)
            canvas.drawPath(path, paint)
        }

        override fun setAlpha(alpha: Int) {
            paint.alpha = alpha
        }

        override fun setColorFilter(filter: android.graphics.ColorFilter?) {
            paint.colorFilter = filter
        }

        @Deprecated("Deprecated in Java")
        override fun getOpacity() = PixelFormat.TRANSLUCENT
    }

    private fun button(
        glyph: Glyph,
        tap: () -> Unit,
    ): GlyphView =
        GlyphView(context, glyph, dp(HIT_DP).toFloat()).apply {
            contentDescription = glyph.name.lowercase()
            setOnClickListener { tap() }
        }

    /** A window's app: its package and, instead of the app's name, a PowOS (Linux) window's caption (its task is PowOS's own). */
    data class App(
        val pkg: String?,
        val title: String? = null,
    )

    private enum class Glyph { MINIMISE, MAXIMISE, RESTORE, CLOSE }

    /**
     * A button's mark, drawn (no icon files): a dash, a square, two squares or a cross, small, centred on the glass bar
     * below the clear strip ([strip] px) the button reaches up through; a soft disc behind it while pressed.
     */
    private class GlyphView(
        context: Context,
        var glyph: Glyph,
        private val strip: Float,
    ) : View(context) {
        private val d = context.resources.displayMetrics.density
        private val paint =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = INK
                strokeWidth = 1.3f * d
                strokeCap = Paint.Cap.ROUND
                style = Paint.Style.STROKE
            }
        private val pressedFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = SOFT_FILL }

        override fun drawableStateChanged() {
            super.drawableStateChanged()
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            val cx = width / 2f
            val cy = strip + (height - strip) / 2f
            if (isPressed) canvas.drawCircle(cx, cy, (height - strip) * 0.42f, pressedFill)
            val s = GLYPH_DP * d / 2f
            when (glyph) {
                Glyph.MINIMISE -> canvas.drawLine(cx - s, cy, cx + s, cy, paint)
                Glyph.MAXIMISE -> canvas.drawRect(cx - s, cy - s, cx + s, cy + s, paint)
                Glyph.RESTORE -> {
                    val o = s * 0.4f
                    canvas.drawRect(cx - s, cy - s + o, cx + s - o, cy + s, paint)
                    canvas.drawLine(cx - s + o, cy - s, cx + s, cy - s, paint)
                    canvas.drawLine(cx + s, cy - s, cx + s, cy + s - o, paint)
                }
                Glyph.CLOSE -> {
                    canvas.drawLine(cx - s, cy - s, cx + s, cy + s, paint)
                    canvas.drawLine(cx - s, cy + s, cx + s, cy - s, paint)
                }
            }
        }
    }

    /** The resize grip: a glass disc with two short diagonal strokes. */
    private class GripView(
        context: Context,
    ) : View(context) {
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = TINT }
        private val mark =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = INK
                strokeWidth = 1.6f * context.resources.displayMetrics.density
                strokeCap = Paint.Cap.ROUND
            }

        init {
            contentDescription = "resize"
        }

        override fun onDraw(canvas: Canvas) {
            val r = width / 2f
            canvas.drawCircle(r, r, r, fill)
            val a = r * 0.35f
            canvas.drawLine(r + a, r - a * 0.2f, r - a * 0.2f, r + a, mark)
            canvas.drawLine(r + a, r + a * 0.45f, r + a * 0.45f, r + a, mark)
        }
    }

    /** A finger on the bar (move) or the grip (resize): the frame follows at once, the task as fast as it can. */
    private inner class Drag(
        val move: Boolean,
    ) : View.OnTouchListener {
        private var x0 = 0f
        private var y0 = 0f
        private var from = Rect()
        private val slop = ViewConfiguration.get(context).scaledTouchSlop

        override fun onTouch(
            v: View,
            e: MotionEvent,
        ): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    x0 = e.rawX
                    y0 = e.rawY
                    from = Rect(bounds)
                    FreeformTasks.raise(context, id)
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - x0).toInt()
                    val dy = (e.rawY - y0).toInt()
                    if (!dragging && dx * dx + dy * dy < slop * slop) return true
                    if (!dragging) startDrag()
                    dragging = true
                    follow(if (move) moved(from, dx, dy) else resized(from, dx, dy), e)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> release(e)
            }
            return true
        }
    }

    /** The frame being dragged ([DragLayer]: drawn in this process every frame); null when no finger has it. */
    private var drag: DragLayer? = null

    /** Measured, the frame's windows moved per touch event as before (WindowManager relayouts): ns per event. */
    private val legacyLatencies = ArrayList<Long>()

    /**
     * HACK: the old way of following the finger, kept only to measure it against the drag layer (settings put global
     * powos_drag_legacy 1). Real fix: remove once the numbers are in the board task.
     */
    private fun legacyDrag() = android.provider.Settings.Global.getInt(context.contentResolver, "powos_drag_legacy", 0) == 1

    /** A drag starts: the frame's own windows step aside (drawn by the drag layer, no relayout per move). */
    private fun startDrag() {
        if (legacyDrag()) return
        val bitmapOf = { v: View -> runCatching { v.drawToBitmap() }.getOrNull() }
        drag = DragLayer(context, bitmapOf(bar), bitmapOf(grip), dp(BAR_DP + HIT_DP), dp(GRIP_DP) - dp(GRIP_OUT_DP), CORNER_DP * density)
        bar.alpha = 0f
        grip.alpha = 0f
        barBlur.set(0f)
        gripBlur.set(0f)
    }

    /** The frame and the task to [target]: the frame on the next frame, the task as fast as it can. */
    private fun follow(
        target: Rect,
        e: MotionEvent,
    ) {
        val eventNs = e.eventTime * 1_000_000
        bounds = Rect(target)
        val layer = drag
        if (layer != null) {
            layer.move(target, eventNs)
        } else {
            layout(target)
            bar.viewTreeObserver.registerFrameCommitCallback { legacyLatencies.add(System.nanoTime() - eventNs) }
        }
        resize(target)
    }

    /** The drag is over: the frame's windows at [r] (once), the drag layer gone. */
    private fun endDrag(r: Rect) {
        layout(r)
        val layer = drag
        if (layer == null) {
            DragLayer.report("PowosWindowDrag", "task $id legacy drag", legacyLatencies)
            legacyLatencies.clear()
            return
        }
        drag = null
        bar.alpha = 1f
        grip.alpha = 1f
        barBlur.set(1f)
        gripBlur.set(1f)
        // The windows are there once this frame is drawn; the layer goes after it (no frame without one or the other).
        bar.postOnAnimation { layer.hide("task $id drag") }
    }

    /** A bitmap of [this] view as it looks now (its size). */
    private fun View.drawToBitmap(): android.graphics.Bitmap {
        val b = android.graphics.Bitmap.createBitmap(maxOf(1, width), maxOf(1, height), android.graphics.Bitmap.Config.ARGB_8888)
        draw(Canvas(b))
        return b
    }

    /** The finger up: an edge drop sends the window to the next page, back whole on screen; else it stays put. */
    private fun Drag.release(e: MotionEvent) {
        val side = if (move && dragging && e.actionMasked == MotionEvent.ACTION_UP) edgeAt(e.rawX) else 0
        if (side != 0) {
            val (s, _) = screen()
            val left = bounds.left.coerceIn(s.left, maxOf(s.left, s.right - bounds.width()))
            val back = Rect(left, bounds.top, left + bounds.width(), bounds.bottom)
            endDrag(back)
            resize(back)
            onEdge(id, side)
        } else if (dragging) {
            endDrag(Rect(bounds))
            resize(Rect(bounds))
        }
        dragging = false
    }

    /** -1 at the screen's left edge, 1 at its right, else 0. */
    private fun edgeAt(x: Float): Int {
        val (s, _) = screen()
        val edge = dp(EDGE_DP)
        return when {
            x <= s.left + edge -> -1
            x >= s.right - edge -> 1
            else -> 0
        }
    }

    private fun screen(): Pair<Rect, Int> {
        val m = wm.maximumWindowMetrics
        val top = runCatching { wm.currentWindowMetrics.windowInsets.getInsets(WindowInsets.Type.statusBars()).top }.getOrDefault(0)
        return m.bounds to top
    }

    /** [from] moved by (dx, dy), its bar kept under the status bar and a hand's width of it on screen. */
    private fun moved(
        from: Rect,
        dx: Int,
        dy: Int,
    ): Rect {
        val (s, statusBar) = screen()
        val keep = dp(KEEP_DP)
        val left = (from.left + dx).coerceIn(s.left - from.width() + keep, s.right - keep)
        val top = (from.top + dy).coerceIn(s.top + statusBar + dp(BAR_DP), s.bottom - keep)
        return Rect(left, top, left + from.width(), top + from.height())
    }

    /** [from] with its lower right corner moved by (dx, dy): no smaller than a usable window, not past the screen. */
    private fun resized(
        from: Rect,
        dx: Int,
        dy: Int,
    ): Rect {
        val (s, _) = screen()
        val right = (from.right + dx).coerceIn(from.left + dp(MIN_W_DP), maxOf(from.left + dp(MIN_W_DP), s.right))
        val bottom = (from.bottom + dy).coerceIn(from.top + dp(MIN_H_DP), maxOf(from.top + dp(MIN_H_DP), s.bottom))
        return Rect(from.left, from.top, right, bottom)
    }

    /** The task to [r]: the newest target only, one call at a time, off the main thread. */
    private fun resize(r: Rect) {
        if (pending.getAndSet(r) == null) worker.execute { pending.getAndSet(null)?.let { FreeformTasks.resize(id, it) } }
    }

    private val pending = AtomicReference<Rect?>(null)

    companion object {
        /** The glass bar's height (the user, 2026-10-23: about half the 40 it was). */
        const val BAR_DP = 26f

        /** The bar window's clear touch strip above the glass: the buttons' and the drag's target reaches it too. */
        const val HIT_DP = 10f
        private const val CORNER_DP = 10f
        private const val BUTTON_DP = 34f
        private const val ICON_DP = 15f

        /** A button's mark, across. */
        private const val GLYPH_DP = 9f
        private const val GRIP_DP = 36f

        /** How far the grip reaches outside the window's corner. */
        private const val GRIP_OUT_DP = 12f
        private const val KEEP_DP = 96f

        /** How near the screen's side a let-go is an edge drop (the next page). */
        private const val EDGE_DP = 28f
        private const val MIN_W_DP = 280f
        private const val MIN_H_DP = 200f

        /** Home's glass: the compositor's blur (theme.css --glass-blur-native) under a dark tint (--glass-tint 42%). */
        private const val BLUR_DP = 140f
        private val TINT = Color.argb(107, 18, 20, 26)
        private val SOFT_FILL = Color.argb(26, 255, 255, 255)
        private val INK = Color.argb(222, 255, 255, 255)

        /** Every frame's task calls, one at a time (a move sends many; only the newest matters). */
        private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "powos-window-frames") }
    }
}
