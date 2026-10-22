package dev.omalauncher.system

import android.content.Context
import android.graphics.Rect
import android.os.Bundle
import android.provider.Settings

/**
 * Android apps in floating windows over home on the unfolded screen (the PowOS desktop, docs/DESKTOP-WEB-SHELL.md):
 * an app opened from home there gets a freeform window, placed a step down and right of the last one, instead of the
 * whole screen. Folded (the cover screen), or with Android's freeform windows off, apps open full screen as before.
 *
 * Freeform is Android's own windowing mode; this ROM (OxygenOS 16) only allows it with the developer setting
 * `enable_freeform_support` = 1 (global; `settings delete global enable_freeform_support` turns it back off). OnePlus's
 * own flexible/zoom window calls open apps full screen when anyone but its launcher asks (checked 2026-10-22).
 */
object AppWindows {
    /** A screen this wide (dp, the smaller side) is the desktop: apps float. The cover screen is 404. */
    private const val DESKTOP_MIN_DP = 600

    /** Where the next window goes relative to the first (cascade), in steps of [STEP_DP]. */
    private var cascade = 0
    private const val STEP_DP = 40
    private const val CASCADE_STEPS = 6

    /** Whether apps opened now get a floating window. */
    fun floating(context: Context): Boolean =
        context.resources.configuration.smallestScreenWidthDp >= DESKTOP_MIN_DP &&
            Settings.Global.getInt(context.contentResolver, "enable_freeform_support", 0) == 1

    /** Launch options for an app opened from home: a floating window when [floating], else null (full screen). */
    fun launchOptions(context: Context): Bundle? {
        if (!floating(context)) return null
        return Tasks.freeformOptions(nextBounds(context)).toBundle()
    }

    /** Half the screen's width, two thirds of its height, cascading from the upper left third. */
    private fun nextBounds(context: Context): Rect {
        val screen = context.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds
        val step = (STEP_DP * context.resources.displayMetrics.density).toInt() * cascade
        cascade = (cascade + 1) % CASCADE_STEPS
        val w = screen.width() / 2
        val h = screen.height() * 2 / 3
        val left = screen.left + screen.width() / 6 + step
        val top = screen.top + screen.height() / 8 + step
        return Rect(left, top, left + w, top + h)
    }
}
