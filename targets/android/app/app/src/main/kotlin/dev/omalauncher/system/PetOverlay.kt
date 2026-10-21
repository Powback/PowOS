package dev.omalauncher.system

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import dev.omalauncher.App
import dev.omalauncher.assist.PowosVoiceInteractionService
import dev.omalauncher.shell.ShellHost
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.hypot

/**
 * The pet over apps (docs/PET.md v2, step d): the same creature as on home (shell/ui/petover.tsx, mode=petover) in a
 * small window at a screen edge while an app is in front - the agents' face wherever you are.
 *
 * - Shown only while: the user has it on ([enabled], "pet.overlay", default on), an app is in front (not home - home
 *   has its own pet), the screen's unlocked, the shade's shut, the assistant (the side button's crop) isn't up, and the
 *   app isn't full screen (a game, a video: the status bar hidden). Otherwise GONE, its page paused (no frames).
 * - Its touches are native (no page round trip): a drag moves the window (the page gets "petover.drag" for the body's
 *   wobble), let go it glides to the nearest side edge and stays at that height; a tap opens the assistant (listening,
 *   no screen); a hold (550 ms) asks about this screen - the side button's session, with the screen's text and picture.
 * - Out of the way: 10 s untouched it tucks half behind its edge and fades to 70% (peeking); a touch pulls it out
 *   first. The keyboard up: it goes (the IME flag in SystemUI's state).
 */
class PetOverlay(
    private val service: Context,
) {
    private val display: Display = service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    private val context: Context = service.createDisplayContext(display).createWindowContext(TYPE, null)
    private val wm = context.getSystemService(WindowManager::class.java)
    private val prefs = service.getSharedPreferences("pet", Context.MODE_PRIVATE)
    private var host: ShellHost? = null
    private var root: Root? = null
    private var params: WindowManager.LayoutParams? = null
    private var shown = false

    private var homeVisible = true
    private var keyguard = false
    private var shadeOpen = false
    private var ime = false
    private var peeking = false
    private val tuck = Runnable { peek(true) }

    private val density get() = context.resources.displayMetrics.density
    private val sizePx get() = (SIZE_DP * density).toInt()

    fun start(): Boolean {
        if (host != null) return true
        val runtime = (service.applicationContext as App).runtime
        runtime.start()
        val h = ShellHost(context, null, runtime, "petover")
        host = h
        val r = Root(context).apply { addView(h.web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)) }
        r.visibility = View.GONE
        // Full screen apps (the status bar hidden: a game, a video): what the shade's strip over the status bar sees
        // (ShadeHost.statusBarShown). This small window's own insets have no status bar in them at all - read here it
        // counted every app as full screen and the pet never showed over apps (2026-10-21).
        root = r
        params = layout().also { wm.addView(r, it) }
        h.web.onPause()
        current = this
        Log.i(TAG, "pet overlay ready")
        return true
    }

    fun stop() {
        if (current === this) current = null
        root?.let { runCatching { wm.removeView(it) } }
        root = null
        host?.destroy()
        host = null
    }

    /** SystemUI's state flags: the lock screen and the shade hide it. */
    fun systemUiState(flags: Long) {
        keyguard = flags and (SYSUI_KEYGUARD_SHOWING or SYSUI_BOUNCER_SHOWING) != 0L && flags and SYSUI_KEYGUARD_OCCLUDED == 0L
        shadeOpen = flags and (SYSUI_NOTIFICATION_PANEL_EXPANDED or SYSUI_QUICK_SETTINGS_VISIBLE) != 0L
        ime = flags and SYSUI_IME_VISIBLE != 0L
        update()
    }

    /** Home came up or went (Switcher's home page): the pet over apps is for when it's gone. */
    fun homeVisible(visible: Boolean) {
        homeVisible = visible
        update()
    }

    fun update() {
        val fullScreen = ShadeHost.current?.statusBarShown == false
        val want = enabled(service) && !homeVisible && !keyguard && !shadeOpen && !assistShowing && !fullScreen && !ime
        val r = root ?: return
        if (want == shown) return
        shown = want
        r.visibility = if (want) View.VISIBLE else View.GONE
        host?.web?.let { if (want) it.onResume() else it.onPause() }
        r.removeCallbacks(tuck)
        if (want) r.postDelayed(tuck, PEEK_AFTER_MS)
        Log.i(TAG, "pet over apps ${if (want) "shown" else "hidden"}")
    }

    private fun emit(
        event: String,
        data: Any?,
    ) = host?.bridge?.emit(event, data)

    private fun layout(): WindowManager.LayoutParams {
        val m = context.resources.displayMetrics
        val right = prefs.getBoolean("side.right", true)
        return WindowManager.LayoutParams(
            sizePx,
            sizePx,
            TYPE,
            // NO_LIMITS: it can tuck half off screen (peeking).
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            title = "PowOS pet"
            gravity = Gravity.TOP or Gravity.START
            fitInsetsTypes = 0
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            x = if (right) m.widthPixels - sizePx else 0
            y = (prefs.getFloat("y", 0.62f) * m.heightPixels).toInt().coerceIn(0, m.heightPixels - sizePx)
        }
    }

    /** Let go: to the nearest side edge, at that height (kept). */
    private fun settle() {
        val p = params ?: return
        val r = root ?: return
        val m = context.resources.displayMetrics
        val right = p.x + sizePx / 2 > m.widthPixels / 2
        val to = if (right) m.widthPixels - sizePx else 0
        prefs.edit().putBoolean("side.right", right).putFloat("y", p.y.toFloat() / m.heightPixels).apply()
        ValueAnimator.ofInt(p.x, to).apply {
            duration = 260
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                p.x = it.animatedValue as Int
                runCatching { wm.updateViewLayout(r, p) }
            }
            start()
        }
        emit("petover.drop", null)
    }

    /** Tucked half behind its edge and faded ([on]), or out in full. */
    private fun peek(on: Boolean) {
        val p = params ?: return
        val r = root ?: return
        if (on == peeking) return
        peeking = on
        val m = context.resources.displayMetrics
        val right = p.x + sizePx / 2 > m.widthPixels / 2
        val out = if (right) m.widthPixels - sizePx else 0
        val to = if (!on) out else if (right) m.widthPixels - sizePx / 2 else -sizePx / 2
        r.animate().alpha(if (on) PEEK_ALPHA else 1f).setDuration(220).start()
        ValueAnimator.ofInt(p.x, to).apply {
            duration = 240
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                p.x = it.animatedValue as Int
                runCatching { wm.updateViewLayout(r, p) }
            }
            start()
        }
    }

    private inner class Root(
        context: Context,
    ) : FrameLayout(context) {
        private val slop = ViewConfiguration.get(context).scaledTouchSlop
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var lastX = 0f
        private var lastY = 0f
        private var dragging = false
        private var held = false
        private val hold =
            Runnable {
                if (dragging) return@Runnable
                held = true
                performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
                emit("petover.hold", null)
                // Ask about this screen: the side button's session (the screen's text and a picture of it).
                PowosVoiceInteractionService.show()
            }

        override fun onInterceptTouchEvent(ev: MotionEvent): Boolean = true

        override fun onTouchEvent(ev: MotionEvent): Boolean {
            val p = params ?: return false
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    // A touch pulls it out of its peek, and the 10 s start again.
                    removeCallbacks(tuck)
                    // Out of its peek: the drag starts from where it's sliding to (in full at its edge).
                    val w = context.resources.displayMetrics.widthPixels
                    startX = if (peeking) (if (p.x + sizePx / 2 > w / 2) w - sizePx else 0) else p.x
                    if (peeking) peek(false)
                    downX = ev.rawX
                    downY = ev.rawY
                    lastX = ev.rawX
                    lastY = ev.rawY
                    startY = p.y
                    dragging = false
                    held = false
                    postDelayed(hold, HOLD_MS)
                    emit("petover.down", null)
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!dragging && hypot(ev.rawX - downX, ev.rawY - downY) > slop) {
                        dragging = true
                        removeCallbacks(hold)
                    }
                    if (dragging) {
                        val m = context.resources.displayMetrics
                        p.x = (startX + (ev.rawX - downX)).toInt().coerceIn(0, m.widthPixels - sizePx)
                        p.y = (startY + (ev.rawY - downY)).toInt().coerceIn(0, m.heightPixels - sizePx)
                        runCatching { wm.updateViewLayout(this, p) }
                        val d = density
                        if (abs(ev.rawX - lastX) + abs(ev.rawY - lastY) > 0.5f) {
                            emit("petover.drag", JSONObject().put("dx", ((ev.rawX - lastX) / d).toDouble()).put("dy", ((ev.rawY - lastY) / d).toDouble()))
                        }
                        lastX = ev.rawX
                        lastY = ev.rawY
                    }
                }
                MotionEvent.ACTION_UP -> {
                    removeCallbacks(hold)
                    postDelayed(tuck, PEEK_AFTER_MS)
                    when {
                        dragging -> settle()
                        held -> Unit
                        else -> {
                            emit("petover.tap", null)
                            PowosVoiceInteractionService.show()
                        }
                    }
                }
                MotionEvent.ACTION_CANCEL -> {
                    removeCallbacks(hold)
                    postDelayed(tuck, PEEK_AFTER_MS)
                    if (dragging) settle()
                }
            }
            return true
        }
    }

    companion object {
        private const val TAG = "PowosPet"

        /** WindowManager.LayoutParams.TYPE_STATUS_BAR_SUB_PANEL (hidden), as the overlays' (OverlayHost). */
        private const val TYPE = 2017
        private const val SIZE_DP = 84
        private const val HOLD_MS = 550L
        private const val PEEK_AFTER_MS = 10_000L
        private const val PEEK_ALPHA = 0.7f

        // QuickStepContract.SYSUI_STATE_* (this phone's SystemUI: getSystemUiStateString).
        private const val SYSUI_NOTIFICATION_PANEL_EXPANDED = 1L shl 2
        private const val SYSUI_BOUNCER_SHOWING = 1L shl 3
        private const val SYSUI_KEYGUARD_SHOWING = 1L shl 6
        private const val SYSUI_KEYGUARD_OCCLUDED = 1L shl 9
        private const val SYSUI_QUICK_SETTINGS_VISIBLE = 1L shl 11
        private const val SYSUI_IME_VISIBLE = 1L shl 18

        var current: PetOverlay? = null
            private set

        /** The assistant's session is up (the side button's crop screen): the pet keeps out of it. */
        var assistShowing = false
            set(value) {
                field = value
                current?.update()
            }

        /** The user's switch (`powos pet overlay on|off`, through the page: "pet.overlay"); on by default. */
        fun enabled(context: Context) = context.getSharedPreferences("pet", Context.MODE_PRIVATE).getBoolean("overlay", true)

        /** Reads it, or sets it ([on] non-null). */
        fun enabled(
            context: Context,
            on: Boolean?,
        ): Boolean {
            if (on != null) {
                context.getSharedPreferences("pet", Context.MODE_PRIVATE).edit().putBoolean("overlay", on).apply()
                current?.update()
            }
            return enabled(context)
        }
    }
}
