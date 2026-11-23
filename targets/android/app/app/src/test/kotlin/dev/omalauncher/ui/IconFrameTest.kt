package dev.omalauncher.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** IconFrame: a tile inside a tile is unwrapped (the S25 double border); a real adaptive icon or a glyph is not. */
class IconFrameTest {
    private val n = 96
    private val clear = 0
    private val white = 0xffffffff.toInt()
    private val green = 0xff2e9e44.toInt()
    private val blue = 0xff1a5fd0.toInt()

    private fun canvas(fill: Int = clear) = IntArray(n * n) { fill }

    /** A rounded square at [x],[y] of side [s], corners [r] of the side, painted [c]. */
    private fun IntArray.roundRect(
        x: Int,
        y: Int,
        s: Int,
        c: Int,
        r: Float = 0.22f,
    ) = apply {
        val rad = s * r
        for (j in 0 until s) for (i in 0 until s) {
            val dx = maxOf(0f, maxOf(rad - (i + 0.5f), (i + 0.5f) - (s - rad)))
            val dy = maxOf(0f, maxOf(rad - (j + 0.5f), (j + 0.5f) - (s - rad)))
            if (dx * dx + dy * dy <= rad * rad) this[(y + j) * n + x + i] = c
        }
    }

    private fun IntArray.circle(
        cx: Float,
        cy: Float,
        r: Float,
        c: Int,
    ) = apply {
        for (j in 0 until n) for (i in 0 until n) {
            val dx = i + 0.5f - cx
            val dy = j + 0.5f - cy
            if (dx * dx + dy * dy <= r * r) this[j * n + i] = c
        }
    }

    @Test
    fun `a legacy tile on a plain white background layer is unwrapped`() {
        // One UI's wrap: the legacy icon (its own rounded square) at ~70% of the shown area, on a white plate.
        val fg = canvas().roundRect(14, 14, 68, green, 0.18f)
        val box = IconFrame.wrappedLayer(fg, canvas(white), n)
        assertNotNull(box)
        assertEquals(14, box!!.x)
        assertEquals(68, box.side)
    }

    @Test
    fun `a white glyph on the legacy tile still counts as one tile`() {
        val fg = canvas().roundRect(16, 16, 64, blue).circle(48f, 48f, 14f, white)
        assertNotNull(IconFrame.wrappedLayer(fg, canvas(white), n))
    }

    @Test
    fun `a real adaptive icon is left alone`() {
        // A round logo on a plain background (Chrome-like): a glyph, not a tile.
        assertNull(IconFrame.wrappedLayer(canvas().circle(48f, 48f, 30f, blue), canvas(white), n))
        // A full-bleed foreground: nothing inside a frame.
        assertNull(IconFrame.wrappedLayer(canvas(green), canvas(white), n))
        // A small square glyph: too small to be an icon of its own.
        assertNull(IconFrame.wrappedLayer(canvas().roundRect(36, 36, 24, green), canvas(white), n))
    }

    @Test
    fun `a tile on a background that is a picture is a real adaptive icon`() {
        val bg = IntArray(n * n) { i -> if ((i % n) < n / 2) blue else green }
        assertNull(IconFrame.wrappedLayer(canvas().roundRect(14, 14, 68, white), bg, n))
    }

    @Test
    fun `no background layer counts as plain`() {
        assertNotNull(IconFrame.wrappedLayer(canvas().roundRect(14, 14, 68, green), null, n))
    }

    @Test
    fun `a picture with a tile inside its own tile is unwrapped`() {
        val pic = canvas().roundRect(4, 4, 88, white).roundRect(18, 18, 60, green, 0.18f)
        val box = IconFrame.framedPicture(pic, n)
        assertNotNull(box)
        assertEquals(60, box!!.side)
    }

    @Test
    fun `a plain tile with a glyph inside is left alone`() {
        assertNull(IconFrame.framedPicture(canvas().roundRect(4, 4, 88, white).circle(48f, 48f, 26f, green), n))
        assertNull(IconFrame.framedPicture(canvas().roundRect(4, 4, 88, green), n))
        // An irregular picture (a round legacy icon): the shell's plate handles it.
        assertNull(IconFrame.framedPicture(canvas().circle(48f, 48f, 44f, white).roundRect(24, 24, 48, green), n))
    }
}
