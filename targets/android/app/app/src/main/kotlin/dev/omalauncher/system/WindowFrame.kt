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
import android.view.SurfaceControl
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
 * Design language (powos-design): the glass is the frost ([Frost], frost v2 as the shell's app pages: the compositor's
 * blur, a cool tint, a lit top edge), no borders, small marks. The bar is [BAR_DP] glass under a clear [HIT_DP] strip,
 * [BAR_DP] + [HIT_DP] in all (the user, 2026-10-23: half again); the strip and the buttons' full height keep it easy
 * to grab. A resize drag resizes the app's window as the finger goes ([FreeformTasks.Live]).
 * A window that draws its own title bar ([App.ownBar]: a Linux app with client-side decorations, Steam) gets no bar,
 * only the grip: its own bar moves it ([appMove], KWin's "move").
 */
@SuppressLint("ClickableViewAccessibility", "ViewConstructor")
class WindowFrame(
    private val context: Context,
    val id: Int,
    /** Its app: the bar's icon and name. */
    private val app: App,
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

    /**
     * A finger is on its bar or grip (from the DOWN to the lift), dragging or not yet: its windows are never re-added
     * or removed meanwhile ([raise], WindowFrames.refresh) - that ends the touch stream, so the drag never starts (the
     * user, 2026-10-24: title bars couldn't be dragged; a restack 80 ms after the DOWN, before the finger passed the
     * touch slop, re-added the bar under it).
     */
    var held = false
        private set

    private lateinit var maxButton: GlyphView
    private val frost = Frost.colors(context)
    /** The bar's buttons and what each does, for [Drag]'s hit test (filled by [barView], so declared before it). */
    private val buttons = mutableListOf<Pair<GlyphView, () -> Unit>>()
    private val bar = barView(app.pkg, app.title)
    private val grip = GripView(context, frost)
    private val barParams = params("PowOS window bar $id")
    private val gripParams = params("PowOS window grip $id")

    init {
        dev.omalauncher.shell.HighRefresh.ask(barParams, context.display, dev.omalauncher.shell.HighRefresh.wanted)
    }
    // Tracked separately, not as one `added` flag: addViews can add one view and fail on the other (WM throws, the
    // overlay op resets mid-add) - a retry must only add what's still missing, never re-add an already-attached view
    // (a second addView on it throws "View ... has already been added", which silently ate the retry: a bar that
    // failed once never got another try, 2026-10-24 - "no title bar to close it by" after a dock minimise/restore).
    private var barAdded = false
    private var gripAdded = false
    private val added: Boolean get() = gripAdded && (app.ownBar || barAdded)

    private val barBlur = WindowBlur({ bar.rootView }, Frost.BLUR_DP, cornersDp = floatArrayOf(CORNER_DP, CORNER_DP, 0f, 0f), topDp = HIT_DP)
    private val gripBlur = WindowBlur({ grip.rootView }, Frost.BLUR_DP, cornersDp = FloatArray(4) { GRIP_DP / 2 })

    init {
        bar.setOnTouchListener(Drag(move = true))
        grip.setOnTouchListener(Drag(move = false))
    }

    /** The window draws its own title bar ([App.ownBar]): no bar of ours, only the grip. */
    val ownBar: Boolean get() = app.ownBar

    /** Our bar's height above the window (px): none for a window with its own. */
    private fun barHeight(): Int = if (app.ownBar) 0 else dp(BAR_DP + HIT_DP)

    /** The frame's view that is always shown (the bar, or the grip of a window with its own bar). */
    private val anchor: View get() = if (app.ownBar) grip else bar

    /** The drag a window's own title bar started (KWin's "move": [appMove]), fed the rest of that touch. */
    private val appDrag = Drag(move = true, buttons = false)
    private var appMoving = false

    /**
     * The window's own title bar is being dragged (PowosWindowActivity got KWin's "move"): [e] and the rest of that
     * touch move the window as a drag of our bar would (the first event is the drag's start). False: no frame shows.
     */
    fun appMove(e: MotionEvent): Boolean {
        if (!added) return false
        if (!appMoving) {
            appMoving = true
            val down = MotionEvent.obtain(e).apply { action = MotionEvent.ACTION_DOWN }
            appDrag.onTouch(anchor, down)
            down.recycle()
            android.util.Log.i("PowosWindowFrame", "task $id moved by its own title bar")
        }
        appDrag.onTouch(anchor, e)
        if (e.actionMasked == MotionEvent.ACTION_UP || e.actionMasked == MotionEvent.ACTION_CANCEL) appMoving = false
        return true
    }

    /**
     * The task is at [r] now (its report): the frame there, unless a finger is moving it. [free]: the screen x span of
     * its bar row no window above covers (WindowFrames.barSpan) - the bar takes only that, so a window under another
     * keeps the visible part of its title bar (and its buttons) instead of losing it, and never floats over the window
     * above (overlays are over every task). Null: the whole width.
     */
    fun place(
        r: Rect,
        free: IntRange? = null,
    ) {
        if (dragging || (r == bounds && free == span && added)) return
        layout(r, free)
    }

    /** The bar's x span (screen px) when only part of its row shows ([place]); null: the window's whole width. */
    private var span: IntRange? = null

    private fun layout(
        r: Rect,
        free: IntRange? = null,
    ) {
        bounds = Rect(r)
        span = free
        val h = barHeight()
        barParams.apply {
            x = (free?.first ?: r.left) + slideDx
            y = r.top - h
            width = free?.let { it.last - it.first } ?: r.width()
            // Over SystemUI's caption too: its 1 px row at the task's top is an input window that drags the task
            // (OemCaption); under the bar no touch reaches it.
            height = h + OemCaption.CAPTION_PX
        }
        val g = dp(GRIP_DP)
        gripParams.apply {
            x = r.right - g + dp(GRIP_OUT_DP) + slideDx
            y = r.bottom - g + dp(GRIP_OUT_DP)
            width = g
            height = g
        }
        if (!added) addViews() else updateViews()
    }

    /** The frame's windows added (the bar only for a window without its own): each independently, so one failing
     * (WindowFrames.frameRefused asks for a retry) never blocks the other, and a retry never re-adds one that's
     * already up. */
    private fun addViews() {
        var ok = true
        if (!app.ownBar && !barAdded) {
            runCatching { wm.addView(bar, barParams); barAdded = true; barBlur.set(if (veiled) 0f else 1f) }
                .onFailure { ok = false; android.util.Log.w("PowosWindowFrame", "can't add the bar of task $id", it) }
        }
        if (!gripAdded) {
            runCatching {
                wm.addView(grip, gripParams); gripAdded = true
                // The grip shows only while a finger is on it (the user, 2026-10-23: no disc floating over other windows).
                grip.alpha = 0f
            }.onFailure { ok = false; android.util.Log.w("PowosWindowFrame", "can't add the grip of task $id", it) }
        }
        if (ok) {
            logAdded()
        } else {
            // Refused (the overlay app op reset, or a transient WM error): granted again, and a retry regardless.
            WindowFrames.current?.frameRefused()
        }
    }

    /** What the device check reads: the bar's size and its frost as drawn (or that the window has its own bar). */
    private fun logAdded() {
        if (app.ownBar) {
            android.util.Log.i("PowosWindowFrame", "task $id: its own title bar, no bar (grip only)")
            return
        }
        android.util.Log.i(
            "PowosWindowFrame",
            "task $id bar ${barParams.height} px (${BAR_DP + HIT_DP} dp, glass $BAR_DP) frost blur ${Frost.BLUR_DP} dp fill=#%08x veil=#%08x sheen=#%08x edge=#%08x ink=#%08x"
                .format(frost.fill, frost.veil, frost.sheen, frost.edge, frost.ink),
        )
    }

    private fun updateViews() {
        runCatching {
            if (!app.ownBar) wm.updateViewLayout(bar, barParams)
            wm.updateViewLayout(grip, gripParams)
        }
    }

    /** The close button: the task removed, and said so (E2E round 2: a tap left Calculator and Dolphin open, unlogged). */
    private fun close() {
        val ok = Tasks.remove(context, id)
        android.util.Log.i("PowosWindowFrame", "close task $id (${app.pkg}): ${if (ok) "removed" else "NOT removed"}")
        WindowFrames.current?.changed()
    }

    /** Its window over the windows' whole area, or back: the maximise button and the bar's double tap, one path. */
    private fun maximise() = onMaximise(id)

    /** Its window off the screen, into the dock (the minimise button). */
    private fun minimise() = onMinimise(id)

    /** Maximised or not: its button shows "restore" (two squares) or "maximise" (one). */
    fun showMaximised(on: Boolean) {
        val glyph = if (on) Glyph.RESTORE else Glyph.MAXIMISE
        if (maxButton.glyph == glyph) return
        maxButton.glyph = glyph
        maxButton.contentDescription = glyph.name.lowercase()
        maxButton.invalidate()
    }

    /**
     * The bar's window asks for display mode [id] (0: none), as home's page does while touched (HighRefresh): over the
     * app's window, its ask is the top-most one, which WM takes - the app's own (ColorOS's 60 Hz) capped home's swipes.
     */
    fun preferMode(id: Int) {
        val p = if (app.ownBar) gripParams else barParams
        if (p.preferredDisplayModeId == id) return
        dev.omalauncher.shell.HighRefresh.ask(p, context.display, id)
        if (added) runCatching { wm.updateViewLayout(anchor, p) }
    }

    /** Its bar's and grip's views while shown (shell/PanelLift stacks their surfaces under home under a home panel; PageSlide moves them with a page swipe). */
    val panelViews: List<android.view.View> get() = if (!added) emptyList() else if (app.ownBar) listOf(grip) else listOf(bar, grip)

    /** A page swipe's offset of its bar and grip (screen px, along x): their layout x = the window's live place + it. */
    private var slideDx = 0

    /** The bar and grip [dx] px along x from the window's place, through WM (WindowFrames.slideMove); 0 is at rest. */
    fun slideTo(dx: Int) {
        if (dx == slideDx) return
        barParams.x += dx - slideDx
        gripParams.x += dx - slideDx
        slideDx = dx
        if (added) updateViews()
    }

    /**
     * HACK: a page slide hides the bar (overlay windows can't track a task's leash per frame: WM applies their layout
     * a frame late, the bar trailed by up to 183 px, job 20261024-213609-68435) - faded out at the slide's start,
     * faded back in at its final place when it ends. Real fix: title bars inside the task's own layer (board task
     * floating-window-title-bars-z-ordered-with-their). The grip is clear at rest (shown only under a finger).
     */
    fun slideHide() {
        if (app.ownBar || !barAdded) return
        bar.animate().cancel()
        bar.animate().alpha(0f).setDuration(SLIDE_FADE_OUT_MS).withEndAction { if (barAdded) barBlur.set(0f) }.start()
    }

    /** The slide ended: the bar (already at its window's final place, [layout]) fades back in; blur first, behind a clear bar. */
    fun slideShow() {
        veiled = false
        if (app.ownBar || !barAdded) return
        bar.animate().cancel()
        barBlur.set(1f)
        bar.animate().alpha(1f).setDuration(SLIDE_FADE_IN_MS).start()
    }

    /**
     * Made for a page swipe's arriving window (WindowFrames.slideStart): its bar drawn clear and unblurred until its
     * surface is where the slide has the window - its first frame lands at the real bounds, on the page still showing.
     */
    var veiled = false
        set(v) {
            if (field == v) return
            field = v
            if (app.ownBar) return
            bar.animate().cancel()
            bar.alpha = if (v) 0f else 1f
            if (barAdded) barBlur.set(if (v) 0f else 1f)
        }
    /** Where its bar and grip take touches (screen px): a frame stacked over another's there takes that one's finger. */
    fun reach(): Rect = Rect(bounds.left, bounds.top - barHeight(), bounds.right + dp(GRIP_OUT_DP), bounds.bottom + dp(GRIP_OUT_DP))

    /**
     * Its two windows re-added, so they stack over PowOS's other overlays: overlays keep the order they were added in,
     * not their tasks' (WindowFrames.restack). Never while a finger is on it (its touch stream would end).
     */
    fun raise() {
        if (!added || dragging || held) return
        runCatching {
            if (!app.ownBar) {
                wm.removeViewImmediate(bar)
                wm.addView(bar, barParams)
            }
            wm.removeViewImmediate(grip)
            wm.addView(grip, gripParams)
            if (!app.ownBar) barBlur.set(if (veiled) 0f else 1f)
        }.onFailure { android.util.Log.w("PowosWindowFrame", "can't raise the frame of task $id", it) }
    }

    fun remove() {
        // A gesture under way ends with the frame: its drag layer (the bar drawn where the finger had it) never outlives
        // the frame - left over, it was a title bar with no window under it (the 01:47 "Home - Dolphin" bar).
        abandonGesture()
        if (!barAdded && !gripAdded) return
        if (barAdded) { barAdded = false; runCatching { wm.removeViewImmediate(bar) } }
        if (gripAdded) { gripAdded = false; runCatching { wm.removeViewImmediate(grip) } }
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
            background = BarGlass(dp(HIT_DP).toFloat(), CORNER_DP * density, frost)
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
                    setTextColor(frost.ink)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
                    typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                    gravity = Gravity.CENTER_VERTICAL
                },
                LinearLayout.LayoutParams(0, dp(BAR_DP), 1f),
            )
            val full = dp(BAR_DP) + strip
            // Never `id` in here: inside this apply it is the LinearLayout's View id (NO_ID, -1), not the task's - the
            // button maximised task -1, which WindowFrames.maximise dropped without a line (2026-10-24, window-max calc).
            addView(button(Glyph.MINIMISE, ::minimise), LinearLayout.LayoutParams(dp(BUTTON_DP), full))
            maxButton = button(Glyph.MAXIMISE, ::maximise)
            addView(maxButton, LinearLayout.LayoutParams(dp(BUTTON_DP), full))
            addView(button(Glyph.CLOSE, ::close), LinearLayout.LayoutParams(dp(BUTTON_DP), full))
        }
    }

    /** The bar's frost below the window's clear touch strip ([top] px), its upper corners rounded: veil, tint, sheen, lit edge. */
    private class BarGlass(
        private val top: Float,
        private val corner: Float,
        private val frost: Frost.Colors,
    ) : android.graphics.drawable.Drawable() {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val path = android.graphics.Path()

        override fun draw(canvas: Canvas) {
            val b = bounds
            val t = b.top + top
            path.reset()
            path.addRoundRect(b.left.toFloat(), t, b.right.toFloat(), b.bottom.toFloat(), floatArrayOf(corner, corner, corner, corner, 0f, 0f, 0f, 0f), android.graphics.Path.Direction.CW)
            canvas.save()
            canvas.clipPath(path)
            frostLayers(canvas, paint, frost, android.graphics.RectF(b.left.toFloat(), t, b.right.toFloat(), b.bottom.toFloat()))
            canvas.restore()
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

    /**
     * A button: a mark the bar's own touch handler ([Drag]) hit-tests and acts on at the lift, not a clickable view.
     * Measured 2026-10-23 (window-max calc/kate, float-windows, 6 runs): a tap on a clickable button never reached its
     * click listener (no "maximised" line at all), while taps on the bar itself (its double tap) always reached [Drag];
     * every bar touch has one owner now.
     */
    private fun button(
        glyph: Glyph,
        tap: () -> Unit,
    ): GlyphView =
        GlyphView(context, glyph, dp(HIT_DP).toFloat(), frost.ink).apply {
            contentDescription = glyph.name.lowercase()
            buttons.add(this to tap)
        }

    /** The button under bar point ([x], [y]) (the bar view's px), if any. */
    private fun buttonAt(
        x: Float,
        y: Float,
    ): Pair<GlyphView, () -> Unit>? = buttons.firstOrNull { (v, _) -> x >= v.left && x < v.right && y >= v.top && y < v.bottom }

    /** A window's app: its package and, instead of the app's name, a PowOS (Linux) window's caption (its task is PowOS's own). */
    data class App(
        val pkg: String?,
        val title: String? = null,
        /** The window draws its own title bar (KWin's "decor 0": client-side decorations): no bar of ours. */
        val ownBar: Boolean = false,
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
        ink: Int,
    ) : View(context) {
        private val d = context.resources.displayMetrics.density
        private val paint =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = ink
                strokeWidth = 1.3f * d
                strokeCap = Paint.Cap.ROUND
                style = Paint.Style.STROKE
            }
        private val pressedFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = (ink and 0xFFFFFF) or (26 shl 24) }

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

    /** The resize grip: a frost disc with two short diagonal strokes. */
    private class GripView(
        context: Context,
        private val frost: Frost.Colors,
    ) : View(context) {
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        private val disc = android.graphics.Path()
        private val mark =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = frost.ink
                strokeWidth = 1.6f * context.resources.displayMetrics.density
                strokeCap = Paint.Cap.ROUND
            }

        init {
            contentDescription = "resize"
        }

        override fun onDraw(canvas: Canvas) {
            val r = width / 2f
            disc.reset()
            disc.addCircle(r, r, r, android.graphics.Path.Direction.CW)
            canvas.save()
            canvas.clipPath(disc)
            frostLayers(canvas, fill, frost, android.graphics.RectF(0f, 0f, width.toFloat(), height.toFloat()))
            canvas.restore()
            val a = r * 0.35f
            canvas.drawLine(r + a, r - a * 0.2f, r - a * 0.2f, r + a, mark)
            canvas.drawLine(r + a, r + a * 0.45f, r + a * 0.45f, r + a, mark)
        }
    }

    /** A finger on the bar (move) or the grip (resize): the frame follows at once, the task as fast as it can. */
    private inner class Drag(
        val move: Boolean,
        /** Its bar's buttons take a tap (not for a drag the window's own bar started: [appMove]). */
        val buttons: Boolean = true,
    ) : View.OnTouchListener {
        private var x0 = 0f
        private var y0 = 0f
        private var from = Rect()
        private val slop = ViewConfiguration.get(context).scaledTouchSlop

        override fun onTouch(
            v: View,
            e: MotionEvent,
        ): Boolean {
            if (e.actionMasked == MotionEvent.ACTION_DOWN) {
                // A new finger: whatever an earlier stream left (a press whose lift never came) is over.
                pressed?.first?.isPressed = false
                pressed = null
                held = true
            }
            if (pressed != null) return pressing(e)
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> down(e)
                MotionEvent.ACTION_MOVE -> moveTo(e)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    release(e)
                    if (!move) showGrip(false)
                    let()
                }
            }
            return true
        }

        /** The finger is off the frame: a restack that waited for it runs now (WindowFrames.touchEnded). */
        private fun let() {
            held = false
            WindowFrames.current?.touchEnded()
        }

        /** The button a finger went down on: it acts at the lift if the finger is still on it; no drag from a button. */
        private var pressed: Pair<GlyphView, () -> Unit>? = null

        /**
         * A finger that went down on a button: a tap (lifted within the touch slop, on it) presses it; past the slop it
         * is a drag of the window like anywhere else on the bar (tap vs drag by slop, as desktop title bars do).
         */
        private fun pressing(e: MotionEvent): Boolean {
            val (v, tap) = pressed ?: return true
            val on = e.x >= v.left && e.x < v.right && e.y >= v.top && e.y < v.bottom
            when (e.actionMasked) {
                MotionEvent.ACTION_MOVE -> pressMoved(v, on, e)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    pressed = null
                    val act = on && e.actionMasked == MotionEvent.ACTION_UP
                    android.util.Log.i("PowosWindowFrame", "task $id ${v.contentDescription}: ${if (act) "tapped" else "let go off it"}")
                    raise = false
                    let()
                    if (act) tap()
                }
            }
            return true
        }

        /** The finger on button [v] moved: still a press within the touch slop ([on] it or not), past it a move. */
        private fun pressMoved(
            v: GlyphView,
            on: Boolean,
            e: MotionEvent,
        ) {
            val dx = e.rawX - x0
            val dy = e.rawY - y0
            if (dx * dx + dy * dy < slop * slop) {
                v.isPressed = on
                return
            }
            v.isPressed = false
            pressed = null
            android.util.Log.i("PowosWindowFrame", "task $id ${v.contentDescription}: dragged off it, a move")
            moveTo(e)
        }

        private fun down(e: MotionEvent) {
            x0 = e.rawX
            y0 = e.rawY
            from = Rect(bounds)
            if (move && buttons) {
                buttonAt(e.x, e.y)?.let {
                    pressed = it
                    it.first.isPressed = true
                    // Raised if it turns into a drag (the drag's change), like any bar drag.
                    raise = WindowFrames.current?.isFront(id) == false
                    return
                }
            }
            // Raised with the gesture's own change (a drag's transition, or at a tap's lift), never at the DOWN: a
            // moveTaskToFront is a transition of its own, still collecting when the drag's change starts a few ms later.
            raise = WindowFrames.current?.isFront(id) == false
            if (!move) showGrip(true)
        }

        private fun moveTo(e: MotionEvent) {
            val dx = (e.rawX - x0).toInt()
            val dy = (e.rawY - y0).toInt()
            if (!dragging && dx * dx + dy * dy < slop * slop) return
            val target = if (move) moved(from, dx, dy) else resized(from, dx, dy)
            if (!dragging) startDrag(resizing = !move, target)
            dragging = true
            follow(target, e)
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

    /** The grip's disc and frost on (a finger on it) or off. */
    private fun showGrip(on: Boolean) {
        grip.alpha = if (on) 1f else 0f
        gripBlur.set(if (on) 1f else 0f)
    }

    /** A move (not a resize) is under way: the task moves once, when the finger lifts ([settle]). */
    private var moving = false

    /**
     * A drag starts (its first [target]): the app's content goes under PowOS's hand ([TaskLeash]: moved and cropped with
     * the frame every frame), the task's bounds go live for a resize ([FreeformTasks.Live]); the frame's own windows
     * step aside (drawn by the drag layer, no relayout per move).
     */
    private fun startDrag(
        resizing: Boolean,
        target: Rect,
    ) {
        moving = !resizing
        worker.execute { live = FreeformTasks.Live(context, id, resizing) }
        // Moves and resizes both through the leash. Without it a resize leaves the task's surface crop at the OLD size
        // (WM Shell syncs the leash only in a transition on this ROM): resize-probe 2026-10-23 20:26, Calculator made
        // bigger - its input window cropped to the old width, the new part blank and its touches going to home.
        leash = if (TaskLeash.enabled(context)) startLeash(resizing, target, raise) else null
        if (leash == null && raise) FreeformTasks.raise(context, id)
        raise = false
        if (legacyDrag()) return
        val layer = dragLayer(resizing)
        drag = layer
        // The frame's windows step aside once the layer draws them (a new window's first frame takes 2-3 frames: hidden
        // at once, the bar blinked out at every drag's start), their blur after their own hidden frame (a blur region
        // goes at once, a view's alpha with its next frame: a sharp bar for a frame).
        layer.onShown = { if (drag === layer) stepAside(layer) }
    }

    /** The layer that draws the frame where the finger has it: our bar (none for a window with its own), the grip resizing. */
    private fun dragLayer(resizing: Boolean): DragLayer {
        val bitmapOf = { v: View -> runCatching { v.drawToBitmap() }.getOrNull() }
        val barPicture = if (app.ownBar) null else bitmapOf(bar)
        return DragLayer(context, barPicture, if (resizing) bitmapOf(grip) else null, barHeight(), dp(GRIP_DP) - dp(GRIP_OUT_DP), CORNER_DP * density)
    }

    /** The frame's own windows hidden while [layer] draws them: alpha now, their blur after that frame. */
    private fun stepAside(layer: DragLayer) {
        bar.alpha = 0f
        grip.alpha = 0f
        anchor.viewTreeObserver.registerFrameCommitCallback {
            if (drag === layer) {
                barBlur.set(0f)
                gripBlur.set(0f)
            }
        }
        anchor.invalidate()
    }

    /** The app's content under PowOS's hand from the drag's first [target] on; null where it can't be. */
    private fun startLeash(
        resizing: Boolean,
        target: Rect,
        raise: Boolean,
    ): TaskLeash.Session? {
        val s = TaskLeash.Session(context, listOf(id), "task $id ${if (resizing) "resize" else "move"}${if (raise) " (raised)" else ""}")
        s.onReady = { ok -> if (ok) drag?.outline = false }
        val started =
            s.start { wct, token ->
                val tok = token(id) ?: error("no token for task $id")
                if (raise) TaskLeash.reorder(wct, tok, true)
                TaskLeash.setBounds(wct, tok, target)
                if (resizing) TaskLeash.setDragResizing(wct, tok, true)
            }
        return s.takeIf { started }
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
        // The app's content with the frame, on the drag layer's next frame (one compositor transaction for both).
        val s = leash
        if (s != null) {
            val t = SurfaceControl.Transaction()
            if (s.frame(t, id, target)) {
                val root = layer?.rootSurfaceControl
                if (root != null) root.applyTransactionOnDraw(t) else t.apply()
            }
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
        leaving = layer
        // Whatever happens to the bar meanwhile (removed, not drawn: an edge drop to another page, a minimise), the layer
        // goes: a layer left behind is a title bar with no window under it.
        main.postDelayed({ leave(layer, "task $id drag (bar not drawn in ${LEAVE_MS} ms)") }, LEAVE_MS)
        // The bar shows again only once WM has its window at [r]: shown (and its blur region sent) at once, it flashed
        // for a frame or two at the place the drag began - the region moves with the window, which moves when WM
        // relays it out. Then the layer goes, after the bar's frame there (no frame without one or the other).
        whenPlaced(r, 0) {
            // Another drag began meanwhile (its own layer has the frame), or the frame is gone.
            if (drag != null || !added) {
                leave(layer, "task $id drag")
                return@whenPlaced
            }
            if (!app.ownBar) {
                bar.alpha = 1f
                barBlur.set(1f)
            }
            anchor.viewTreeObserver.registerFrameCommitCallback { anchor.postOnAnimation { leave(layer, "task $id drag") } }
            anchor.invalidate()
        }
    }

    /** A drag's layer that ended, until the bar is drawn back at its place ([endDrag]); hidden with the frame. */
    private var leaving: DragLayer? = null

    /** [layer] gone (once). */
    private fun leave(
        layer: DragLayer,
        what: String,
    ) {
        if (leaving !== layer) return
        leaving = null
        layer.hide(what)
    }

    /**
     * The frame goes while a finger has it, or a drag's layer is still up: the layer hidden, the drag ended where the
     * finger had it (its content's transition finished), nothing left on the screen without its window.
     */
    private fun abandonGesture() {
        held = false
        leaving?.let { leave(it, "task $id drag (frame removed)") }
        val layer = drag
        drag = null
        layer?.hide("task $id drag (frame removed)")
        if (!dragging) return
        dragging = false
        settle(Rect(bounds))
        android.util.Log.i("PowosWindowFrame", "task $id: frame removed mid-drag, the drag ended at ${bounds.toShortString()}")
    }

    /** Whether WM has the bar's window over window bounds [r]. */
    private fun barAt(r: Rect): Boolean {
        val at = IntArray(2)
        anchor.getLocationOnScreen(at)
        if (app.ownBar) return at[0] == r.right - dp(GRIP_DP) + dp(GRIP_OUT_DP) && at[1] == r.bottom - dp(GRIP_DP) + dp(GRIP_OUT_DP)
        return at[0] == r.left && at[1] == r.top - barHeight()
    }

    /** [then] once the bar's window is at [r] (WM relaid it out), or after [PLACE_FRAMES] frames whatever it says. */
    private fun whenPlaced(
        r: Rect,
        frames: Int,
        then: () -> Unit,
    ) {
        val done = barAt(r) || frames >= PLACE_FRAMES || !added
        if (!done) {
            anchor.postOnAnimation { whenPlaced(r, frames + 1, then) }
            return
        }
        if (frames > 0) android.util.Log.i("PowosWindowDrag", "task $id: bar placed after $frames frame(s)" + if (frames >= PLACE_FRAMES) " (gave up waiting)" else "")
        then()
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
            settle(back)
            onEdge(id, side)
        } else if (dragging) {
            endDrag(Rect(bounds))
            settle(Rect(bounds))
        } else if (e.actionMasked == MotionEvent.ACTION_UP) {
            if (raise) FreeformTasks.raise(context, id)
            if (move) barTapped(e)
        }
        raise = false
        dragging = false
    }

    /** The finger's window wasn't the top-most one: it comes up with this gesture ([startDrag], or at the lift). */
    private var raise = false

    /** The bar's last tap (uptime ms): a second one soon after is a double tap - maximise, or back (the desktop way). */
    private var lastBarTap = 0L

    private fun barTapped(e: MotionEvent) {
        if (e.eventTime - lastBarTap <= ViewConfiguration.getDoubleTapTimeout()) {
            lastBarTap = 0L
            maximise()
        } else {
            lastBarTap = e.eventTime
        }
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

    /**
     * [from] moved by (dx, dy), its whole bar window (glass + touch strip) kept under the status bar - the status bar's
     * window is above every overlay, so a bar reaching into it lost its touches there - and a hand's width on screen
     * sideways. Down, its bottom stops at home's bottom bar (AppWindows.area, as opening, maximise and resize do): home
     * is in the task area under every window, so a window moved down over the dock took the dock's taps (2026-10-24).
     * A window already lower (placed before the bar was known) keeps its top as the limit, so it never jumps.
     */
    private fun moved(
        from: Rect,
        dx: Int,
        dy: Int,
    ): Rect {
        val (s, statusBar) = screen()
        val keep = dp(KEEP_DP)
        val left = (from.left + dx).coerceIn(s.left - from.width() + keep, s.right - keep)
        val highest = s.top + statusBar + barHeight()
        val floor = AppWindows.area(context).bottom.coerceAtMost(s.bottom)
        val lowest = maxOf(highest, minOf(s.bottom - keep, maxOf(floor - from.height(), from.top)))
        val top = (from.top + dy).coerceIn(highest, lowest)
        return Rect(left, top, left + from.width(), top + from.height())
    }

    /** [from] with its lower right corner moved by (dx, dy): no smaller than a usable window, not past the screen. */
    private fun resized(
        from: Rect,
        dx: Int,
        dy: Int,
    ): Rect {
        val (s, _) = screen()
        // Not down over home's bottom bar (AppWindows.area, as maximise): a corner dragged down ran under the dock
        // (2026-10-23). A window already lower keeps its bottom as the limit.
        val floor = maxOf(AppWindows.area(context).bottom.coerceAtMost(s.bottom), from.bottom)
        val right = (from.right + dx).coerceIn(from.left + dp(MIN_W_DP), maxOf(from.left + dp(MIN_W_DP), s.right))
        val bottom = (from.bottom + dy).coerceIn(from.top + dp(MIN_H_DP), maxOf(from.top + dp(MIN_H_DP), floor))
        return Rect(from.left, from.top, right, bottom)
    }

    /** The task to [r]: the newest target only, one call at a time, off the main thread; live while a finger has it. */
    private fun resize(r: Rect) {
        // A move goes to WM once, at the end, as a transition (FreeformTasks.Live.end): bounds set in WM on the way
        // left the app's content - and its touches - where the window had been (e2e r3: bar at 887, content at 556),
        // and the last of them would leave the end nothing to change.
        if (moving) return
        if (pending.getAndSet(r) == null) {
            worker.execute {
                val to = pending.getAndSet(null) ?: return@execute
                val l = live
                if (l == null) {
                    FreeformTasks.resize(id, to)
                    return@execute
                }
                val t0 = System.nanoTime()
                l.to(to)
                liveNs.add(System.nanoTime() - t0)
                liveSizes.add(to.width() to to.height())
            }
        }
    }

    /**
     * The finger lifted, the task at [r]: its last bounds, drag-resizing off, the drag's numbers logged. With the content
     * under PowOS's hand ([TaskLeash]) its transition ends with them - after the live resize calls already queued; if
     * it never got the content, the old way ([FreeformTasks.Live.end]).
     */
    private fun settle(r: Rect) {
        pending.set(null)
        val resizing = !moving
        moving = false
        val s = leash
        leash = null
        if (s == null || !s.pending) {
            settleTask(r)
            return
        }
        settleLive(s, r, resizing)
    }

    /** The drag's end through its content's transition ([TaskLeash.Session.finish]). */
    private fun settleLive(
        s: TaskLeash.Session,
        r: Rect,
        resizing: Boolean,
    ) {
        // The leashes still coming: ended the moment they come (true), or the old way if they never do.
        s.onReady = { ok -> if (ok) dropLive() else settleTask(r) }
        // After the live resize calls already queued on the worker: the end's bounds are the last WM gets.
        worker.execute {
            logLive(r)
            main.post { finishLive(s, r, resizing) }
        }
    }

    /** The content's transition ends at [r] (main thread). */
    private fun finishLive(
        s: TaskLeash.Session,
        r: Rect,
        resizing: Boolean,
    ) {
        val wasLive = s.live
        s.finish(mapOf(id to r)) { wct, token -> endBounds(wct, token(id), r, resizing) }
        if (wasLive) dropLive()
    }

    private fun endBounds(
        wct: Any,
        tok: Any?,
        r: Rect,
        resizing: Boolean,
    ) {
        tok ?: return
        TaskLeash.setBounds(wct, tok, r)
        if (resizing) TaskLeash.setDragResizing(wct, tok, false)
    }

    /** The content's transition took the end: no live bounds left, home's window list read again. */
    private fun dropLive() {
        worker.execute { live = null }
        WindowFrames.current?.changed()
    }

    /** The task to [r] the old way (no content under PowOS's hand). */
    private fun settleTask(r: Rect) {
        worker.execute {
            val l = live
            // The listed windows (home's windows.list, its gestures' no-go boxes) again: a bounds change of ours fires
            // no task-stack event, so the list kept the bounds from the launch (E2E 2026-10-23: a page swipe beside a
            // moved window was refused inside where it had been).
            if (l == null) {
                FreeformTasks.resize(id, r)
                WindowFrames.current?.changed()
                return@execute
            }
            l.end(r)
            live = null
            WindowFrames.current?.changed()
            logLive(r)
        }
    }

    /** The drag's live bounds calls, one line (worker thread). */
    private fun logLive(r: Rect) {
        run {
            if (liveNs.isNotEmpty()) {
                val ms = liveNs.map { it / 1_000_000.0 }.sorted()
                val (w0, h0) = liveSizes.first()
                android.util.Log.i(
                    "PowosWindowResize",
                    "task $id: ${ms.size} live bounds on the way (${liveSizes.distinct().size} sizes) ${w0}x$h0 -> ${r.width()}x${r.height()}, call median %.1f ms, max %.1f ms".format(ms[ms.size / 2], ms.last()),
                )
            }
            liveNs.clear()
            liveSizes.clear()
        }
    }

    private val pending = AtomicReference<Rect?>(null)

    /** The drag's live bounds (worker thread only). */
    private var live: FreeformTasks.Live? = null

    /** The drag's app content under PowOS's hand (main thread); null: the content waits for the lift. */
    private var leash: TaskLeash.Session? = null
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val liveNs = ArrayList<Long>()
    private val liveSizes = ArrayList<Pair<Int, Int>>()

    companion object {
        private const val SLIDE_FADE_OUT_MS = 80L
        private const val SLIDE_FADE_IN_MS = 120L

        /** The glass bar's height (the user, 2026-10-23: about half the 26 + 10 it was; 26 dp in all with [HIT_DP]). */
        const val BAR_DP = 18f

        /** The bar window's clear touch strip above the glass: the buttons' and the drag's target reaches it too. */
        const val HIT_DP = 8f
        private const val CORNER_DP = 10f
        private const val BUTTON_DP = 34f
        private const val ICON_DP = 12f

        /** A button's mark, across. */
        private const val GLYPH_DP = 8f
        private const val GRIP_DP = 28f

        /** The most frames a drag's end waits for WM to have the bar's window where the finger left it. */
        private const val PLACE_FRAMES = 12

        /** How far the grip reaches outside the window's corner: none, it sits inside (the user, 2026-10-23). */
        private const val GRIP_OUT_DP = 0f
        private const val KEEP_DP = 96f

        /** How near the screen's side a let-go is an edge drop (the next page). */
        private const val EDGE_DP = 28f

        /** At most this long after a drag's lift its layer stays up waiting for the bar to be drawn in place (ms). */
        private const val LEAVE_MS = 500L
        private const val MIN_W_DP = 280f
        private const val MIN_H_DP = 200f

        /**
         * The frost's layers in [box] (the caller clips the shape), as shell.css paints a frost surface: the veil,
         * the tint, a sheen from the top to clear at 45%, a 1 px lit edge along the top (--lift-edge).
         */
        private fun frostLayers(
            canvas: Canvas,
            paint: Paint,
            frost: Frost.Colors,
            box: android.graphics.RectF,
        ) {
            paint.shader = null
            paint.color = frost.veil
            canvas.drawRect(box, paint)
            paint.color = frost.fill
            canvas.drawRect(box, paint)
            paint.shader = android.graphics.LinearGradient(0f, box.top, 0f, box.top + box.height() * 0.45f, frost.sheen, Color.TRANSPARENT, android.graphics.Shader.TileMode.CLAMP)
            canvas.drawRect(box, paint)
            paint.shader = null
            paint.color = frost.edge
            canvas.drawRect(box.left, box.top, box.right, box.top + 1f, paint)
        }

        /** Every frame's task calls, one at a time (a move sends many; only the newest matters). */
        private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "powos-window-frames") }
    }
}
