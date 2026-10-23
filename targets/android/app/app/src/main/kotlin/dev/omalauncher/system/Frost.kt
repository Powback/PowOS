package dev.omalauncher.system

import android.app.WallpaperColors
import android.app.WallpaperManager
import android.content.Context
import android.graphics.Color
import androidx.compose.ui.graphics.toArgb
import dev.omalauncher.ui.Palette
import kotlin.math.cbrt
import kotlin.math.pow

/**
 * The frost (frost v2) for the chrome PowOS draws in Kotlin - the floating windows' title bars and grips
 * ([WindowFrame]): the same material as the shell's app pages and PowOS AI's cards (shell theme.css --frost-*,
 * shell.css's frost surfaces). The compositor's blur at [BLUR_DP], the theme's cool tint over a veil, a sheen from
 * above and a lit top edge. Over a wallpaper of the other tone it takes that tone, its text the theme's colours
 * swapped, as the page's surfaces do (glass.ts data-wallpaper; here the wallpaper's own colour hints say the tone).
 * Checked against the page (2026-10-23, CDP computed background of `.ai-screen .tile`): the same fill to 0.01.
 */
internal object Frost {
    /** --frost-blur-native: the compositor's radius for the frost (CSS px = dp). */
    const val BLUR_DP = 360f

    /** The layers, top first: [sheen] (a gradient to clear at 45%), [fill], [veil]; [edge] a 1 px line at the top. */
    data class Colors(
        val fill: Int,
        val veil: Int,
        val sheen: Int,
        val edge: Int,
        val ink: Int,
    )

    fun colors(context: Context): Colors {
        val p = Palette.current
        val bg = p.background.toArgb()
        val fg = p.foreground.toArgb()
        val light = p.isLight
        // theme.css: --glass-base = srgb mix(foreground 18%, background); --frost-cool by the theme's tone.
        val glassBase = srgbMix(fg, 0.18f, bg)
        val other = wallpaperTone(context)?.let { it != light } ?: false
        val base =
            when {
                // shell.css: over the other tone, the wallpaper's: mix(--frost-paper (the foreground) 70%, --frost-swap-cool).
                other -> oklabMix(fg, 0.7f, if (light) COOL_DARK else COOL_LIGHT)
                light -> oklabMix(glassBase, 0.55f, COOL_LIGHT)
                // A dark theme over a dark wallpaper: a touch lighter (shell.css), so the glass shows over pure black.
                else -> oklabMix(glassBase, 0.5f, oklabMix(COOL_DARK, 0.8f, fg))
            }
        // --glass-tint: 32% under html.glass-native (dark), 50% light; frost surfaces take 20% more.
        val tint = if (light) 0.50f else 0.32f
        val veil = if (other) Color.TRANSPARENT else if (light) Color.argb(20, 255, 255, 255) else Color.argb(51, 0, 0, 0)
        val ink = if (other) bg else fg
        return Colors(alpha(base, tint + 0.20f), veil, alpha(ink, 0.06f), Color.argb(18, 255, 255, 255), ink)
    }

    /** The wallpaper light (true) or dark (false) by its own colour hints; null when it can't be read. */
    private fun wallpaperTone(context: Context): Boolean? =
        runCatching {
            val c = context.getSystemService(WallpaperManager::class.java).getWallpaperColors(WallpaperManager.FLAG_SYSTEM) ?: return null
            c.colorHints and WallpaperColors.HINT_SUPPORTS_DARK_TEXT != 0
        }.getOrNull()

    private val COOL_LIGHT = Color.rgb(0xe8, 0xee, 0xf6)
    private val COOL_DARK = Color.rgb(0x18, 0x22, 0x30)

    private fun alpha(
        c: Int,
        a: Float,
    ) = Color.argb((a.coerceIn(0f, 1f) * 255).toInt(), Color.red(c), Color.green(c), Color.blue(c))

    /** CSS color-mix(in srgb, [a] [p], [b]). */
    private fun srgbMix(
        a: Int,
        p: Float,
        b: Int,
    ) = Color.rgb(mix(Color.red(a), p, Color.red(b)), mix(Color.green(a), p, Color.green(b)), mix(Color.blue(a), p, Color.blue(b)))

    private fun mix(
        a: Int,
        p: Float,
        b: Int,
    ) = (a * p + b * (1 - p)).toInt().coerceIn(0, 255)

    /** CSS color-mix(in oklab, [a] [p], [b]). */
    private fun oklabMix(
        a: Int,
        p: Float,
        b: Int,
    ): Int {
        val x = oklab(a)
        val y = oklab(b)
        return rgb(FloatArray(3) { x[it] * p + y[it] * (1 - p) })
    }

    private fun lin(c: Int): Float {
        val v = c / 255f
        return if (v <= 0.04045f) v / 12.92f else ((v + 0.055f) / 1.055f).pow(2.4f)
    }

    private fun unlin(v: Float): Int {
        val s = if (v <= 0.0031308f) 12.92f * v else 1.055f * v.pow(1 / 2.4f) - 0.055f
        return (s * 255 + 0.5f).toInt().coerceIn(0, 255)
    }

    private fun oklab(c: Int): FloatArray {
        val r = lin(Color.red(c))
        val g = lin(Color.green(c))
        val b = lin(Color.blue(c))
        val l = cbrt(0.4122214708f * r + 0.5363325363f * g + 0.0514459929f * b)
        val m = cbrt(0.2119034982f * r + 0.6806995451f * g + 0.1073969566f * b)
        val s = cbrt(0.0883024619f * r + 0.2817188376f * g + 0.6299787005f * b)
        return floatArrayOf(
            0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
            1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
            0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s,
        )
    }

    private fun rgb(o: FloatArray): Int {
        val l = (o[0] + 0.3963377774f * o[1] + 0.2158037573f * o[2]).pow(3)
        val m = (o[0] - 0.1055613458f * o[1] - 0.0638541728f * o[2]).pow(3)
        val s = (o[0] - 0.0894841775f * o[1] - 1.2914855480f * o[2]).pow(3)
        return Color.rgb(
            unlin(4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s),
            unlin(-1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s),
            unlin(-0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s),
        )
    }
}
