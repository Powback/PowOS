package dev.omalauncher.system

import android.content.Context
import org.json.JSONObject

/**
 * Quick Tools: a small control center by the thumb, brought by an edge swipe ([dev.omalauncher.system.gesture.EdgeGestures]),
 * as Good Lock's One Hand Operation+ has it. The page (shell/ui/quicktools.tsx, mode=quicktools) shows the control
 * center's own tiles and sliders (QuickSettings through the bridge) in an [OverlayHost] window.
 *
 * - Finger-tied: while the swipe is on, the card follows it in ("qt.drag" { side, y, q }: y in CSS px from the top);
 *   let go, it settles open or shut ("qt.settle" { open }). A tap outside the card, Back, Home or the screen going off
 *   shut it.
 * - Its blur behind is the compositor's, under the card only: the card is a native glass region on this window
 *   (shell/ui/nativeglass.ts - quicktools is one of its region pages - GlassBlur's blur regions).
 */
class QuickToolsHost(
    service: Context,
) : OverlayHost(service, "quicktools", "quick tools") {
    fun begin(): Boolean = start().also { if (it) current = this }

    override fun stop() {
        if (current === this) current = null
        super.stop()
    }

    /** The swipe brings it in: [q] 0..1 of the way, by the finger at [y] (screen px) on the [right] or left edge. */
    fun drag(
        right: Boolean,
        y: Float,
        q: Float,
    ) {
        if (host == null) return
        show()
        val density = service.resources.displayMetrics.density
        emit("qt.drag", JSONObject().put("side", if (right) "right" else "left").put("y", (y / density).toDouble()).put("q", q.coerceIn(0f, 1f).toDouble()))
    }

    /** Opens it without a drag (a long swipe, an action): by [y] on that edge. */
    fun openAt(
        right: Boolean,
        y: Float,
    ) {
        drag(right, y, 0f)
        settle(true)
    }

    fun settle(open: Boolean) {
        if (host == null) return
        emit("qt.settle", JSONObject().put("open", open))
        if (!shown) return
        if (open) armOpen() else armShut()
    }

    override fun onBack() = settle(false)

    override fun onDismiss() = settle(false)

    companion object {
        var current: QuickToolsHost? = null
            private set
    }
}
