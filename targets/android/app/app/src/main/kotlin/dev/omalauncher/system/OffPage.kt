package dev.omalauncher.system

/**
 * The rules for a window on a home page that isn't on screen (plain ints, JVM-testable):
 * - nothing automatic raises it: a page swipe's start shows its leash to slide it in, but only a window that left
 *   UNDER home (no leash, WindowFrames' underHome) is reordered to the top. Every other off-page window already sits
 *   above home, hidden; a reorder there was a TO_FRONT per touch on home (11-03: Plasma's task 2429 raised and
 *   hidden again on every swipe start - surface torn down and rebuilt, KWin "entering fallback", 190 janks).
 * - on its page it is on the screen: a window that comes back with most of its width off the glass (Plasma's at
 *   x 2136..3496 on a 2268-wide screen, its page shown but the window out of reach) is moved onto it.
 */
object OffPage {
    /**
     * Whether a window away on another page is hidden in WM (WCT.setHidden). Never: that made the app invisible, its
     * surfaces were destroyed and every page swipe's start (which shows it to slide it in) rebuilt them - Plasma's
     * desktop reconnected per swipe, 450-560 ms main-thread freezes (11-03, perf-1793735444160). Its leash keeps it
     * out of sight and touch instead ([AWAY_SCALE], TaskSurfaces.hide); its surfaces stay alive.
     */
    const val WM_HIDDEN_AWAY = false

    /** An away window's leash scale: even a window 9999 px wide maps under one pixel - no touch lands on it. */
    const val AWAY_SCALE = 1e-4f

    /** At a page slide's start: whether the window on page offset [rel] is reordered to the top in its transition. */
    fun raiseAtSlideStart(
        rel: Int,
        underHome: Boolean,
    ): Boolean = rel != 0 && underHome

    /** A window spanning [left]..[right] has less than half its width inside [areaLeft]..[areaRight]. */
    fun mostlyOff(
        left: Int,
        right: Int,
        areaLeft: Int,
        areaRight: Int,
    ): Boolean {
        val w = right - left
        if (w <= 0) return false
        val inside = (minOf(right, areaRight) - maxOf(left, areaLeft)).coerceAtLeast(0)
        return inside * 2 < w
    }
}
