package dev.omalauncher.system.gesture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NavGestureClassifierTest {
    // A phone-sized screen at density 2.5: 1080 x 2400 px.
    private val density = 2.5f
    private val height = 2400f
    private val bottom = 2390f

    private fun classifier() = NavGestureClassifier(density, height)

    /** Moves the finger from ([x0], [y0]) to ([x1], [y1]) in [ms], one event every 8 ms, starting at [t0]. */
    private fun NavGestureClassifier.drag(
        x0: Float,
        y0: Float,
        x1: Float,
        y1: Float,
        ms: Long,
        t0: Long = 0,
    ): Long {
        var t = t0
        val steps = (ms / 8).coerceAtLeast(1)
        for (i in 1..steps) {
            t = t0 + i * 8
            move(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps, t)
        }
        return t
    }

    @Test
    fun aQuickSwipeUpGoesHome() {
        val c = classifier()
        c.down(540f, bottom, 0)
        val t = c.drag(540f, bottom, 540f, bottom - 400f, 120)
        assertEquals(NavGestureClassifier.Axis.UP, c.axis)
        assertEquals(NavGestureClassifier.Outcome.Home, c.up(540f, bottom - 400f, t + 8))
    }

    @Test
    fun aSlowLongSwipeUpLetGoIsTheSwitcher() {
        val c = classifier()
        c.down(540f, bottom, 0)
        // 700 px in 1.4 s: never a fling, never still, past the home distance (22% of the screen): the window is on
        // its card by then, and a slow release leaves it there (Quickstep's non-fling end target).
        val t = c.drag(540f, bottom, 540f, bottom - 700f, 1400)
        assertFalse(c.armed)
        assertEquals(NavGestureClassifier.Outcome.Switcher, c.up(540f, bottom - 700f, t + 8))
    }

    @Test
    fun aModerateFlickUpGoesHome() {
        val c = classifier()
        c.down(540f, bottom, 0)
        // 1.6 px/ms (0.64 dp/ms): over Quickstep's 0.5 dp/ms fling threshold.
        val t = c.drag(540f, bottom, 540f, bottom - 480f, 300)
        assertEquals(NavGestureClassifier.Outcome.Home, c.up(540f, bottom - 480f, t + 8))
    }

    @Test
    fun swipeUpAndHoldIsTheSwitcher() {
        val c = classifier()
        c.down(540f, bottom, 0)
        var t = c.drag(540f, bottom, 540f, bottom - 500f, 200)
        // Held still for 300 ms, events still coming (a finger is never perfectly still).
        for (i in 1..37) {
            t += 8
            c.move(540f + (i % 2), bottom - 500f, t)
        }
        assertTrue(c.armed)
        assertEquals(NavGestureClassifier.Outcome.Switcher, c.up(540f, bottom - 500f, t + 8))
    }

    @Test
    fun aHoldWithNoEventsArmsOnRelease() {
        val c = classifier()
        c.down(540f, bottom, 0)
        val t = c.drag(540f, bottom, 540f, bottom - 500f, 200)
        // The last moves were slow enough to start the pause, then no events until the release.
        c.move(540f, bottom - 500f, t + 8)
        c.move(540f, bottom - 500f, t + 16)
        assertEquals(NavGestureClassifier.Outcome.Switcher, c.up(540f, bottom - 500f, t + 400))
    }

    @Test
    fun aFlingUpAfterAHoldStillGoesHome() {
        val c = classifier()
        c.down(540f, bottom, 0)
        var t = c.drag(540f, bottom, 540f, bottom - 500f, 200)
        for (i in 1..37) {
            t += 8
            c.move(540f, bottom - 500f, t)
        }
        assertTrue(c.armed)
        t = c.drag(540f, bottom - 500f, 540f, bottom - 900f, 64, t)
        assertFalse(c.armed)
        assertEquals(NavGestureClassifier.Outcome.Home, c.up(540f, bottom - 900f, t + 8))
    }

    @Test
    fun aShortSwipeUpIsNothing() {
        val c = classifier()
        c.down(540f, bottom, 0)
        // 100 px slowly: under the home distance, no fling, not held.
        val t = c.drag(540f, bottom, 540f, bottom - 100f, 400)
        assertEquals(NavGestureClassifier.Outcome.None, c.up(540f, bottom - 100f, t + 8))
    }

    @Test
    fun swipingUpThenFlingingBackDownCancels() {
        val c = classifier()
        c.down(540f, bottom, 0)
        var t = c.drag(540f, bottom, 540f, bottom - 700f, 300)
        t = c.drag(540f, bottom - 700f, 540f, bottom - 300f, 48, t)
        assertEquals(NavGestureClassifier.Outcome.None, c.up(540f, bottom - 300f, t + 8))
    }

    @Test
    fun alongTheBottomEdgeIsAQuickSwitch() {
        val c = classifier()
        c.down(300f, bottom, 0)
        val t = c.drag(300f, bottom, 700f, bottom - 20f, 160)
        assertEquals(NavGestureClassifier.Axis.SIDEWAYS, c.axis)
        assertEquals(NavGestureClassifier.Outcome.QuickSwitch(rightwards = true), c.up(700f, bottom - 20f, t + 8))
    }

    @Test
    fun leftwardsQuickSwitch() {
        val c = classifier()
        c.down(700f, bottom, 0)
        val t = c.drag(700f, bottom, 300f, bottom - 10f, 160)
        assertEquals(NavGestureClassifier.Outcome.QuickSwitch(rightwards = false), c.up(300f, bottom - 10f, t + 8))
    }

    @Test
    fun aShortSlowSidewaysNudgeIsNothing() {
        val c = classifier()
        c.down(500f, bottom, 0)
        val t = c.drag(500f, bottom, 560f, bottom, 600)
        assertEquals(NavGestureClassifier.Axis.SIDEWAYS, c.axis)
        assertEquals(NavGestureClassifier.Outcome.None, c.up(560f, bottom, t + 8))
    }

    @Test
    fun aTapDecidesNothing() {
        val c = classifier()
        c.down(540f, bottom, 0)
        assertEquals(null, c.move(542f, bottom - 3f, 16))
        assertEquals(NavGestureClassifier.Axis.NONE, c.axis)
        assertEquals(NavGestureClassifier.Outcome.None, c.up(542f, bottom - 3f, 60))
    }

    @Test
    fun downwardsIsIgnored() {
        val c = classifier()
        c.down(540f, 2300f, 0)
        c.drag(540f, 2300f, 545f, 2380f, 80)
        assertEquals(NavGestureClassifier.Axis.IGNORED, c.axis)
    }

    @Test
    fun theShadeOpensOnAFlickOrPastAThird() {
        assertTrue(shadeOpens(1f, 0.1, cancelled = false))
        assertTrue(shadeOpens(0f, 0.5, cancelled = false))
        assertFalse(shadeOpens(0f, 0.2, cancelled = false))
        assertFalse(shadeOpens(-1f, 0.8, cancelled = false))
        assertFalse(shadeOpens(1f, 0.8, cancelled = true))
    }
}
