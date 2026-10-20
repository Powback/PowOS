package dev.omalauncher.glasses

/**
 * Pixels for the glasses' displays, on plain ARGB arrays (JVM-tested, RasterTest): the G2's packed 4-bit greyscale
 * (imageToGray4) and the G1's 1-bit Floyd-Steinberg dither (applyFloydSteinbergDithering), as the user's modules did
 * them - the Bitmap decode/scale around them is GlassesImages.kt's.
 */
object Raster {
    /** BT.601 luma of an ARGB pixel, 0-255 (alpha ignored, as the module did). */
    fun luma(argb: Int): Int {
        val r = (argb shr 16) and 0xFF
        val g = (argb shr 8) and 0xFF
        val b = argb and 0xFF
        return (0.299f * r + 0.587f * g + 0.114f * b).toInt()
    }

    /** [argb] (w*h, row-major) as 4-bit greyscale, two pixels a byte: the even pixel in the high nibble. */
    fun gray4(argb: IntArray): ByteArray {
        val out = ByteArray((argb.size + 1) / 2)
        for (i in argb.indices) {
            val nibble = luma(argb[i]) * 15 / 255
            val at = i / 2
            out[at] = if (i and 1 == 0) (nibble shl 4).toByte() else (out[at].toInt() or (nibble and 0x0F)).toByte()
        }
        return out
    }

    /** [argb] dithered to black and white (Floyd-Steinberg on luma, threshold 127): true = white (lit). */
    fun dither(
        argb: IntArray,
        width: Int,
        height: Int,
    ): BooleanArray {
        val err = IntArray(argb.size) { luma(argb[it]) }
        val out = BooleanArray(argb.size)
        for (y in 0 until height) {
            for (x in 0 until width) {
                val i = y * width + x
                val old = err[i].coerceIn(0, 255)
                val white = old > 127
                val e = old - if (white) 255 else 0
                out[i] = white
                if (x + 1 < width) err[i + 1] += e * 7 / 16
                if (y + 1 < height) {
                    if (x > 0) err[i + width - 1] += e * 3 / 16
                    err[i + width] += e * 5 / 16
                    if (x + 1 < width) err[i + width + 1] += e / 16
                }
            }
        }
        return out
    }

    /** [argb] thresholded at 127 (no dither: text stays crisp). */
    fun threshold(argb: IntArray) = BooleanArray(argb.size) { luma(argb[it]) > 127 }
}
