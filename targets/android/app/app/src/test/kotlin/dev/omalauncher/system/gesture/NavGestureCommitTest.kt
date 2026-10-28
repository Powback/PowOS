package dev.omalauncher.system.gesture

import org.junit.Assert.assertEquals
import org.junit.Test

/** The switcher's commit: distance OR upward speed OR a hold; only a short, slow release aborts. */
class NavGestureCommitTest {
    private val density = 2.5f
    private val bottom = 2390f

    private fun release(
        travel: Float,
        ms: Long,
    ): NavGestureClassifier.Outcome {
        val c = NavGestureClassifier(density, 2400f)
        c.down(540f, bottom, 0)
        var t = 0L
        while (t < ms) {
            t += 8
            c.move(540f, bottom - travel * t / ms, t)
        }
        return c.up(540f, bottom - travel, t + 8)
    }

    @Test
    fun aFastShortFlickUpCommitsTheSwitcher() = assertEquals(NavGestureClassifier.Outcome.Switcher, release(70f, 64))

    @Test
    fun aShortSlowReleaseStillAborts() = assertEquals(NavGestureClassifier.Outcome.None, release(60f, 400))

    @Test
    fun aMeaningfulSlowTravelCommits() = assertEquals(NavGestureClassifier.Outcome.Switcher, release(200f, 600))
}
