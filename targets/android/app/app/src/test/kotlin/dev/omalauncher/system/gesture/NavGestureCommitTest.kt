package dev.omalauncher.system.gesture

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The home swipe's rule (the user's, verified 10-29; regressed 10-31 02:13: "If I open an application full screen and
 * then swipe home then it always activates the switcher instead"): a quick flick or a long swipe up goes home; the
 * switcher opens only on a swipe up and HOLD. Only a short, slow release (or one flung back down) aborts.
 */
class NavGestureCommitTest {
    private val density = 2.5f
    private val bottom = 2390f

    /** Up [travel] px in [ms] at a steady speed, then held still [holdMs] (events still coming), then let go. */
    private fun release(
        travel: Float,
        ms: Long,
        holdMs: Long = 0,
    ): NavGestureClassifier.Outcome {
        val c = NavGestureClassifier(density, 2400f)
        c.down(540f, bottom, 0)
        var t = 0L
        while (t < ms) {
            t += 8
            c.move(540f, bottom - travel * t / ms, t)
        }
        val held = t + holdMs
        while (t < held) {
            t += 8
            c.move(540f + (t / 8 % 2), bottom - travel, t)
        }
        return c.up(540f, bottom - travel, t + 8)
    }

    @Test
    fun aFastShortFlickUpGoesHome() = assertEquals(NavGestureClassifier.Outcome.Home, release(70f, 64))

    @Test
    fun aShortSlowReleaseStillAborts() = assertEquals(NavGestureClassifier.Outcome.None, release(60f, 400))

    @Test
    fun aMeaningfulSlowTravelGoesHome() = assertEquals(NavGestureClassifier.Outcome.Home, release(200f, 600))

    // The user's swipes from the device log (10-31 02:12-02:21), each of which opened the switcher: now home.

    @Test
    fun theLoggedQuickFlick100pxGoesHome() = assertEquals(NavGestureClassifier.Outcome.Home, release(100f, 40))

    @Test
    fun theLoggedFlick160pxAt079GoesHome() = assertEquals(NavGestureClassifier.Outcome.Home, release(160f, 81))

    @Test
    fun theLoggedFlick282pxAt116GoesHome() = assertEquals(NavGestureClassifier.Outcome.Home, release(282f, 97))

    @Test
    fun aLongFastSwipeGoesHome() = assertEquals(NavGestureClassifier.Outcome.Home, release(900f, 200))

    @Test
    fun aLongRelaxedSwipeGoesHome() = assertEquals(NavGestureClassifier.Outcome.Home, release(500f, 500))

    @Test
    fun aSwipeUpAndHoldIsTheSwitcher() = assertEquals(NavGestureClassifier.Outcome.Switcher, release(400f, 200, holdMs = 400))

    @Test
    fun aPauseUnderTheHoldStillGoesHome() = assertEquals(NavGestureClassifier.Outcome.Home, release(400f, 200, holdMs = 120))
}
