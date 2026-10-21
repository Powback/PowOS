package dev.omalauncher.system.gesture

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.media.AudioManager
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import com.android.systemui.shared.recents.ISystemUiProxy
import dev.omalauncher.shell.PowosLockActivity
import dev.omalauncher.system.QuickToolsHost
import dev.omalauncher.system.ShadeHost
import dev.omalauncher.system.Switcher
import dev.omalauncher.system.Tasks
import java.io.File

/**
 * Edge gestures, as Good Lock's One Hand Operation+ has them: thin handles on the left and right edges (by default the
 * lower half of the right one), where a swipe in - short or held, straight or diagonally up or down
 * ([EdgeGestureClassifier]) - does what the settings say ([EdgeConfig], shell/ui/edge.tsx): Quick Tools by the thumb
 * ([QuickToolsHost]), Back, Home, the switcher, the shade, the assistant, an app...
 *
 * - On PowOS's gesture input ([GestureMonitor]), not a window: a finger down on a handle is taken at once
 *   ([GestureConsumer.takesOnDown]: the app and SystemUI's edge-back gesture under it get a cancel), so SystemUI's back
 *   never races it there; everywhere else - above the handle, the bottom strip ([NavGesture]), the status bar (the
 *   shade's pull) - nothing changes. Back inside a handle is the handle's own action (straight in, by default).
 * - Not on the lock screen, while a shade (PowOS's or SystemUI's) or Quick Tools are open, with the keyboard up (its
 *   keys run to the edges), nor while the device dozes.
 * - The handles are drawn by a strip window each side (never touchable): a faint line where the gestures are.
 *
 * HACK: ISystemUiProxy.onBackEvent(null) is SystemUI's (LauncherProxyService: with no event it sends Back down and up,
 * checking the caller is the bound recents provider). Real fix: none for an app without INJECT_EVENTS - Quickstep's
 * taskbar back button calls the same.
 */
class EdgeGestures(
    private val service: Context,
) : GestureConsumer {
    var systemUi: ISystemUiProxy? = null

    /** SystemUI's QuickStepContract.SYSUI_STATE_* flags: the handles hide on the lock screen. */
    var systemUiState = 0L
        set(value) {
            val was = locked()
            field = value
            if (locked() != was) handles()
        }

    private val main = Handler(Looper.getMainLooper())
    private val display: Display = service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    private val displayContext = service.createDisplayContext(display)
    private val handleContext = displayContext.createWindowContext(TYPE_HANDLE, null)
    private val wm = handleContext.getSystemService(WindowManager::class.java)
    private val density get() = displayContext.resources.displayMetrics.density

    private val file = File(service.filesDir, "shell-data/edgeGestures.json")
    private var config = EdgeConfig()
    private var configStamp = -1L

    private var classifier: EdgeGestureClassifier? = null
    private var right = false
    private var side: EdgeConfig.Side? = null
    private var lastY = 0f

    /** Quick Tools is following this swipe in. */
    private var dragging = false

    override val takesOnDown = true

    private val leftHandle = Handle(false)
    private val rightHandle = Handle(true)

    /** The settings page wrote the file: the handles follow at once. */
    private val observer =
        object : FileObserver(file.parentFile!!.apply { mkdirs() }, CLOSE_WRITE or MOVED_TO or DELETE) {
            override fun onEvent(
                event: Int,
                path: String?,
            ) {
                if (path == file.name) main.post { handles() }
            }
        }

    fun start() {
        observer.startWatching()
        handles()
    }

    fun stop() {
        observer.stopWatching()
        leftHandle.remove()
        rightHandle.remove()
        endDrag(open = false)
    }

    /** The display changed (rotation, folding): the handles are laid out again. */
    fun refresh() = handles()

    private fun config(): EdgeConfig {
        val stamp = if (file.isFile) file.lastModified() else 0L
        if (stamp != configStamp) {
            configStamp = stamp
            config = EdgeConfig.parse(runCatching { file.takeIf { it.isFile }?.readText() }.getOrNull())
        }
        return config
    }

    private fun screen(): Rect = runCatching { displayContext.getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds }.getOrElse { Rect(0, 0, 1080, 2400) }

    /** The handle's span on [s] (screen px, top to bottom): above the bottom strip, whose swipes are home's. */
    private fun span(
        s: EdgeConfig.Side,
        screen: Rect,
    ): Pair<Float, Float> {
        val h = screen.height().toFloat()
        val bottomLimit = screen.bottom - navStrip() - 8f * density
        val top = screen.top + s.top * h
        val bottom = (screen.top + s.bottom * h).coerceAtMost(bottomLimit)
        return top to bottom
    }

    @SuppressLint("DiscouragedApi", "InternalInsetResource")
    private fun navStrip(): Int {
        val res = service.resources
        return listOf("navigation_bar_frame_height", "navigation_bar_height", "navigation_bar_gesture_height")
            .firstNotNullOfOrNull { name -> res.getIdentifier(name, "dimen", "android").takeIf { it != 0 }?.let(res::getDimensionPixelSize)?.takeIf { it > 0 } }
            ?: (48 * density).toInt()
    }

    private fun locked(): Boolean {
        val s = systemUiState
        if (s and (SYSUI_KEYGUARD_SHOWING or SYSUI_BOUNCER_SHOWING or SYSUI_DEVICE_DOZING) != 0L) return true
        return s and SYSUI_KEYGUARD_OCCLUDED != 0L && PowosLockActivity.current != null
    }

    private fun blocked(): String? {
        val s = systemUiState
        return when {
            locked() -> "locked"
            s and (SYSUI_NOTIFICATION_PANEL_EXPANDED or SYSUI_QUICK_SETTINGS_VISIBLE) != 0L -> "SystemUI's shade is open"
            s and SYSUI_IME_VISIBLE != 0L -> "the keyboard is up"
            ShadeHost.current?.isShown == true -> "PowOS's shade is open"
            QuickToolsHost.current?.shown == true -> "Quick Tools are open"
            else -> null
        }
    }

    override fun onDown(e: MotionEvent): Boolean {
        val c = config()
        if (!c.on) return false
        val screen = screen()
        val x = e.rawX
        val y = e.rawY
        val r: Boolean
        val s: EdgeConfig.Side
        when {
            c.right.on && x >= screen.right - c.right.width * density -> {
                r = true
                s = c.right
            }
            c.left.on && x < screen.left + c.left.width * density -> {
                r = false
                s = c.left
            }
            else -> return false
        }
        val (top, bottom) = span(s, screen)
        if (y < top || y > bottom) return false
        blocked()?.let {
            Log.i(TAG, "not now: $it")
            return false
        }
        right = r
        side = s
        lastY = y
        dragging = false
        classifier = EdgeGestureClassifier(r, density, c.triggerDp() * density).also { it.down(x, y, e.eventTime) }
        Log.i(TAG, "edge: down on the ${if (r) "right" else "left"} handle at ${y.toInt()}")
        return true
    }

    override fun onEvent(e: MotionEvent): GestureConsumer.Verdict {
        val c = classifier ?: return GestureConsumer.Verdict.DROP
        val s = side ?: return GestureConsumer.Verdict.DROP
        when (e.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                lastY = e.rawY
                val decided = c.move(e.rawX, e.rawY, e.eventTime)
                if (decided != null) {
                    tick(EFFECT_TICK)
                    Log.i(TAG, "edge: $decided")
                    main.removeCallbacks(holdCheck)
                    main.postDelayed(holdCheck, HOLD_POLL_MS)
                    if (s.action("short.${decided.key}") == QUICK_TOOLS) dragging = true
                }
                if (dragging) QuickToolsHost.current?.drag(right, lastY, quickToolsQ(c))
                return GestureConsumer.Verdict.TAKE
            }
            MotionEvent.ACTION_UP -> {
                finish()
                val g = c.up(e.rawX, e.rawY, e.eventTime)
                val action = g?.let { s.action(it.key) } ?: "none"
                Log.i(TAG, "edge: ${g?.key ?: "nothing"} -> $action")
                if (action == QUICK_TOOLS) {
                    if (dragging) QuickToolsHost.current?.settle(true) else QuickToolsHost.current?.openAt(right, lastY)
                    dragging = false
                } else {
                    endDrag(open = false)
                    run(action)
                }
                return GestureConsumer.Verdict.DROP
            }
            MotionEvent.ACTION_CANCEL -> {
                finish()
                endDrag(open = false)
                return GestureConsumer.Verdict.DROP
            }
        }
        return GestureConsumer.Verdict.TAKE
    }

    private fun finish() {
        classifier = null
        main.removeCallbacks(holdCheck)
    }

    /** Held still once decided: long. Quick Tools following the finger goes back if the long swipe is something else. */
    private val holdCheck =
        object : Runnable {
            override fun run() {
                val c = classifier ?: return
                if (c.hold(SystemClock.uptimeMillis())) {
                    tick(EFFECT_CLICK)
                    val d = c.direction ?: return
                    val longAction = side?.action("long.${d.key}")
                    Log.i(TAG, "edge: held -> long.${d.key} ($longAction)")
                    if (dragging && longAction != QUICK_TOOLS) endDrag(open = false)
                    return
                }
                if (!c.long) main.postDelayed(this, HOLD_POLL_MS)
            }
        }

    private fun endDrag(open: Boolean) {
        if (!dragging) return
        dragging = false
        QuickToolsHost.current?.settle(open)
    }

    /** How far in Quick Tools is (0..1): it comes in over [QT_TRAVEL_DP] past the decision. */
    private fun quickToolsQ(c: EdgeGestureClassifier) = ((c.inward - config.triggerDp() * density * 0.5f) / (QT_TRAVEL_DP * density)).coerceIn(0.05f, 1f)

    private fun tick(effect: Int) {
        runCatching { service.getSystemService(Vibrator::class.java)?.vibrate(VibrationEffect.createPredefined(effect)) }
    }

    // --- the actions

    private fun run(action: String) {
        runCatching {
            when {
                action == "none" -> {}
                action == "back" -> back()
                action == "home" -> home()
                action == "recents" -> {
                    Switcher.show(service)
                    runCatching { systemUi?.onOverviewShown(false) }
                }
                action == "notifications" -> shade(control = false)
                action == "control" -> shade(control = true)
                action == "assistant" -> assistant()
                action == "drawer" -> drawer()
                action == "previous" -> previous()
                action == "playpause" -> playPause()
                action == QUICK_TOOLS -> QuickToolsHost.current?.openAt(right, lastY)
                action.startsWith("app:") -> launch(action.removePrefix("app:"))
                else -> Log.w(TAG, "unknown action $action")
            }
        }.onFailure { Log.w(TAG, "edge action $action failed", it) }
    }

    /** Back, as SystemUI's back button sends it (the HACK in the class comment). */
    private fun back() {
        val sysui = systemUi
        if (sysui == null) {
            Log.w(TAG, "no back: SystemUI isn't connected")
            return
        }
        sysui.onBackEvent(null)
    }

    private fun home() {
        service.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED))
    }

    /** PowOS's shade (its control center or notifications); SystemUI's own where PowOS's isn't up. */
    private fun shade(control: Boolean) {
        if (ShadeHost.current?.openPanel(control) == true) return
        runCatching { systemUi?.expandNotificationPanel() }
    }

    /** The assistant (circle-to-select over this screen), as the side button opens it. */
    private fun assistant() {
        if (!dev.omalauncher.assist.PowosVoiceInteractionService.show()) Log.w(TAG, "no assistant: PowOS isn't the assistant (or it isn't ready)")
    }

    /** Home with the pull-up panel up (the drawer). */
    private fun drawer() {
        service.startActivity(
            Intent(service, dev.omalauncher.shell.ShellActivity::class.java)
                .setAction(Intent.ACTION_MAIN)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(dev.omalauncher.shell.EXTRA_HOME_PANEL, "apps"),
        )
    }

    /** The app used before this one, as the swipe along the bottom edge. */
    private fun previous() {
        val current = if (Switcher.open && Switcher.homeVisible) null else Tasks.visible(service)
        val previous = Tasks.list(service, 6).firstOrNull { it.id != current } ?: return
        Tasks.open(service, previous.id)
    }

    private fun playPause() {
        val audio = service.getSystemService(AudioManager::class.java)
        val now = SystemClock.uptimeMillis()
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, 0))
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, 0))
    }

    private fun launch(pkg: String) {
        val intent = service.packageManager.getLaunchIntentForPackage(pkg)
        if (intent == null) {
            Log.w(TAG, "no app $pkg to open")
            return
        }
        service.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    // --- the handles

    private fun handles() {
        val c = config()
        val screen = screen()
        val show = c.on && c.handles && !locked()
        leftHandle.update(if (show && c.left.on) span(c.left, screen) else null, screen)
        rightHandle.update(if (show && c.right.on) span(c.right, screen) else null, screen)
    }

    /** A strip window on one edge, drawing a faint line over the handle's span; never touchable. */
    private inner class Handle(
        private val right: Boolean,
    ) {
        private var view: Line? = null
        private var params: WindowManager.LayoutParams? = null

        fun update(
            span: Pair<Float, Float>?,
            screen: Rect,
        ) {
            if (span == null) return remove()
            val p =
                params ?: WindowManager.LayoutParams(
                    (HANDLE_WINDOW_DP * density).toInt(),
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    TYPE_HANDLE,
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT,
                ).apply {
                    title = "PowOS edge handle ${if (right) "right" else "left"}"
                    gravity = Gravity.TOP or if (right) Gravity.END else Gravity.START
                    fitInsetsTypes = 0
                    layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                }
            val v = view
            if (v == null) {
                val line = Line(right)
                line.span = span.first - screen.top to span.second - screen.top
                runCatching { wm.addView(line, p) }
                    .onSuccess {
                        view = line
                        params = p
                    }.onFailure { Log.w(TAG, "can't draw the edge handle", it) }
            } else {
                v.span = span.first - screen.top to span.second - screen.top
                v.invalidate()
            }
        }

        fun remove() {
            view?.let { runCatching { wm.removeView(it) } }
            view = null
        }
    }

    private inner class Line(
        private val right: Boolean,
    ) : View(handleContext) {
        var span = 0f to 0f
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = HANDLE_COLOR }

        override fun onDraw(canvas: Canvas) {
            val w = HANDLE_LINE_DP * density
            val inset = HANDLE_INSET_DP * density
            val left = if (right) width - inset - w else inset
            // Inset at the ends too, so the line reads as a handle, not a frame.
            val (top, bottom) = span
            val pad = HANDLE_END_PAD_DP * density
            if (bottom - top <= pad * 2) return
            canvas.drawRoundRect(left, top + pad, left + w, bottom - pad, w, w, paint)
        }
    }

    private companion object {
        const val TAG = "PowosEdge"
        const val QUICK_TOOLS = "quicktools"

        /** WindowManager.LayoutParams.TYPE_NAVIGATION_BAR_PANEL (hidden; INTERNAL_SYSTEM_WINDOW, the recents role's). */
        const val TYPE_HANDLE = 2024

        const val HOLD_POLL_MS = 50L
        const val QT_TRAVEL_DP = 96f
        const val HANDLE_WINDOW_DP = 6f
        const val HANDLE_LINE_DP = 2.5f
        const val HANDLE_INSET_DP = 1.5f
        const val HANDLE_END_PAD_DP = 12f

        /** White at 28%: visible on most screens, never loud. */
        const val HANDLE_COLOR = 0x47FFFFFF

        val EFFECT_TICK = VibrationEffect.EFFECT_TICK
        val EFFECT_CLICK = VibrationEffect.EFFECT_CLICK

        // QuickStepContract.SYSUI_STATE_* (this phone's SystemUI: getSystemUiStateString).
        const val SYSUI_NOTIFICATION_PANEL_EXPANDED = 1L shl 2
        const val SYSUI_BOUNCER_SHOWING = 1L shl 3
        const val SYSUI_KEYGUARD_SHOWING = 1L shl 6
        const val SYSUI_KEYGUARD_OCCLUDED = 1L shl 9
        const val SYSUI_QUICK_SETTINGS_VISIBLE = 1L shl 11
        const val SYSUI_IME_VISIBLE = 1L shl 18
        const val SYSUI_DEVICE_DOZING = 1L shl 21
    }
}
