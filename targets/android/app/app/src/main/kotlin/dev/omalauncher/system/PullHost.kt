package dev.omalauncher.system

import android.content.Context
import dev.omalauncher.shell.WindowBlur
import org.json.JSONObject

/**
 * The pull-up panels over any app: home's pull-up panel - the drawer, or PowOS AI's - brought by a swipe up from a
 * bottom corner ([dev.omalauncher.system.gesture.CornerPull]), in an [OverlayHost] window over the app (shell/ui/pull.tsx,
 * mode=pull). The page follows the finger ("pull.begin" { kind }, "pull.drag" { p }, "pull.end" { open }) and tells
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

    /** A corner swipe started: the panel ([kind] "apps" or "ai") comes up with the finger. */
    fun pullBegin(kind: String) {
        if (host == null || DeviceLock.locked(service)) return
        emit("pull.begin", JSONObject().put("kind", kind))
        show()
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
