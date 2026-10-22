package dev.omalauncher.system

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
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
 * One floating app window's frame, PowOS's own (OxygenOS draws none): a glass title bar above the window - its app's
 * icon and name, minimise and close - that a finger drags to move it, and a grip on its lower right corner that resizes
 * it. Two small overlay windows (TYPE_APPLICATION_OVERLAY: over apps, under the status bar and the shade) placed on the
 * task's bounds; the task follows the finger through [FreeformTasks.resize], at most one call in flight.
 * Design language (powos-design): the glass is the compositor's blur plus a dark tint, no borders, soft round buttons.
 */
@SuppressLint("ClickableViewAccessibility", "ViewConstructor")
class WindowFrame(
    private val context: Context,
    val id: Int,
    pkg: String?,
    private val onMinimise: (Int) -> Unit,
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

    private val bar = barView(pkg)
    private val grip = GripView(context)
    private val barParams = params("PowOS window bar $id")
    private val gripParams = params("PowOS window grip $id")
    private var added = false

    private val barBlur = WindowBlur({ bar.rootView }, BLUR_DP, cornersDp = floatArrayOf(CORNER_DP, CORNER_DP, 0f, 0f))
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
        val h = dp(BAR_DP)
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

    private fun barView(pkg: String?): LinearLayout {
        val label = appLabel(pkg)
        return LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12f), 0, dp(6f), 0)
            background =
                GradientDrawable().apply {
                    setColor(TINT)
                    val c = CORNER_DP * density
                    cornerRadii = floatArrayOf(c, c, c, c, 0f, 0f, 0f, 0f)
                }
            appIcon(pkg)?.let { icon ->
                addView(ImageView(context).apply { setImageDrawable(icon) }, LinearLayout.LayoutParams(dp(20f), dp(20f)).apply { marginEnd = dp(10f) })
            }
            addView(
                TextView(context).apply {
                    text = label
                    setTextColor(INK)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
            )
            addView(button(Glyph.MINIMISE) { onMinimise(id) }, LinearLayout.LayoutParams(dp(BUTTON_DP), dp(BUTTON_DP)).apply { marginEnd = dp(4f) })
            addView(button(Glyph.CLOSE) { Tasks.remove(context, id) }, LinearLayout.LayoutParams(dp(BUTTON_DP), dp(BUTTON_DP)))
        }
    }

    private fun button(
        glyph: Glyph,
        tap: () -> Unit,
    ): View =
        GlyphView(context, glyph).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(SOFT_FILL)
            }
            contentDescription = glyph.name.lowercase()
            setOnClickListener { tap() }
        }

    private enum class Glyph { MINIMISE, CLOSE }

    /** A button's mark, drawn (no icon files): a dash or a cross. */
    private class GlyphView(
        context: Context,
        private val glyph: Glyph,
    ) : View(context) {
        private val paint =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = INK
                strokeWidth = 1.6f * context.resources.displayMetrics.density
                strokeCap = Paint.Cap.ROUND
            }

        override fun onDraw(canvas: Canvas) {
            val cx = width / 2f
            val cy = height / 2f
            val s = width * 0.18f
            if (glyph == Glyph.MINIMISE) {
                canvas.drawLine(cx - s, cy, cx + s, cy, paint)
            } else {
                canvas.drawLine(cx - s, cy - s, cx + s, cy + s, paint)
                canvas.drawLine(cx - s, cy + s, cx + s, cy - s, paint)
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
        private val move: Boolean,
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
                    dragging = true
                    val target = if (move) moved(from, dx, dy) else resized(from, dx, dy)
                    layout(target)
                    resize(target)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) resize(Rect(bounds))
                    dragging = false
                }
            }
            return true
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
        const val BAR_DP = 40f
        private const val CORNER_DP = 14f
        private const val BUTTON_DP = 30f
        private const val GRIP_DP = 36f

        /** How far the grip reaches outside the window's corner. */
        private const val GRIP_OUT_DP = 12f
        private const val KEEP_DP = 96f
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
