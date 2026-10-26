package dev.omalauncher.system.gesture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PanelPullTest {
    // The folded screen: 2376 px tall, --drop 15% = 356 px.
    private val h = 2376f

    @Test fun fullAfterTwoThirdsOfTheDrop() {
        assertEquals(1f, PanelPull.openness(h * 0.10f, h), 0.001f)
        assertEquals(0.5f, PanelPull.openness(h * 0.05f, h), 0.001f)
        assertEquals(0f, PanelPull.openness(-50f, h), 0f)
    }

    @Test fun opensPastFifteenPercent() {
        assertTrue(PanelPull.opens(0f, 0.2, cancelled = false))
        assertFalse(PanelPull.opens(0f, 0.1, cancelled = false))
    }

    @Test fun flicksDecide() {
        assertTrue(PanelPull.opens(0.5f, 0.05, cancelled = false))
        assertFalse(PanelPull.opens(-0.5f, 0.9, cancelled = false))
        assertTrue(PanelPull.opens(0.25f, 0.05, cancelled = false, openFlick = PanelPull.OPEN_FLICK))
        assertFalse(PanelPull.opens(1f, 0.9, cancelled = true))
    }
}
