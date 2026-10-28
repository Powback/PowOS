package dev.omalauncher.shell

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.util.Base64
import android.util.LruCache
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import kotlin.math.roundToInt

/**
 * A hosted widget's rendered view tree as compact data (docs/app-to-widget.md, slice B): texts with a role guess
 * (title / value / label), images as small cached refs (the PNG is fetched once by [image], never sent per update),
 * progress bars, list rows and click targets. The shell's `appwidgets.data` event. Bounds are [x, y, w, h] dp inside
 * the widget. Public View APIs only; main thread, after layout. (ViewTreeDump keeps the full recon detail - classes,
 * paddings, colors, OWL nodes - which a data reader doesn't want on every update.)
 */
internal class WidgetData {
    private val pngs =
        object : LruCache<String, ByteArray>(IMAGE_CACHE_BYTES) {
            override fun sizeOf(
                key: String,
                value: ByteArray,
            ) = value.size
        }

    /** The picture [ref] as a PNG data URL, or null once it's been forgotten. */
    fun image(ref: String): String? = pngs.get(ref)?.let { "data:image/png;base64," + Base64.encodeToString(it, Base64.NO_WRAP) }

    fun read(root: View): JSONObject {
        val r = Reader(root)
        r.walk(root, null)
        return r.result()
    }

    private inner class Reader(
        val root: View,
    ) {
        val d = root.resources.displayMetrics.density
        val rootLoc = IntArray(2).also { root.getLocationOnScreen(it) }
        val loc = IntArray(2)
        val texts = ArrayList<Triple<String, Double, JSONArray>>()
        val images = JSONArray()
        val progress = JSONArray()
        val lists = JSONArray()
        val targets = JSONArray()

        fun bounds(v: View): JSONArray {
            v.getLocationOnScreen(loc)
            return JSONArray(listOf(dp(loc[0] - rootLoc[0]), dp(loc[1] - rootLoc[1]), dp(v.width), dp(v.height)))
        }

        fun dp(px: Int) = (px / d * 10).roundToInt() / 10.0

        /** [row]: the texts of the list row being read (its strings), else null. */
        fun walk(
            v: View,
            row: MutableList<String>?,
        ) {
            if (v.visibility != View.VISIBLE || v.alpha <= 0.01f) return
            target(v)
            leaf(v)
            if (v is AdapterView<*>) return list(v)
            if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i), row)
        }

        fun target(v: View) {
            if (!v.hasOnClickListeners() || v === root || v.width <= 0 || v.height <= 0) return
            val label = (v.contentDescription?.toString() ?: (v as? TextView)?.text?.toString() ?: firstText(v)).orEmpty()
            targets.put(JSONObject().put("b", bounds(v)).put("label", label.take(80)))
        }

        fun leaf(v: View) {
            when (v) {
                is TextView -> text(v)
                is ImageView -> image(v)?.let { images.put(it) }
                is ProgressBar ->
                    progress.put(JSONObject().put("v", v.progress).put("max", v.max).put("indeterminate", v.isIndeterminate).put("b", bounds(v)))
            }
        }

        fun text(v: TextView) {
            val t = v.text?.toString()?.trim().orEmpty()
            if (t.isEmpty()) return
            texts.add(Triple(t.take(200), (v.textSize / v.resources.displayMetrics.scaledDensity * 10).roundToInt() / 10.0, bounds(v)))
        }

        fun list(v: AdapterView<*>) {
            val rows = JSONArray()
            for (i in 0 until v.childCount) {
                val cells = ArrayList<String>()
                walkRow(v.getChildAt(i), cells)
                if (cells.isNotEmpty()) rows.put(JSONArray(cells))
            }
            lists.put(JSONObject().put("b", bounds(v)).put("rows", rows))
        }

        /** A list row's texts (only; its widgets in the lists are rows, not the widget's own texts). */
        fun walkRow(
            v: View,
            into: MutableList<String>,
        ) {
            if (v.visibility != View.VISIBLE) return
            if (v is TextView) v.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let { into.add(it.take(200)) }
            if (v is ViewGroup) for (i in 0 until v.childCount) walkRow(v.getChildAt(i), into)
        }

        fun firstText(v: View): String? {
            if (v is TextView && !v.text.isNullOrBlank()) return v.text.toString().trim()
            if (v is ViewGroup) for (i in 0 until v.childCount) firstText(v.getChildAt(i))?.let { return it }
            return null
        }

        fun image(v: ImageView): JSONObject? {
            val ref = ref(v.drawable, v.width, v.height) ?: return null
            val o = JSONObject().put("ref", ref).put("b", bounds(v))
            v.contentDescription?.let { o.put("d", it.toString().take(80)) }
            return o
        }

        /** Roles: the biggest text is the value (when it has a digit) else the title; smaller ones before it titles, after it labels. */
        fun result(): JSONObject {
            val max = texts.maxOfOrNull { it.second } ?: 0.0
            val top = texts.indexOfFirst { it.second == max }
            val arr = JSONArray()
            texts.forEachIndexed { i, (t, size, b) ->
                val role =
                    when {
                        size == max && t.any(Char::isDigit) && t.length <= 14 -> "value"
                        size == max -> "title"
                        i < top -> "title"
                        else -> "label"
                    }
                arr.put(JSONObject().put("t", t).put("role", role).put("size", size).put("b", b))
            }
            return JSONObject()
                .put("w", dp(root.width)).put("h", dp(root.height))
                .put("texts", arr).put("images", images).put("progress", progress).put("lists", lists).put("targets", targets)
        }
    }

    /** A drawable as a cached PNG (at most [IMAGE_SIDE] px a side): its ref is a hash of the pixels, the same picture the same ref. */
    private fun ref(
        drawable: Drawable?,
        fallbackW: Int,
        fallbackH: Int,
    ): String? {
        if (drawable == null) return null
        val src = source(drawable, fallbackW, fallbackH) ?: return null
        return cache(src)
    }

    private fun cache(src: Bitmap): String? {
        val soft = if (src.config == Bitmap.Config.HARDWARE) src.copy(Bitmap.Config.ARGB_8888, false) else src
        if (soft == null) return null
        val scale = minOf(1f, IMAGE_SIDE.toFloat() / maxOf(soft.width, soft.height))
        val small = if (scale < 1f) scaled(soft, scale) else soft
        val px = IntArray(small.width * small.height).also { small.getPixels(it, 0, small.width, 0, 0, small.width, small.height) }
        val crc = CRC32().apply { update(java.nio.ByteBuffer.allocate(px.size * 4).also { b -> b.asIntBuffer().put(px) }.array()) }
        val ref = "img-%08x-%dx%d".format(crc.value, small.width, small.height)
        if (pngs.get(ref) == null) pngs.put(ref, ByteArrayOutputStream().also { small.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray())
        return ref
    }

    private fun scaled(
        b: Bitmap,
        scale: Float,
    ) = Bitmap.createScaledBitmap(b, (b.width * scale).roundToInt().coerceAtLeast(1), (b.height * scale).roundToInt().coerceAtLeast(1), true)

    private fun source(
        drawable: Drawable,
        fallbackW: Int,
        fallbackH: Int,
    ): Bitmap? {
        (drawable as? BitmapDrawable)?.bitmap?.takeIf { !it.isRecycled }?.let { return it }
        val w = drawable.intrinsicWidth.takeIf { it > 0 } ?: fallbackW
        val h = drawable.intrinsicHeight.takeIf { it > 0 } ?: fallbackH
        if (w <= 0 || h <= 0) return null
        return Bitmap.createBitmap(minOf(w, IMAGE_SIDE), minOf(h, IMAGE_SIDE), Bitmap.Config.ARGB_8888).also {
            val old = drawable.copyBounds()
            drawable.setBounds(0, 0, it.width, it.height)
            runCatching { drawable.draw(Canvas(it)) }
            drawable.bounds = old
        }
    }

    private companion object {
        const val IMAGE_SIDE = 64
        const val IMAGE_CACHE_BYTES = 2 * 1024 * 1024
    }
}
