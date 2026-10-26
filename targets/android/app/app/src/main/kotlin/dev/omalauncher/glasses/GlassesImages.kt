package dev.omalauncher.glasses

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64

/**
 * A picture (PNG/JPEG bytes, or a data: URL as a page's canvas gives it) in the glasses' own format: decoded, scaled to
 * the model's canvas (as imageToGray4 / g1DisplayBitmap scaled), then [Raster]'s 4-bit greys (G2) or 1-bit BMP (G1).
 */
object GlassesImages {
    /** The bytes of a "data:image/png;base64,..." URL, or of plain base64. */
    fun bytesOf(data: String): ByteArray = Base64.decode(data.replaceFirst(Regex("^data:[^,]+,"), ""), Base64.DEFAULT)

    /** [encoded] for [model]; [dither]: G1 Floyd-Steinberg (the module's default) rather than a plain threshold. Null: not an image. */
    fun convert(
        encoded: ByteArray,
        model: GlassesModel,
        dither: Boolean = true,
    ): GlassesImage? {
        val decoded = BitmapFactory.decodeByteArray(encoded, 0, encoded.size) ?: return null
        val w = model.width
        val h = model.height
        val scaled = Bitmap.createScaledBitmap(decoded, w, h, true)
        // createScaledBitmap returns the same bitmap when the size already matches: recycled once.
        if (scaled !== decoded) decoded.recycle()
        val px = IntArray(w * h)
        scaled.getPixels(px, 0, w, 0, 0, w, h)
        scaled.recycle()
        return when (model) {
            GlassesModel.G2 -> GlassesImage.Gray4(w, h, Raster.gray4(px))
            GlassesModel.G1 -> GlassesImage.Bmp1(G1Protocol.bmp(if (dither) Raster.dither(px, w, h) else Raster.threshold(px), w, h))
        }
    }
}
