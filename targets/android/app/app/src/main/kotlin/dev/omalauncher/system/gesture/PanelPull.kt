package dev.omalauncher.system.gesture

/**
 * The finger mapping of the panels the host pulls (the shade / control center from the top, the pull-up panels from a
 * bottom corner) - the same as the page's own drawer and panel drags (shell/ui/gesture.ts): a short travel, the
 * page's --drop / --rise (15% of the window's height), at a gain of 1.5, so the panel is all the way after ~90 px of
 * finger and fades in on the way (shell.css).
 */
object PanelPull {
    /** gesture.ts GAIN: the panel moves this much faster than the finger. */
    const val GAIN = 1.5f

    /** shell.css --drop / --rise: the panel's travel, of the window's height. */
    const val TRAVEL = 0.15f

    /** gesture.ts OPEN_AT: let go past this openness (~13 px of finger), it opens. */
    const val OPEN_AT = 0.15

    /** gesture.ts FLICK (CSS px/ms): faster than this towards shut shuts it, whatever the openness. */
    const val FLICK = 0.45f

    /** gesture.ts OPEN_FLICK: the drawer opens on a short flick this fast. */
    const val OPEN_FLICK = 0.2f

    /** The openness (0..1) for [distance] px of finger towards open in a window [height] px tall. */
    fun openness(
        distance: Float,
        height: Float,
    ): Float = (distance * GAIN / (height * TRAVEL)).coerceIn(0f, 1f)

    /** The openness for [distance] px of finger towards open over a travel of [travel] px (the page's own --drop). */
    fun opennessOver(
        distance: Float,
        travel: Float,
    ): Float = (distance * GAIN / travel).coerceIn(0f, 1f)

    /**
     * Whether it opens when let go at openness [q], the finger moving [velocity] CSS px/ms towards open (negative:
     * towards shut): a flick towards open faster than [openFlick] opens, one towards shut faster than [FLICK] shuts,
     * else past [OPEN_AT]. A cancelled touch never opens.
     */
    fun opens(
        velocity: Float,
        q: Double,
        cancelled: Boolean,
        openFlick: Float = FLICK,
    ): Boolean = !cancelled && (velocity > openFlick || (velocity >= -FLICK && q > OPEN_AT))
}
