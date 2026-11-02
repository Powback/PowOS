package dev.omalauncher.system

import org.junit.Assert.assertEquals
import org.junit.Test

/** The switcher's split card: how Android's split divides the screen, from its two tasks' corners (SplitDrawer.layoutOf). */
class SplitLayoutTest {
    @Test
    fun sideBySideOnTheUnfoldedScreen() {
        // Left half at x 0, right half at x 1220 (same top): side by side.
        assertEquals("2h", SplitDrawer.layoutOf(0, 0, 1220, 0))
    }

    @Test
    fun oneOverTheOtherOnTheFoldedScreen() {
        // Top half at y 0, bottom half at y 1250 (same left): one over the other.
        assertEquals("2v", SplitDrawer.layoutOf(0, 0, 0, 1250))
    }

    @Test
    fun anOffsetDividerStillReadsByTheLargerGap() {
        // A side's inset (the divider's few px) never flips it.
        assertEquals("2v", SplitDrawer.layoutOf(0, 0, 8, 900))
        assertEquals("2h", SplitDrawer.layoutOf(0, 0, 700, 12))
    }
}
