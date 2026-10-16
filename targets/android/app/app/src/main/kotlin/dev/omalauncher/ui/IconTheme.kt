package dev.omalauncher.ui

import android.graphics.Bitmap
import androidx.compose.ui.graphics.Color
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cbrt
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * App icons in the theme's colors: each theme's red, yellow, green, cyan, blue and magenta say how it renders those
 * hues - how saturated, how light, how far shifted - and icon pixels near a hue get the same treatment, interpolated
 * between the two nearest. A pastel theme gives pastel icons, a muted one muted icons, a gray one gray icons; a
 * canonical palette leaves them as they are.
 *
 * Works in OKLCH (perceptual lightness, chroma, hue). A theme slot's hue is only borrowed when it is near its own
 * hue: some themes fill the slots with other hues (hackerman's red is green, lumon's are all blue), which would
 * otherwise turn a red logo green; their saturation and lightness still apply. Gray pixels stay as they are.
 *
 * Baked once per theme into a [GRID]³ RGB table; recoloring an icon is one trilinear lookup per pixel.
 */
class IconTheme private constructor(
    private val lut: IntArray?,
) {
    /** The theme leaves icons as they are. */
    val identity get() = lut == null

    /** [src] in the theme's colors, as a new bitmap; [src] itself when [identity]. */
    fun recolor(src: Bitmap): Bitmap {
        val lut = lut ?: return src
        val w = src.width
        val h = src.height
        val px = IntArray(w * h)
        src.getPixels(px, 0, w, 0, 0, w, h)
        for (i in px.indices) {
            val c = px[i]
            val a = c ushr 24
            if (a == 0) continue
            px[i] = (a shl 24) or lookup(lut, (c shr 16) and 0xff, (c shr 8) and 0xff, c and 0xff)
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    companion object {
        private const val GRID = 33
        private const val STEP = 255f / (GRID - 1)

        /** How strongly the theme's lightness carries over (all of it makes every blue the theme's one blue). */
        private const val LIGHTNESS = 0.6f

        /** A slot's hue counts only within this of its anchor's, in degrees. */
        private const val HUE_REACH = 45f

        /** Chroma below which a pixel is gray and stays; fully themed above [GRAY_TO]. */
        private const val GRAY = 0.02f
        private const val GRAY_TO = 0.05f

        /** The six hues, as theme slot names and their canonical sRGB colors. */
        private val ANCHORS =
            listOf(
                "red" to 0xff0000,
                "yellow" to 0xffff00,
                "green" to 0x00ff00,
                "cyan" to 0x00ffff,
                "blue" to 0x0000ff,
                "magenta" to 0xff00ff,
            )

        private var cached: Pair<Map<String, Color>, IconTheme>? = null

        /** The icon treatment of the palette [named] (Palette.current.named); the last one is kept. */
        @Synchronized
        fun of(named: Map<String, Color>): IconTheme {
            cached?.let { (key, theme) -> if (key == named) return theme }
            return build(named).also { cached = named to it }
        }

        private class Anchor(
            val l: Float,
            val c: Float,
            val h: Float,
            val chromaRatio: Float,
            val dL: Float,
            val dH: Float,
        )

        private fun build(named: Map<String, Color>): IconTheme {
            val anchors =
                ANCHORS.map { (name, rgb) ->
                    val a = oklch(rgb shr 16 and 0xff, rgb shr 8 and 0xff, rgb and 0xff)
                    val slot = named[name] ?: (if (name == "magenta") named["purple"] else null)
                    if (slot == null) {
                        Anchor(a[0], a[1], a[2], 1f, 0f, 0f)
                    } else {
                        val t = oklch((slot.red * 255).toInt(), (slot.green * 255).toInt(), (slot.blue * 255).toInt())
                        val dH = hueDelta(a[2], t[2])
                        Anchor(a[0], a[1], a[2], (t[1] / a[1]).coerceIn(0f, 1.2f), t[0] - a[0], if (abs(dH) <= HUE_REACH && t[1] > GRAY) dH else 0f)
                    }
                }.sortedBy { it.h }
            if (anchors.all { abs(it.chromaRatio - 1) < 0.05f && abs(it.dL) < 0.02f && abs(it.dH) < 2f }) return IconTheme(null)
            val lut = IntArray(GRID * GRID * GRID)
            var i = 0
            for (r in 0 until GRID) for (g in 0 until GRID) for (b in 0 until GRID) {
                lut[i++] = map(anchors, (r * STEP).toInt(), (g * STEP).toInt(), (b * STEP).toInt())
            }
            return IconTheme(lut)
        }

        /** One color through the theme's treatment. */
        private fun map(
            anchors: List<Anchor>,
            r: Int,
            g: Int,
            b: Int,
        ): Int {
            val (l, c, h) = oklch(r, g, b).let { Triple(it[0], it[1], it[2]) }
            if (c < GRAY) return (r shl 16) or (g shl 8) or b
            // The anchors on either side of h, wrapping around 360°.
            var hi = anchors.indexOfFirst { it.h >= h }
            if (hi == -1) hi = 0
            val lo = (hi - 1 + anchors.size) % anchors.size
            val a0 = anchors[lo]
            val a1 = anchors[hi]
            val span = ((a1.h - a0.h) + 360f) % 360f
            val t = if (span == 0f) 0f else ((((h - a0.h) + 360f) % 360f) / span).coerceIn(0f, 1f)
            fun lerp(x: Float, y: Float) = x + (y - x) * t
            val ratio = lerp(a0.chromaRatio, a1.chromaRatio)
            val anchorC = lerp(a0.c, a1.c)
            val nc = c * ratio
            val nl = (l + lerp(a0.dL, a1.dL) * min(1f, c / anchorC) * LIGHTNESS).coerceIn(0f, 1f)
            val nh = h + lerp(a0.dH, a1.dH)
            // Grays and near-grays fade into the treatment, so soft shading doesn't band.
            val w = ((c - GRAY) / (GRAY_TO - GRAY)).coerceIn(0f, 1f)
            val out = toSrgb(l + (nl - l) * w, c + (nc - c) * w, if (w < 1f) h + (nh - h) * w else nh)
            return out
        }

        private fun hueDelta(
            from: Float,
            to: Float,
        ): Float {
            var d = to - from
            while (d > 180f) d -= 360f
            while (d < -180f) d += 360f
            return d
        }

        private fun lookup(
            lut: IntArray,
            r: Int,
            g: Int,
            b: Int,
        ): Int {
            val fr = r / STEP
            val fg = g / STEP
            val fb = b / STEP
            val r0 = min(fr.toInt(), GRID - 2)
            val g0 = min(fg.toInt(), GRID - 2)
            val b0 = min(fb.toInt(), GRID - 2)
            val tr = fr - r0
            val tg = fg - g0
            val tb = fb - b0
            var or = 0f
            var og = 0f
            var ob = 0f
            for (dr in 0..1) for (dg in 0..1) for (db in 0..1) {
                val w = (if (dr == 1) tr else 1 - tr) * (if (dg == 1) tg else 1 - tg) * (if (db == 1) tb else 1 - tb)
                if (w == 0f) continue
                val v = lut[((r0 + dr) * GRID + (g0 + dg)) * GRID + (b0 + db)]
                or += w * (v shr 16 and 0xff)
                og += w * (v shr 8 and 0xff)
                ob += w * (v and 0xff)
            }
            return ((or + 0.5f).toInt() shl 16) or ((og + 0.5f).toInt() shl 8) or (ob + 0.5f).toInt()
        }

        private fun linear(c: Int): Float {
            val v = c / 255f
            return if (v <= 0.04045f) v / 12.92f else ((v + 0.055f) / 1.055f).pow(2.4f)
        }

        private fun gamma(v: Float): Int {
            val c = if (v <= 0.0031308f) v * 12.92f else 1.055f * v.pow(1 / 2.4f) - 0.055f
            return (c * 255f + 0.5f).toInt().coerceIn(0, 255)
        }

        /** sRGB 0..255 to OKLCH: lightness 0..1, chroma, hue in degrees. */
        private fun oklch(
            r8: Int,
            g8: Int,
            b8: Int,
        ): FloatArray {
            val r = linear(r8)
            val g = linear(g8)
            val b = linear(b8)
            val l = cbrt(0.4122214708f * r + 0.5363325363f * g + 0.0514459929f * b)
            val m = cbrt(0.2119034982f * r + 0.6806995451f * g + 0.1073969566f * b)
            val s = cbrt(0.0883024619f * r + 0.2817188376f * g + 0.6299787005f * b)
            val okL = 0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s
            val okA = 1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s
            val okB = 0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s
            val h = Math.toDegrees(atan2(okB, okA).toDouble()).toFloat().let { if (it < 0) it + 360f else it }
            return floatArrayOf(okL, hypot(okA, okB), h)
        }

        /** OKLCH to linear sRGB; null outside the sRGB gamut. */
        private fun linearRgb(
            l: Float,
            c: Float,
            hDeg: Float,
        ): FloatArray {
            val h = Math.toRadians(hDeg.toDouble())
            val a = c * cos(h).toFloat()
            val b = c * sin(h).toFloat()
            val l_ = (l + 0.3963377774f * a + 0.2158037573f * b).let { it * it * it }
            val m_ = (l - 0.1055613458f * a - 0.0638541728f * b).let { it * it * it }
            val s_ = (l - 0.0894841775f * a - 1.2914855480f * b).let { it * it * it }
            return floatArrayOf(
                4.0767416621f * l_ - 3.3077115913f * m_ + 0.2309699292f * s_,
                -1.2684380046f * l_ + 2.6097574011f * m_ - 0.3413193965f * s_,
                -0.0041960863f * l_ - 0.7034186147f * m_ + 1.7076147010f * s_,
            )
        }

        /** OKLCH to packed sRGB, lowering chroma until it fits the gamut (keeps lightness and hue). */
        private fun toSrgb(
            l: Float,
            c: Float,
            h: Float,
        ): Int {
            fun fits(v: FloatArray) = v.all { it in -0.0005f..1.0005f }
            var rgb = linearRgb(l, c, h)
            if (!fits(rgb)) {
                var lo = 0f
                var hi = c
                repeat(12) {
                    val mid = (lo + hi) / 2
                    if (fits(linearRgb(l, mid, h))) lo = mid else hi = mid
                }
                rgb = linearRgb(l, lo, h)
            }
            return (gamma(rgb[0].coerceIn(0f, 1f)) shl 16) or (gamma(rgb[1].coerceIn(0f, 1f)) shl 8) or gamma(rgb[2].coerceIn(0f, 1f))
        }
    }
}
