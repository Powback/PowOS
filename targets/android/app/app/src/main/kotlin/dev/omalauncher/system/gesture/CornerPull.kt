package dev.omalauncher.system.gesture

import android.content.Context
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.util.Log
import android.view.Display
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.view.WindowManager
import dev.omalauncher.system.PullHost
import dev.omalauncher.system.Tasks
import java.io.File
import kotlin.math.abs

/**
 * The pull-up panels over any app (home has them in its own page): a swipe up from the bottom-LEFT corner brings
 * PowOS AI's panel, from the bottom-RIGHT corner the drawer ([PullHost], shell/ui/pull.tsx) - the panel following the
 * finger as on home. The middle of the bottom edge stays gesture navigation's ([NavGesture]: home, the switcher, the
 * quick switch), and so does every corner swipe that isn't clearly up.
 *
 * It wraps [NavGesture], since both start in the navigation bar's strip: a finger down there goes to [nav] as always
 * (which already asks for its recents transition); in a corner zone ([CORNER] of the width) this also watches it, and
 * once it has gone [slop] mostly upwards - before nav has seen that move - it's the panel's: nav hears a cancel (its
 * window goes back where it was), the panel comes up. Anything else stays nav's, event for event.
 *
 * Only over an app (home's own page has the corners), only in gesture navigation (nav takes the down), and only while
 * the switch is on: the page store's `pullOverApps` (settings -> style -> home; files/shell-data/pullOverApps.json,
 * "off" turns it off).
 */
class CornerPull(
    private val service: Context,
    private val nav: NavGesture,
) : GestureConsumer {
    private val display: Display = service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    private val displayContext = service.createDisplayContext(display)
    private val slop = ViewConfiguration.get(displayContext).scaledTouchSlop.toFloat()
    private val density get() = displayContext.resources.displayMetrics.density
    private val switch = File(service.filesDir, "shell-data/pullOverApps.json")

    private enum class State { NAV, WATCHING, PULLING }

    private var state = State.NAV
    private var navFollows = false
    private var x0 = 0f
    private var y0 = 0f
    private var kind = "apps"
    private var height = 1f
    private var velocity: VelocityTracker? = null

    private fun on(): Boolean = runCatching { !switch.isFile || !switch.readText().contains("off") }.getOrDefault(true)

    private fun screen(): Rect = runCatching { displayContext.getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds }.getOrElse { Rect(0, 0, 1080, 2400) }

    override fun onDown(e: MotionEvent): Boolean {
        navFollows = nav.onDown(e)
        state = State.NAV
        if (!navFollows) return false
        if (PullHost.current == null || !on()) return true
        val s = screen()
        val zone = s.width() * CORNER
        val left = e.rawX < s.left + zone
        val right = e.rawX >= s.right - zone
        if (!left && !right) return true
        // Over home its own page has the corners.
        if (runCatching { Tasks.visible(service) }.getOrNull() == null) return true
        state = State.WATCHING
        kind = if (left) "ai" else "apps"
        x0 = e.rawX
        y0 = e.rawY
        height = s.height().toFloat()
        velocity?.recycle()
        velocity = VelocityTracker.obtain().also { it.addMovement(e) }
        return true
    }

    override fun onEvent(e: MotionEvent): GestureConsumer.Verdict {
        when (state) {
            State.NAV -> return nav.onEvent(e)
            State.WATCHING -> {
                velocity?.addMovement(e)
                if (e.actionMasked == MotionEvent.ACTION_MOVE) {
                    val up = y0 - e.rawY
                    val dx = abs(e.rawX - x0)
                    if (up > slop && up > dx * 1.2f) {
                        claim()
                        return GestureConsumer.Verdict.TAKE
                    }
                    if (dx > slop || abs(up) > slop) state = State.NAV
                }
                return nav.onEvent(e)
            }
            State.PULLING -> {
                velocity?.addMovement(e)
                val host = PullHost.current ?: return GestureConsumer.Verdict.DROP
                when (e.actionMasked) {
                    MotionEvent.ACTION_MOVE -> host.pullDrag(openness(e))
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        val v = velocity
                        velocity = null
                        // px/ms upwards, in dp as the shell's own flick threshold (shadeOpens: the same rule as the shade's).
                        val vy = v?.let { it.computeCurrentVelocity(1); -it.yVelocity / density } ?: 0f
                        v?.recycle()
                        val open = e.actionMasked == MotionEvent.ACTION_UP && shadeOpens(vy, openness(e).toDouble(), cancelled = false)
                        Log.i(TAG, "corner pull: let go at ${"%.2f".format(openness(e))}, ${"%.2f".format(vy)} dp/ms -> ${if (open) "open" else "shut"}")
                        host.pullEnd(open)
                        state = State.NAV
                        return GestureConsumer.Verdict.DROP
                    }
                }
                return GestureConsumer.Verdict.TAKE
            }
        }
    }

    /** It's the panel's: nav lets go (its window back where it was), the panel comes up with the finger. */
    private fun claim() {
        state = State.PULLING
        if (navFollows) {
            val now = android.os.SystemClock.uptimeMillis()
            val cancel = MotionEvent.obtain(now, now, MotionEvent.ACTION_CANCEL, x0, y0, 0)
            runCatching { nav.onEvent(cancel) }
            cancel.recycle()
        }
        Log.i(TAG, "corner pull: $kind")
        PullHost.current?.pullBegin(kind)
    }

    private fun openness(e: MotionEvent) = ((y0 - e.rawY) / (height * SPAN)).coerceIn(0f, 1f)

    private companion object {
        const val TAG = "PowosCornerPull"

        /** The corner zones: this much of the width on each side of the bottom edge. */
        const val CORNER = 0.22f

        /** As home's pull-up: the panel is all the way up after this much of the screen's height. */
        const val SPAN = 0.6f
    }
}
