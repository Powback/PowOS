package dev.omalauncher.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The recording light's camera on the status strip (rec-light 11-11: the inner screen, the camera app had turned it
 * landscape, showed the dot - the strip window was told of no cutout). OnePlus Open: inner 2268x2440, its camera hole
 * [2142,2268) x [0,126) upright; cover 1116 wide, hole [521,595) x [0,126); strip 126 px.
 */
class CameraCutoutTest {
    private val inner = BarRect(2142, 0, 2268, 126)

    @Test
    fun theWindowsOwnCutoutFirst() {
        assertEquals(inner, CameraCutout.onStrip(listOf(inner), listOf(inner), 126))
        val cover = BarRect(521, 0, 595, 126)
        assertEquals(cover, CameraCutout.onStrip(listOf(BarRect(0, 0, 0, 0), cover), emptyList(), 126))
    }

    @Test
    fun theDisplaysWhenTheWindowWasToldNone() {
        val turned = BarRect(0, 0, 126, 126)
        assertEquals(turned, CameraCutout.onStrip(emptyList(), listOf(turned), 126))
    }

    @Test
    fun aCameraOffTheStripIsNoRing() {
        // Turned so the hole is on the bottom edge: the strip can't ring it - the dot, never a ring drawn off the strip.
        val bottom = BarRect(2314, 2142, 2440, 2268)
        assertNull(CameraCutout.onStrip(listOf(bottom), listOf(bottom), 126))
        assertNull(CameraCutout.onStrip(emptyList(), emptyList(), 126))
    }

    @Test
    fun theTopOneBeforeASmallerSideOne() {
        val side = BarRect(0, 60, 20, 100)
        assertEquals(inner, CameraCutout.onStrip(listOf(side, inner), emptyList(), 126))
    }
}
