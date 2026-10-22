package dev.omalauncher.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.Drawable
import android.os.Build

/**
 * An app icon as an alpha-only silhouette, for tinting in one color (monochrome icons).
 * Prefers the adaptive icon's monochrome layer (Android's themed icons), then its
 * foreground layer (the logo without its backdrop), then the whole icon.
 */
fun iconMask(
    drawable: Drawable,
    size: Int,
): Bitmap {
    val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    val adaptive = drawable as? AdaptiveIconDrawable
    val mono = if (Build.VERSION.SDK_INT >= 33) adaptive?.monochrome else null
    val layer = mono ?: adaptive?.foreground
    if (layer != null) {
        // Adaptive layers are 108dp with a 72dp safe zone; scale so the safe zone fills the bitmap.
        val inset = size / 4
        layer.setBounds(-inset, -inset, size + inset, size + inset)
        layer.draw(canvas)
    } else {
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
    }
    // The monochrome layer is already a mask; anything else keeps its detail as brightness.
    if (mono == null) brightnessToAlpha(bmp)
    return bmp.extractAlpha().also { bmp.recycle() }
}

/** PowOS's one icon shape: a rounded square, its corners this much of the edge (the shell's --icon-radius). */
const val ICON_RADIUS = 0.22f

/**
 * [drawable] drawn [size] px square on [canvas]. An adaptive icon draws its own layers (background, foreground) in
 * PowOS's one shape ([ICON_RADIUS]) rather than the system's mask, so every app's icon has the same silhouette on every
 * surface (the shell's ui/iconshape.ts fits the rest to it); any other drawable as it is.
 */
fun drawShapedIcon(
    drawable: Drawable,
    canvas: Canvas,
    size: Int,
) {
    val adaptive = drawable as? AdaptiveIconDrawable
    if (adaptive == null) {
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        return
    }
    val s = size.toFloat()
    canvas.saveLayer(0f, 0f, s, s, null)
    // Layers are 108dp with the 72dp shown: scaled so the shown part fills the square.
    val inset = size / 4
    for (layer in listOfNotNull(adaptive.background, adaptive.foreground)) {
        layer.setBounds(-inset, -inset, size + inset, size + inset)
        layer.draw(canvas)
    }
    // Everything outside the rounded square cleared, its edge anti-aliased (a clipPath would leave it jagged).
    val outside = Path().apply {
        addRoundRect(0f, 0f, s, s, s * ICON_RADIUS, s * ICON_RADIUS, Path.Direction.CW)
        fillType = Path.FillType.INVERSE_WINDING
    }
    canvas.drawPath(outside, Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR) })
    canvas.restore()
}

/** Silhouette of a plain bitmap (Linux icons). */
fun bitmapMask(source: Bitmap): Bitmap {
    val bmp = source.copy(Bitmap.Config.ARGB_8888, true)
    brightnessToAlpha(bmp)
    return bmp.extractAlpha().also { bmp.recycle() }
}

/**
 * Bright pixels become opaque, dark ones transparent, scaled so the brightest part
 * is fully opaque: dark logos stay visible, and details survive as shades.
 */
private fun brightnessToAlpha(bmp: Bitmap) {
    val w = bmp.width
    val h = bmp.height
    val pixels = IntArray(w * h)
    bmp.getPixels(pixels, 0, w, 0, 0, w, h)
    var max = 1
    for (i in pixels.indices) {
        val p = pixels[i]
        val lum = (0.3 * ((p shr 16) and 0xff) + 0.59 * ((p shr 8) and 0xff) + 0.11 * (p and 0xff)).toInt()
        val v = (p ushr 24) * lum / 255
        pixels[i] = v
        if (v > max) max = v
    }
    for (i in pixels.indices) pixels[i] = ((pixels[i] * 255 / max) shl 24) or 0xffffff
    bmp.setPixels(pixels, 0, w, 0, 0, w, h)
}
