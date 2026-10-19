package dev.omalauncher.widgets.recon

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import java.io.File
import java.nio.ByteBuffer
import java.util.zip.CRC32

/**
 * The images a recon finds (bitmaps in RemoteViews, drawables in the view tree), as images/<n>.png in its
 * folder, each distinct picture once. Collected on the main thread, written by [write] off it.
 */
internal class Images(
    private val context: Context,
) {
    private val byHash = HashMap<Long, String>()
    private val pending = ArrayList<Pair<String, Bitmap>>()

    /** A path relative to the recon folder, or null for nothing to draw. */
    fun bitmap(source: Bitmap?): String? {
        if (source == null || source.isRecycled || source.width <= 0 || source.height <= 0) return null
        val bmp = scaled(if (source.config == Bitmap.Config.HARDWARE) source.copy(Bitmap.Config.ARGB_8888, false) else source)
        val hash = hash(bmp)
        byHash[hash]?.let { return it }
        val path = "images/${byHash.size + 1}.png"
        byHash[hash] = path
        // A copy: the provider's bitmap may be reused or recycled before it's written.
        pending += path to if (bmp === source) source.copy(Bitmap.Config.ARGB_8888, false) else bmp
        return path
    }

    /** [d] at its own size, or [fallbackW] x [fallbackH] px when it has none (colors, shapes). */
    fun drawable(
        d: Drawable?,
        fallbackW: Int,
        fallbackH: Int,
    ): String? {
        if (d == null) return null
        if (d is BitmapDrawable) return bitmap(d.bitmap)
        val w = d.intrinsicWidth.takeIf { it > 0 } ?: fallbackW
        val h = d.intrinsicHeight.takeIf { it > 0 } ?: fallbackH
        if (w <= 0 || h <= 0) return null
        val bmp = Bitmap.createBitmap(minOf(w, MAX_SIDE), minOf(h, MAX_SIDE), Bitmap.Config.ARGB_8888)
        val oldBounds = d.copyBounds()
        d.setBounds(0, 0, bmp.width, bmp.height)
        runCatching { d.draw(Canvas(bmp)) }
        d.bounds = oldBounds
        return bitmap(bmp)
    }

    /** A whole frame (the screenshot, previews) as [name] in the recon folder. */
    fun save(
        frame: Bitmap,
        name: String,
    ) {
        pending += name to frame
    }

    fun icon(icon: Icon?): String? = icon?.let { runCatching { drawable(it.loadDrawable(context), 96, 96) }.getOrNull() }

    /** Writes what was collected under [dir]. IO thread. */
    fun write(dir: File) {
        for ((path, bmp) in pending) {
            val f = File(dir, path)
            f.parentFile?.mkdirs()
            f.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        pending.clear()
    }

    private fun scaled(b: Bitmap): Bitmap {
        val side = maxOf(b.width, b.height)
        if (side <= MAX_SIDE) return b
        val k = MAX_SIDE.toFloat() / side
        return Bitmap.createScaledBitmap(b, maxOf(1, (b.width * k).toInt()), maxOf(1, (b.height * k).toInt()), true)
    }

    private fun hash(b: Bitmap): Long {
        val buf = ByteBuffer.allocate(b.byteCount)
        b.copyPixelsToBuffer(buf)
        return CRC32().apply {
            update(buf.array())
            update(b.width)
            update(b.height)
        }.value
    }

    private companion object {
        /** Widgets' pictures are small; a wallpaper-sized one is cut down to this. */
        const val MAX_SIDE = 1024
    }
}
