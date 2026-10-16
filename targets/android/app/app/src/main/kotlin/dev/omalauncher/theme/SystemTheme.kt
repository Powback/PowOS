package dev.omalauncher.theme

import android.util.Log
import androidx.compose.ui.graphics.Color
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.ui.ThemePalette

/**
 * PowOS rooted mode: the launcher's theme is the whole phone's - the PowOS desktop's KDE color scheme and Android's
 * own (Material You palette from the theme's accent, dark or light mode from the theme). Style.SYSTEM_THEME turns it
 * off. Runs commands, so call it off the main thread.
 */
object SystemTheme {
    private const val TAG = "SystemTheme"

    /** What [apply] would set for [p]: the same key, nothing to do. */
    fun key(p: ThemePalette) = kdeColors(p) + hex(p.accent) + p.isLight

    /** Whether the PowOS desktop took it (it may not be running yet; then again later). */
    fun apply(p: ThemePalette): Boolean {
        runCatching { applyAndroid(p) }.onFailure { Log.w(TAG, "Android colors", it) }
        return runCatching { applyKde(p) }.onFailure { Log.w(TAG, "PowOS colors", it) }.getOrDefault(false)
    }

    private fun rgb(c: Color) = "${(c.red * 255).toInt()},${(c.green * 255).toInt()},${(c.blue * 255).toInt()}"

    private fun hex(c: Color) = "%02X%02X%02X".format((c.red * 255).toInt(), (c.green * 255).toInt(), (c.blue * 255).toInt())

    /** A KDE .colors scheme from the palette (as Omarchy's themes map onto apps: background, foreground, accent...). */
    fun kdeColors(p: ThemePalette): String {
        fun n(name: String, fallback: Color) = p.named[name] ?: fallback
        val bg = p.background
        val alt = p.surface
        val view = n("dark_background", bg)
        val fg = p.foreground
        val inactive = p.muted
        val accent = p.accent
        val negative = p.red
        val positive = p.green
        val neutral = n("yellow", accent)
        val link = n("blue", accent)
        val visited = n("magenta", n("purple", link))
        fun group(name: String, back: Color, backAlt: Color, front: Color = fg) =
            """
            [Colors:$name]
            BackgroundAlternate=${rgb(backAlt)}
            BackgroundNormal=${rgb(back)}
            DecorationFocus=${rgb(accent)}
            DecorationHover=${rgb(accent)}
            ForegroundActive=${rgb(accent)}
            ForegroundInactive=${rgb(inactive)}
            ForegroundLink=${rgb(link)}
            ForegroundNegative=${rgb(negative)}
            ForegroundNeutral=${rgb(neutral)}
            ForegroundNormal=${rgb(front)}
            ForegroundPositive=${rgb(positive)}
            ForegroundVisited=${rgb(visited)}
            """.trimIndent()
        return listOf(
            "[General]\nColorScheme=PowOSLauncher\nName=PowOS Launcher\nshadeSortColumn=true",
            "[KDE]\ncontrast=4",
            group("Window", bg, alt),
            group("View", view, bg),
            group("Button", alt, bg),
            group("Header", bg, alt),
            group("Tooltip", alt, bg),
            group("Complementary", view, bg),
            group("Selection", accent, accent, bg),
            "[WM]\nactiveBackground=${rgb(bg)}\nactiveForeground=${rgb(fg)}\ninactiveBackground=${rgb(bg)}\ninactiveForeground=${rgb(inactive)}",
        ).joinToString("\n\n") + "\n"
    }

    /**
     * Writes the scheme into the PowOS user's color-schemes and applies it. plasma-apply-colorscheme does nothing for
     * the scheme already active, so the scheme alternates between two names.
     */
    private fun applyKde(p: ThemePalette): Boolean {
        val d = "\$HOME/.local/share/color-schemes"
        val script =
            listOf(
                "mkdir -p \"$d\"",
                "cur=\$(kreadconfig6 --group General --key ColorScheme 2>/dev/null)",
                "n=PowOSLauncherA; [ \"\$cur\" = PowOSLauncherA ] && n=PowOSLauncherB",
                "cat > \"$d/\$n.colors\" <<'POWOS_EOF'",
                kdeColors(p).replace("ColorScheme=PowOSLauncher", "ColorScheme=__NAME__").trimEnd(),
                "POWOS_EOF",
                "sed -i \"s/__NAME__/\$n/\" \"$d/\$n.colors\"",
                "plasma-apply-colorscheme \"\$n\"",
            ).joinToString("\n")
        val code = RootedGuest.run(script) { Log.i(TAG, it) }
        Log.i(TAG, "PowOS colors: exit $code")
        return code == 0
    }

    /** Android's Material You palette (theme_customization_overlay_packages, as the wallpaper picker sets it) and dark mode. */
    private fun applyAndroid(p: ThemePalette) {
        val json =
            "{\"android.theme.customization.system_palette\":\"${hex(p.accent)}\"," +
                "\"android.theme.customization.accent_color\":\"${hex(p.accent)}\"," +
                "\"android.theme.customization.theme_style\":\"TONAL_SPOT\"," +
                "\"android.theme.customization.color_source\":\"preset\"," +
                "\"_applied_timestamp\":${System.currentTimeMillis()}}"
        val cmd = "settings put secure theme_customization_overlay_packages '$json' && cmd uimode night ${if (p.isLight) "no" else "yes"}"
        val process = ProcessBuilder("su", "-c", cmd).redirectErrorStream(true).start()
        process.inputStream.bufferedReader().forEachLine { Log.i(TAG, it) }
        Log.i(TAG, "Android colors: exit ${process.waitFor()}")
    }
}
