package dev.omalauncher.system

import android.content.Context
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.view.Display
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.view.WindowManager
import dev.omalauncher.shell.WindowBlur
import dev.omalauncher.system.gesture.GestureConsumer
import dev.omalauncher.system.gesture.PanelPull
import org.json.JSONObject
import kotlin.math.abs

/**
 * The launcher: one overlay, as the shade is ([ShadeHost]) - the drawer, or PowOS AI's panel, in an [OverlayHost] window
 * over whatever shows (shell/ui/pull.tsx, mode=pull), for every way in: a swipe up from a bottom corner
 * ([dev.omalauncher.system.gesture.CornerPull]), a swipe up on home's body ([homeLift], while home's page says so:
 * pull.homePull - as the shade's pull down), home's pill and an edge gesture's "app drawer" ([open]). Over an app the
 * app stays where it is underneath; home draws no drawer of its own. The page follows the finger ("pull.begin" { kind }, "pull.drag" { p }, "pull.end" { open }) and tells
 * when it's shut ("pull.closed"); an app opened from the drawer simply comes up (the panel shuts itself).
 *
 * What's behind the window (the app) is blurred as it comes up, the page only tints: one full-window blur region
 * ([WindowBlur]), following the panel's openness.
 */
class PullHost(
    service: Context,
) : OverlayHost(service, "pull", "pull-up panel") {
    private val blur = WindowBlur({ root })

    /** What's behind should be blurred by now (0..1); applied only while the page can be seen ([pageReady]). */
    private var behind = 0f

    private fun blurBehind(amount: Float) {
        behind = amount
        blur.set(if (pageReady) amount else 0f)
    }

    override fun onPageReady() = blur.set(behind)

    fun begin(): Boolean = start().also { if (it) current = this }

    override fun stop() {
        if (current === this) current = null
        blur.set(0f)
        super.stop()
    }

    /**
     * A swipe up started: the panel ([kind] "apps" or "ai") comes up with the finger. [how]: what it opens with (the
     * search focused, the chat, a draft - state.ts LauncherOpen), done by the page once it's open.
     */
    fun pullBegin(
        kind: String,
        how: JSONObject? = null,
    ) {
        if (host == null || DeviceLock.locked(service)) return
        emit("pull.begin", JSONObject(how?.toString() ?: "{}").put("kind", kind))
        show()
    }

    /** Up at once, not following a finger: home's pill, an edge gesture's "app drawer", the side button's chat. */
    fun open(
        kind: String,
        how: JSONObject?,
    ): Boolean {
        if (host == null || DeviceLock.locked(service)) return false
        pullBegin(kind, how)
        pullDrag(1f)
        pullEnd(true)
        return true
    }

    /** Home's page: a swipe up on its body is the launcher's now (nothing open over home's pages, not editing). */
    var homePull = false
    var homePullExcluded: List<Rect> = emptyList()

    /** From home's left half the swipe brings PowOS AI's panel (the page's pull-up corners setting). */
    var homeSplit = false

    private val displayContext =
        service.createDisplayContext(service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY))

    private fun screen(): Rect =
        runCatching { displayContext.getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds }.getOrElse { Rect(0, 0, 1080, 2400) }

    /** Whether a finger down on home's body at ([x], [y]) may be the launcher's lift. */
    private fun homeLiftable(
        x: Float,
        y: Float,
    ): Boolean {
        if (!homePull || host == null || shown || DeviceLock.locked(service) || !homeBare()) return false
        // Not on home's controls that drag (the dock), the controller pad, the PowOS AI overlay, nor a floating window.
        // Spec G-R: a drag starting on a strip that scrolls (the dock, the side column's recents, a widget list) is its own.
        val r = homePullExcluded.firstOrNull { it.contains(x.toInt(), y.toInt()) }
        if (r != null) android.util.Log.i("PowosPull", "not lifting: excluded (${x.toInt()},${y.toInt()}) in $r of ${homePullExcluded.size}")
        if (r != null || dev.omalauncher.shell.ControllerPad.covers(x, y)) return false
        // Any app's window, by WM's bounds (spec G-W): OnePlus's own floating windows aren't in WindowFrames.
        return !PetOverlay.assistShowing && !AppWindowAt.covered(service, x, y)
    }

    /** Home shows with nothing of the system's over it (the switcher, the shade). */
    private fun homeBare(): Boolean = Switcher.onHome && Switcher.homeVisible && !Switcher.open && ShadeHost.current?.shown != true

    /**
     * The launcher's lift on home's body (PowOS's gesture input, beside the shade's pull down: FirstToTake): a finger
     * dragged up is taken and the overlay follows it, as the bottom corners' ([dev.omalauncher.system.gesture.CornerPull]).
     */
    val homeLift =
        object : GestureConsumer {
            private val slop = ViewConfiguration.get(displayContext).scaledTouchSlop.toFloat()
            private var x0 = 0f
            private var y0 = 0f
            private var height = 1f
            private var kind = "apps"
            private var taken = false
            private var velocity: VelocityTracker? = null

            override fun onDown(e: MotionEvent): Boolean {
                if (!homeLiftable(e.rawX, e.rawY)) return false
                val s = screen()
                x0 = e.rawX
                y0 = e.rawY
                height = s.height().toFloat()
                kind = if (homeSplit && e.rawX < s.exactCenterX()) "ai" else "apps"
                taken = false
                velocity?.recycle()
                velocity = VelocityTracker.obtain().also { it.addMovement(e) }
                return true
            }

            private fun openness(e: MotionEvent) = PanelPull.openness(y0 - e.rawY, height)

            override fun onEvent(e: MotionEvent): GestureConsumer.Verdict {
                velocity?.addMovement(e)
                val end = e.actionMasked == MotionEvent.ACTION_UP || e.actionMasked == MotionEvent.ACTION_CANCEL
                if (!taken) return if (end) drop() else watch(e)
                if (e.actionMasked == MotionEvent.ACTION_MOVE) pullDrag(openness(e))
                if (!end) return GestureConsumer.Verdict.TAKE
                val density = displayContext.resources.displayMetrics.density
                val vy = velocity?.let { it.computeCurrentVelocity(1); -it.yVelocity / density } ?: 0f
                val open = e.actionMasked == MotionEvent.ACTION_UP && PanelPull.opens(vy, openness(e).toDouble(), cancelled = false, openFlick = PanelPull.OPEN_FLICK)
                pullEnd(open)
                return drop()
            }

            /** Not yet taken: up past the slop (mostly up) it's the launcher's; any other way, not. */
            private fun watch(e: MotionEvent): GestureConsumer.Verdict {
                if (e.actionMasked != MotionEvent.ACTION_MOVE) return GestureConsumer.Verdict.FOLLOW
                val up = y0 - e.rawY
                val dx = abs(e.rawX - x0)
                if (up > slop && up > dx * 1.2f) {
                    taken = true
                    pullBegin(kind)
                    pullDrag(openness(e))
                    return GestureConsumer.Verdict.TAKE
                }
                return if (dx > slop || -up > slop) drop() else GestureConsumer.Verdict.FOLLOW
            }

            private fun drop(): GestureConsumer.Verdict {
                velocity?.recycle()
                velocity = null
                taken = false
                return GestureConsumer.Verdict.DROP
            }
        }

    /** [p] 0..1: how far up the panel is. */
    fun pullDrag(p: Float) {
        if (!shown) return
        blurBehind(p)
        emit("pull.drag", JSONObject().put("p", p.coerceIn(0f, 1f).toDouble()))
    }

    fun pullEnd(open: Boolean) {
        if (host == null) return
        emit("pull.end", JSONObject().put("open", open))
        if (!shown) return
        blurBehind(if (open) 1f else 0f)
        if (open) armOpen() else armShut()
    }

    override fun onBack() {
        emit("system.back", null)
    }

    override fun onDismiss() = pullEnd(false)

    override fun onHidden() {
        blurBehind(0f)
        emit("pull.hide", null)
    }

    companion object {
        var current: PullHost? = null
            private set
    }
}
