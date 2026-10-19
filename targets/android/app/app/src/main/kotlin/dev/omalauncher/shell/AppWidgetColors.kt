package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.content.Context
import android.util.SparseIntArray
import kotlin.math.atan2
import kotlin.math.cbrt
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The system palette Android widgets draw with, made from PowOS's theme (for AppWidgetHostView.setColorResources), as
 * a Pixel launcher gives widgets the wallpaper's: five tonal palettes of 13 shades each (system_accent1_0 ..
 * system_neutral2_1000: shade 0 is white, 1000 black) and, on Android 14+, the Material tokens made from them
 * (system_primary_light, system_surface_container_dark, ...).
 *
 * Each palette is one hue and chroma at the shades' Material tones (L* in CIELAB, which is HCT's tone), its chroma
 * lowered where sRGB can't show it: accent1 is the theme's accent, accent2 the same hue quieter, accent3 the theme's
 * magenta (else the accent turned 60 degrees), the neutrals the background's hue nearly grey. Then the shades and
 * tokens widgets use for their background, text and highlight in the theme's light or dark are its own colors
 * exactly, so a widget's card is PowOS's surface and its text PowOS's foreground.
 */
internal object WidgetColors {
    /** The shades Android names, and their Material tones. */
    private val SHADES = intArrayOf(0, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000)
    private val TONES = doubleArrayOf(100.0, 99.0, 95.0, 90.0, 80.0, 70.0, 60.0, 50.0, 40.0, 30.0, 20.0, 10.0, 0.0)

    private class Ramp(
        val hue: Double,
        val chroma: Double,
    ) {
        fun tone(t: Double) = fromLch(t, chroma, hue)
    }

    /** Android 14's Material tokens: (name, palette, tone in light, tone in dark). */
    private val TOKENS =
        listOf(
            Token("primary", "accent1", 40, 80),
            Token("on_primary", "accent1", 100, 20),
            Token("primary_container", "accent1", 90, 30),
            Token("on_primary_container", "accent1", 10, 90),
            Token("secondary", "accent2", 40, 80),
            Token("on_secondary", "accent2", 100, 20),
            Token("secondary_container", "accent2", 90, 30),
            Token("on_secondary_container", "accent2", 10, 90),
            Token("tertiary", "accent3", 40, 80),
            Token("on_tertiary", "accent3", 100, 20),
            Token("tertiary_container", "accent3", 90, 30),
            Token("on_tertiary_container", "accent3", 10, 90),
            Token("background", "neutral1", 98, 6),
            Token("on_background", "neutral1", 10, 90),
            Token("surface", "neutral1", 98, 6),
            Token("on_surface", "neutral1", 10, 90),
            Token("surface_variant", "neutral2", 90, 30),
            Token("on_surface_variant", "neutral2", 30, 80),
            Token("outline", "neutral2", 50, 60),
            Token("outline_variant", "neutral2", 80, 30),
            Token("surface_bright", "neutral1", 98, 24),
            Token("surface_dim", "neutral1", 87, 6),
            Token("surface_container", "neutral1", 94, 12),
            Token("surface_container_low", "neutral1", 96, 10),
            Token("surface_container_lowest", "neutral1", 100, 4),
            Token("surface_container_high", "neutral1", 92, 17),
            Token("surface_container_highest", "neutral1", 90, 22),
        )

    private class Token(
        val name: String,
        val palette: String,
        val light: Int,
        val dark: Int,
    )

    @SuppressLint("DiscouragedApi") // The names, not R constants: the Material tokens are Android 14+ only.
    fun build(
        context: Context,
        background: Int,
        surface: Int,
        foreground: Int,
        muted: Int,
        accent: Int,
        border: Int,
        magenta: Int?,
        light: Boolean,
    ): SparseIntArray {
        val res = context.resources
        fun id(name: String) = res.getIdentifier(name, "color", "android")
        val a = lch(accent)
        val n = lch(background)
        val ramps =
            mapOf(
                "accent1" to Ramp(a[2], a[1].coerceIn(16.0, 60.0)),
                "accent2" to Ramp(a[2], (a[1] / 3).coerceIn(8.0, 24.0)),
                "accent3" to (magenta?.let { lch(it) }?.let { Ramp(it[2], it[1].coerceIn(16.0, 48.0)) } ?: Ramp((a[2] + 60) % 360, 24.0)),
                "neutral1" to Ramp(n[2], n[1].coerceIn(2.0, 8.0)),
                "neutral2" to Ramp(n[2], (n[1] * 2).coerceIn(4.0, 16.0)),
            )
        val out = SparseIntArray()
        for ((name, ramp) in ramps) for (i in SHADES.indices) id("system_${name}_${SHADES[i]}").takeIf { it != 0 }?.let { out.put(it, ramp.tone(TONES[i])) }
        for (t in TOKENS) {
            val ramp = ramps.getValue(t.palette)
            id("system_${t.name}_light").takeIf { it != 0 }?.let { out.put(it, ramp.tone(t.light.toDouble())) }
            id("system_${t.name}_dark").takeIf { it != 0 }?.let { out.put(it, ramp.tone(t.dark.toDouble())) }
        }
        // The theme's own colors where widgets put their card, text and highlight, in its light or dark.
        val side = if (light) "light" else "dark"
        val exact =
            if (light) {
                mapOf("system_neutral1_50" to background, "system_neutral1_100" to surface, "system_neutral1_900" to foreground, "system_neutral2_700" to muted, "system_accent1_600" to accent)
            } else {
                mapOf("system_neutral1_900" to background, "system_neutral1_800" to surface, "system_neutral1_100" to foreground, "system_neutral2_200" to muted, "system_accent1_200" to accent)
            } +
                mapOf(
                    "system_background_$side" to background,
                    "system_surface_$side" to background,
                    "system_surface_container_$side" to surface,
                    "system_on_background_$side" to foreground,
                    "system_on_surface_$side" to foreground,
                    "system_on_surface_variant_$side" to muted,
                    "system_outline_$side" to border,
                    "system_primary_$side" to accent,
                )
        for ((name, color) in exact) id(name).takeIf { it != 0 }?.let { out.put(it, color or (0xff shl 24)) }
        return out
    }

    // CIELAB / LCh (D65), sRGB.

    private fun lin(c: Double) = if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)

    private fun gamma(c: Double) = if (c <= 0.0031308) 12.92 * c else 1.055 * c.pow(1 / 2.4) - 0.055

    private const val E = 216.0 / 24389
    private const val K = 24389.0 / 27

    private fun f(t: Double) = if (t > E) cbrt(t) else (K * t + 16) / 116

    /** [L, C, h] of an ARGB color. */
    private fun lch(argb: Int): DoubleArray {
        val r = lin((argb shr 16 and 0xff) / 255.0)
        val g = lin((argb shr 8 and 0xff) / 255.0)
        val b = lin((argb and 0xff) / 255.0)
        val x = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047)
        val y = f(0.2126 * r + 0.7152 * g + 0.0722 * b)
        val z = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883)
        val l = 116 * y - 16
        val aa = 500 * (x - y)
        val bb = 200 * (y - z)
        return doubleArrayOf(l, hypot(aa, bb), (Math.toDegrees(atan2(bb, aa)) + 360) % 360)
    }

    /** The color at tone [l], hue [h] and as much of chroma [c] as sRGB shows; opaque ARGB. */
    private fun fromLch(
        l: Double,
        c: Double,
        h: Double,
    ): Int {
        rgb(l, c, h)?.let { return it }
        var lo = 0.0
        var hi = c
        repeat(16) {
            val mid = (lo + hi) / 2
            if (rgb(l, mid, h) != null) lo = mid else hi = mid
        }
        return rgb(l, lo, h) ?: rgb(l, 0.0, h)!!
    }

    private fun rgb(
        l: Double,
        c: Double,
        h: Double,
    ): Int? {
        val rad = Math.toRadians(h)
        val fy = (l + 16) / 116
        val fx = fy + c * cos(rad) / 500
        val fz = fy - c * sin(rad) / 200
        fun inv(t: Double) = if (t * t * t > E) t * t * t else (116 * t - 16) / K
        val x = 0.95047 * inv(fx)
        val y = if (l > K * E) fy * fy * fy else l / K
        val z = 1.08883 * inv(fz)
        val r = 3.2406 * x - 1.5372 * y - 0.4986 * z
        val g = -0.9689 * x + 1.8758 * y + 0.0415 * z
        val b = 0.0557 * x - 0.2040 * y + 1.0570 * z
        if (listOf(r, g, b).any { it < -0.0005 || it > 1.0005 }) return null
        fun byte(v: Double) = (gamma(v.coerceIn(0.0, 1.0)) * 255).roundToInt().coerceIn(0, 255)
        return (0xff shl 24) or (byte(r) shl 16) or (byte(g) shl 8) or byte(b)
    }
}
