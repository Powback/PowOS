package dev.omalauncher.system

/** A rectangle in display px, [l, r) x [t, b) as android.graphics.Rect.contains reads it - plain, so the JVM tests run it. */
data class BarRect(
    val l: Int,
    val t: Int,
    val r: Int,
    val b: Int,
) {
    fun contains(
        x: Int,
        y: Int,
    ): Boolean = x in l until r && y in t until b
}

/** What's on the status bar strip now (display px): the page's own controls, Android's app handles, the web windows' bars. */
data class BarClaims(
    val controls: List<BarRect>,
    val handles: List<BarRect>,
    val windows: List<BarRect>,
    /**
     * The recording light (chrome.tsx RecordingRing, data-action "privacy"): drawn on the camera's cutout, so on the
     * folded cover - camera hole centred - it sits where an app's centred "•••" handle is. It outranks handles and
     * windows: the ring's tap opens the control center (rec-light 11-11: "not pulling: claimed (558,63) in
     * Rect(459, 0 - 657, 126)", the camera's handle took it). The handle keeps its sides.
     */
    val lights: List<BarRect> = emptyList(),
)

/** Whose a finger down on the status bar strip is (spec G-R). */
enum class BarHit {
    /** Android's app handle ("•••" over split and full-screen apps): SystemUI's own window, the strip leaves it a hole. */
    HANDLE,

    /** A web window's title bar or controls (a maximised one's merged bar): home's, the strip takes it and hands it over. */
    WINDOW,

    /** The status bar page's own control (the clock, the indicators, the FPS meter; the recording light over all). */
    CONTROL,

    /** The rest of the bar: SystemUI's status bar (its live capsules); the pull comes from the input monitor. */
    BAR,
}

/**
 * The status bar strip's hit routing (ShadeHost's touchable region and its forwarding to home): one list, so what the
 * strip takes and what it hands over can't drift apart. Why the strip TAKES a web window's bar rather than leaving it a
 * hole (the 2800d804 way): under the strip is SystemUI's StatusBar window (`dumpsys input`: touchable [0,0][w,bar]),
 * not home, so a hole gave the tap to SystemUI and the merged bar's title, buttons and drag were all dead (the user,
 * "Maximised window's top bar takes taps"). An app handle is SystemUI's own window above its status bar: a hole there
 * reaches it.
 */
object BarHits {
    fun route(
        x: Int,
        y: Int,
        claims: BarClaims,
    ): BarHit =
        when {
            claims.lights.any { it.contains(x, y) } -> BarHit.CONTROL
            claims.handles.any { it.contains(x, y) } -> BarHit.HANDLE
            claims.windows.any { it.contains(x, y) } -> BarHit.WINDOW
            claims.controls.any { it.contains(x, y) } -> BarHit.CONTROL
            else -> BarHit.BAR
        }

    /** Whether the strip's window gets the touch at all ([monitored] false: it takes the pull itself, the HACK in ShadeHost). */
    fun stripTakes(
        hit: BarHit,
        monitored: Boolean,
    ): Boolean =
        when (hit) {
            BarHit.HANDLE -> false
            BarHit.WINDOW, BarHit.CONTROL -> true
            BarHit.BAR -> !monitored
        }

    /** Whether a gesture that starts at [hit] is home's (forwarded to its page) rather than the strip page's. */
    fun forwards(hit: BarHit): Boolean = hit == BarHit.WINDOW
}

/**
 * Where the recording light rings the camera on the status strip (chrome.tsx RecordingRing), display px; null: the
 * camera isn't on the strip in this rotation (or there's no cutout) - the light is a dot by the status icons.
 * [window]: the strip window's own cutout rects (the inner screen's top-right hole unfolded upright, the cover's centred
 * one); [display]: the display's in its current rotation - the strip sits at the display's top left, so the same px.
 * A cutout counts only where it reaches the strip ([strip] px tall): the top one first, else the smallest.
 */
object CameraCutout {
    fun onStrip(
        window: List<BarRect>,
        display: List<BarRect>,
        strip: Int,
    ): BarRect? {
        fun pick(rects: List<BarRect>) =
            rects.filter { it.r > it.l && it.b > it.t && it.t < strip.coerceAtLeast(1) }
                .sortedWith(compareBy({ it.t }, { (it.r - it.l) * (it.b - it.t) }))
                .firstOrNull()
        return pick(window) ?: pick(display)
    }
}
