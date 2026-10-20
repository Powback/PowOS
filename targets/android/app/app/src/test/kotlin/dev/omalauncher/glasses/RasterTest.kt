package dev.omalauncher.glasses

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** imageToGray4's packing and the G1's dither, on plain pixel arrays. */
class RasterTest {
    private val white = 0xFFFFFFFF.toInt()
    private val black = 0xFF000000.toInt()
    private val grey = 0xFF808080.toInt()

    @Test fun luma() {
        assertEquals(255, Raster.luma(white))
        assertEquals(0, Raster.luma(black))
        assertEquals(76, Raster.luma(0xFFFF0000.toInt())) // 0.299 * 255
        assertEquals(149, Raster.luma(0xFF00FF00.toInt())) // 0.587 * 255
    }

    @Test fun gray4PacksTwoPixelsAByteHighNibbleFirst() {
        assertArrayEquals(byteArrayOf(0xF0.toByte()), Raster.gray4(intArrayOf(white, black)))
        assertArrayEquals(byteArrayOf(0x0F), Raster.gray4(intArrayOf(black, white)))
        // 128 * 15 / 255 = 7.
        assertArrayEquals(byteArrayOf(0x77), Raster.gray4(intArrayOf(grey, grey)))
        // An odd count: the last pixel alone in its byte's high nibble.
        assertArrayEquals(byteArrayOf(0xFF.toByte(), 0xF0.toByte()), Raster.gray4(intArrayOf(white, white, white)))
        // The G2 canvas: 576 x 288 -> 82944 bytes.
        assertEquals(576 * 288 / 2, Raster.gray4(IntArray(576 * 288) { black }).size)
    }

    @Test fun ditherKeepsBlackAndWhiteAndHalfToneGrey() {
        assertTrue(Raster.dither(IntArray(64) { white }, 8, 8).all { it })
        assertTrue(Raster.dither(IntArray(64) { black }, 8, 8).none { it })
        val lit = Raster.dither(IntArray(32 * 32) { grey }, 32, 32).count { it }
        assertTrue("about half lit: $lit", lit in 450..574)
        assertArrayEquals(booleanArrayOf(true, false), Raster.threshold(intArrayOf(white, black)))
    }
}
