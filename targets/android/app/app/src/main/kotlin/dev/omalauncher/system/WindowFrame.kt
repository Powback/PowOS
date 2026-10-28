package dev.omalauncher.system

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.PixelFormat
import android.graphics.Rect
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceControl
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import dev.omalauncher.shell.WindowBlur
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * One floating app window's frame, PowOS's own (OxygenOS draws none): a thin glass title bar above the window - its app's
 * icon and name, minimise, maximise and close - that a finger drags to move it, and a grip on its lower right corner that resizes
 * it. Two small overlay windows (TYPE_APPLICATION_OVERLAY: over apps, under the status bar and the shade) placed on the
 * task's bounds; the task follows the finger through [FreeformTasks.resize], at most one call in flight.
 * Visible chrome is shell/ui/chrome.tsx (shared web UI), using frost v2 as the shell's app pages: the compositor's
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
    val app: App,
    private val onMinimise: (Int) -> Unit,
    /** Let go at the screen's left (-1) or right (1) edge: the window goes to that home page (WindowFrames.edge). */
    private val onEdge: (Int, Int) -> Unit = { _, _ -> },
    /** The bar's double tap: over the windows' whole area, or back (WindowFrames.maximise). */
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

    /** Its app as its bar names it (the app's label when the window has no title). */
    val barApp get() = app.copy(title = app.title?.takeIf { it.isNotBlank() } ?: appLabel(app.pkg))
    private val barChrome = FrameChrome(context, "window", barApp) { barAction(it) }

    /** A title-bar button's action (this frame's bar, or its in-task bar: [TaskFrame]). */
    fun barAction(action: String) {
        when (action) { "minimise" -> minimise(); "maximise" -> fullScreen(); "close" -> close() }
    }
    private val gripChrome = FrameChrome(context, "grip", App(null)) {}
    private val bar = barChrome.web
    private val grip = gripChrome.web
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
    private val added: Boolean get() = gripAdded && (noBar || barAdded)

    private val barBlur = WindowBlur({ bar.rootView }, Frost.BLUR_DP, cornersDp = floatArrayOf(CORNER_DP, CORNER_DP, 0f, 0f), topDp = HIT_DP)
    private val gripBlur = WindowBlur({ grip.rootView }, Frost.BLUR_DP, cornersDp = FloatArray(4) { GRIP_DP / 2 })

    init {
        bar.setOnTouchListener(Drag(move = true))
        grip.setOnTouchListener(Drag(move = false))
    }

    /** The window draws its own title bar ([App.ownBar]): no bar of ours, only the grip. */
    val ownBar: Boolean get() = app.ownBar

    /** Its title bar is in the task's own layer ([TaskFrame], set by it): no overlay bar, as for [ownBar]. */
    private var inTaskBar = false

    /** No overlay bar of ours: the window draws its own ([ownBar]) or has its in-task bar ([inTaskBar]); grip only. */
    private val noBar: Boolean get() = app.ownBar || inTaskBar

    /**
     * [TaskFrame] put this window's bar in its task's layer ([on]) or dropped it: the overlay bar goes, or comes back
     * (a window never has no bar: a task with no leash yet, or a failed attach, keeps the overlay one). Main thread.
     */
    fun taskBar(on: Boolean) {
        // A removal skipped under a finger (its touch would end) is retried on the next call (TaskFrame.sync on layout).
        // Only a real change re-lays out: layout() calls TaskFrame.sync, which calls this again - a removal still
        // waiting for the finger once recursed here until the app died (StackOverflowError, emulator 2026-10-28).
        val changed = on != inTaskBar
        val drop = on && barAdded && !dragging && !held
        if (!changed && !drop) return
        inTaskBar = on
        if (drop) {
            barAdded = false
            bar.animate().cancel()
            runCatching { wm.removeViewImmediate(bar) }
        }
        android.util.Log.i("PowosWindowFrame", "task $id: " + if (!on) "overlay bar back" else if (drop) "bar in its task, overlay bar removed" else "bar in its task, overlay bar goes at the lift")
        // Shown: re-laid out (the bar's height above the window comes and goes with it), the overlay bar re-added if back.
        if (gripAdded) layout(bounds, span)
    }

    /** Our bar's height above the window (px): none for a window with its own. */
    private fun barHeight(): Int = if (noBar) 0 else dp(BAR_DP + HIT_DP)

    /** The frame's view that is always shown (the bar, or the grip of a window with its own bar). */
    private val anchor: View get() = if (noBar) grip else bar

    /** The drag of the in-task bar ([TaskFrame]): its buttons hit-tested by that bar's own chrome ([barTouch]). */
    private var taskBarHit: (Float, Float) -> Pair<FrameChrome.Button, () -> Unit>? = { _, _ -> null }
    private val taskBarDrag = Drag(move = true, hit = { x, y -> taskBarHit(x, y) })

    /**
     * A touch on this window's in-task bar ([TaskFrame], the task's own layer): the same drag as this frame's bar - a
     * button by [hit] (that bar's DOM rects), past the slop a move through the TaskLeash session, a double tap
     * WindowFrames.maximise ([barTapped]). [e] in that bar's coordinates.
     */
    fun barTouch(
        e: MotionEvent,
        hit: (Float, Float) -> Pair<FrameChrome.Button, () -> Unit>?,
    ): Boolean {
        taskBarHit = hit
        return taskBarDrag.onTouch(anchor, e)
    }

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
        TaskFrame.sync(context, id)
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
        bar.onResume()
        grip.onResume()
        var ok = true
        if (!noBar && !barAdded) {
            runCatching { wm.addView(bar, barParams); barAdded = true; barBlur.set(blurLevel()) }
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
        if (noBar) {
            android.util.Log.i("PowosWindowFrame", "task $id: its own title bar, no bar (grip only)")
            return
        }
        android.util.Log.i("PowosWindowFrame", "task $id web bar ${barParams.height} px (${BAR_DP + HIT_DP} dp), compositor blur ${Frost.BLUR_DP} dp")
    }

    private fun updateViews() {
        runCatching {
            if (!noBar) wm.updateViewLayout(bar, barParams)
            wm.updateViewLayout(grip, gripParams)
        }
    }

    /** The close button: the task removed, and said so (E2E round 2: a tap left Calculator and Dolphin open, unlogged). */
    private fun close() {
        val ok = Tasks.remove(context, id)
        android.util.Log.i("PowosWindowFrame", "close task $id (${app.pkg}): ${if (ok) "removed" else "NOT removed"}")
        WindowFrames.current?.changed()
    }

    /** Its window over the windows' whole area, or back: the bar's double tap (the maximise button: [onFullScreen]). */
    private fun maximise() = onMaximise(id)

    /** The maximise button: the app full screen, as opened on the phone (WindowFrames.fullScreen), as close reaches it. */
    private fun fullScreen() {
        WindowFrames.current?.fullScreen(id) ?: maximise()
    }

    /** Its window off the screen, into the dock (the minimise button). */
    private fun minimise() = onMinimise(id)

    /** Maximised or not: its button shows "restore" (two squares) or "maximise" (one). */
    fun showMaximised(on: Boolean) {
        barChrome.maximised(on)
        TaskFrame.maximised(id, on)
    }

    /**
     * The bar's window asks for display mode [id] (0: none), as home's page does while touched (HighRefresh): over the
     * app's window, its ask is the top-most one, which WM takes - the app's own (ColorOS's 60 Hz) capped home's swipes.
     */
    fun preferMode(id: Int) {
        val p = if (noBar) gripParams else barParams
        if (p.preferredDisplayModeId == id) return
        dev.omalauncher.shell.HighRefresh.ask(p, context.display, id)
        if (added) runCatching { wm.updateViewLayout(anchor, p) }
    }

    /** Its bar's and grip's views while shown (shell/PanelLift stacks their surfaces under home under a home panel; PageSlide moves them with a page swipe). */
    val panelViews: List<android.view.View> get() = if (!added) emptyList() else if (noBar) listOf(grip) else listOf(bar, grip)

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

    /** The page swipe's offset put on its bar's and grip's own surfaces ([slideSurface]); 0 at rest. */
    private var surfaceDx = Float.NaN

    /**
     * The bar and grip [dx] px along x by their window surfaces, in [t] - the transaction that moves the window's leash
     * (PageSlide.draw), so they move with the page in the same frame, not a frame or more later through WM's layout.
     * False when their surfaces can't be had (not drawn yet, a WM-moved slide already going): then [slideTo].
     * HACK: ViewRootImpl.getSurfaceControl is hidden (GlassBlur.surfaceOf). Real fix: bars inside the task's own layer.
     */
    fun slideSurface(
        t: android.view.SurfaceControl.Transaction,
        dx: Float,
    ): Boolean {
        if (slideDx != 0) return false
        val views = panelViews
        val surfaces = views.mapNotNull { dev.omalauncher.shell.GlassBlur.surfaceOf(it) }
        if (views.isEmpty() || surfaces.size != views.size) return false
        surfaces.forEach { t.setPosition(it, dx, 0f) }
        surfaceDx = dx
        return true
    }

    /** The slide's surface offset ([slideSurface]) back to 0, at once: the bar is at its window's place again. */
    fun slideSurfaceRest() {
        if (surfaceDx.isNaN()) return
        surfaceDx = Float.NaN
        val t = android.view.SurfaceControl.Transaction()
        panelViews.mapNotNull { dev.omalauncher.shell.GlassBlur.surfaceOf(it) }.forEach { t.setPosition(it, 0f, 0f) }
        t.apply()
    }

    /**
     * HACK: a page slide hides the bar (overlay windows can't track a task's leash per frame: WM applies their layout
     * a frame late, the bar trailed by up to 183 px, job 20261024-213609-68435) - faded out at the slide's start,
     * faded back in at its final place when it ends. Real fix: title bars inside the task's own layer (board task
     * floating-window-title-bars-z-ordered-with-their). The grip is clear at rest (shown only under a finger).
     */
    fun slideHide() {
        slideHidden = true
        if (noBar) return
        if (!barAdded) { bar.animate().cancel(); bar.alpha = 0f; wmAlpha(0f); return }
        bar.animate().cancel()
        bar.animate().alpha(0f).setDuration(SLIDE_FADE_OUT_MS).withEndAction {
            if (barAdded) barBlur.set(0f)
            // The view is clear: now the windows themselves, so WM stops drawing them and SurfaceFlinger drops the layers.
            if (slideHidden) wmAlpha(0f)
        }.start()
    }

    /** The bar and grip overlay windows' own alpha (LayoutParams.alpha): 0 = the compositor has nothing to draw for them. */
    private fun wmAlpha(a: Float) {
        if (noBar) return
        if (barParams.alpha == a && gripParams.alpha == a) return
        barParams.alpha = a
        gripParams.alpha = a
        if (added) updateViews()
    }

    /** The slide ended: the bar (already at its window's final place, [layout]) fades back in; blur first, behind a clear bar. */
    fun slideShow() {
        veiled = false
        slideHidden = false
        if (noBar || !barAdded) { bar.alpha = 1f; wmAlpha(1f); return }
        bar.animate().cancel()
        wmAlpha(1f) // at the final place first (the view is still clear), then fade the view in
        barBlur.set(1f)
        bar.animate().alpha(1f).setDuration(SLIDE_FADE_IN_MS).start()
    }

    /**
     * Made for a page swipe's arriving window (WindowFrames.slideStart): its bar drawn clear and unblurred until its
     * surface is where the slide has the window - its first frame lands at the real bounds, on the page still showing.
     */
    /** Hidden for a page slide ([slideHide]) until [slideShow]: nothing else (a late add, a raise) un-hides it. */
    private var slideHidden = false

    private fun blurLevel() = if (veiled || slideHidden) 0f else 1f

    var veiled = false
        set(v) {
            if (field == v) return
            field = v
            if (noBar) return
            bar.animate().cancel()
            val hide = v || slideHidden
            bar.alpha = if (hide) 0f else 1f
            if (barAdded) barBlur.set(if (hide) 0f else 1f)
        }
    /** The grip's square on the screen (px): what a window above may cover. */
    fun gripRect(): Rect {
        val g = dp(GRIP_DP)
        return Rect(bounds.right - g + dp(GRIP_OUT_DP), bounds.bottom - g + dp(GRIP_OUT_DP), bounds.right + dp(GRIP_OUT_DP), bounds.bottom + dp(GRIP_OUT_DP))
    }

    private var gripUnder = false

    /**
     * A window above this one covers its grip: the grip (an overlay, over every task) takes no touch there, so a
     * resize never starts through the window above - the grip's share of "bars z-ordered with their window"
     * (the bar's is [place]'s span). HACK: overlays can't sit between tasks; real fix: the bar and grip in the task's own
     * layer (TaskFrame, flag powos_bar_in_task), once the probe has run on the phone.
     */
    fun gripCovered(on: Boolean) {
        if (on == gripUnder) return
        gripUnder = on
        val f = WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        gripParams.flags = if (on) gripParams.flags or f else gripParams.flags and f.inv()
        if (gripAdded && !dragging) runCatching { wm.updateViewLayout(grip, gripParams) }
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
            if (!noBar) {
                wm.removeViewImmediate(bar)
                wm.addView(bar, barParams)
            }
            wm.removeViewImmediate(grip)
            wm.addView(grip, gripParams)
            if (!noBar) barBlur.set(blurLevel())
        }.onFailure { android.util.Log.w("PowosWindowFrame", "can't raise the frame of task $id", it) }
    }

    /** Leave the screen without rebuilding two WebViews when this desktop returns. */
    fun detach() {
        // A gesture under way ends with the frame: its drag layer (the bar drawn where the finger had it) never outlives
        // the frame - left over, it was a title bar with no window under it (the 01:47 "Home - Dolphin" bar).
        abandonGesture()
        if (barAdded) { barAdded = false; runCatching { wm.removeViewImmediate(bar) } }
        if (gripAdded) { gripAdded = false; runCatching { wm.removeViewImmediate(grip) } }
        bar.animate().cancel()
        grip.animate().cancel()
        bar.onPause()
        grip.onPause()
        slideTo(0)
    }

    fun remove() {
        detach()
        // After detach: released first, its taskBar(false) would re-add the overlay bar of a frame that is going.
        TaskFrame.release(id)
        barChrome.destroy()
        gripChrome.destroy()
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

    /** Hit rectangles come from the web layout in CSS px, converted by FrameChrome. */
    private fun buttonAt(x: Float, y: Float) = barChrome.buttonAt(x, y)

    /** A window's app: its package and, instead of the app's name, a PowOS (Linux) window's caption (its task is PowOS's own). */
    data class App(
        val pkg: String?,
        val title: String? = null,
        /** The window draws its own title bar (KWin's "decor 0": client-side decorations): no bar of ours. */
        val ownBar: Boolean = false,
    )

    /** A finger on the bar (move) or the grip (resize): the frame follows at once, the task as fast as it can. */
    private inner class Drag(
        val move: Boolean,
        /** Its bar's buttons take a tap (not for a drag the window's own bar started: [appMove]). */
        val buttons: Boolean = true,
        /** The button under a point: this frame's bar by default, the in-task bar's own for [barTouch]. */
        val hit: (Float, Float) -> Pair<FrameChrome.Button, () -> Unit>? = { x, y -> buttonAt(x, y) },
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
            // The in-task bar came up under this finger (a drag of the overlay bar started its TaskLeash session):
            // the overlay bar's removal waited for the lift; now, after this event's dispatch (one bar, not two).
            if (inTaskBar && barAdded) bar.post { taskBar(true) }
        }

        /** The button a finger went down on: it acts at the lift if the finger is still on it; no drag from a button. */
        private var pressed: Pair<FrameChrome.Button, () -> Unit>? = null

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
            v: FrameChrome.Button,
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
                hit(e.x, e.y)?.let {
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
        val barPicture = if (noBar) null else bitmapOf(bar)
        return DragLayer(context, barPicture, if (resizing) bitmapOf(grip) else null, barHeight(), dp(GRIP_DP) - dp(GRIP_OUT_DP), CORNER_DP * density).apply { controlsWidth = barChrome.controlsWidth }
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
        // Its app's place on this screen (WindowPlaces), where its next window opens.
        WindowFrames.current?.placed(id, r)
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
            if (!noBar && !slideHidden) {
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
        if (noBar) return at[0] == r.right - dp(GRIP_DP) + dp(GRIP_OUT_DP) && at[1] == r.bottom - dp(GRIP_DP) + dp(GRIP_OUT_DP)
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

        /** A button's mark, across. */
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

        /** Every frame's task calls, one at a time (a move sends many; only the newest matters). */
        private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "powos-window-frames") }
    }
}
