package dev.omalauncher.system

import android.app.ActivityOptions
import android.content.Context
import android.graphics.Rect
import android.os.Bundle
import android.provider.Settings
import kotlin.math.roundToInt

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

    /**
     * [base] (or plain options) made a floating window's when apps float now ([floating]): the next cascaded bounds and
     * Android's freeform mode. Every launch path on the unfolded home goes through this - dock, drawer, search, recents,
     * widgets, notifications, quick settings, links, the AI - so an app never opens full screen there. Folded: [base].
     */
    fun options(
        context: Context,
        base: ActivityOptions? = null,
    ): ActivityOptions? {
        if (!floating(context)) return base
        return Tasks.freeformOptions(nextBounds(context), base)
    }

    /**
     * Options to bring task [id] back (the switcher, a recents card): a floating window as [options] gives, unless it
     * is one already - then [base] as it is, so it comes back where it was.
     */
    fun taskOptions(
        context: Context,
        id: Int,
        base: ActivityOptions,
    ): ActivityOptions {
        if (!floating(context) || FreeformTasks.list(context).any { it.id == id }) return base
        return options(context, base) ?: base
    }

    /** [options] as a Bundle (startActivity / PendingIntent.send take one); null folded without [base]. */
    fun bundle(
        context: Context,
        base: ActivityOptions? = null,
    ): Bundle? = options(context, base)?.toBundle()

    /** Launch options for an app opened from home: a floating window when [floating], else null (full screen). */
    fun launchOptions(context: Context): Bundle? = bundle(context)

    /**
     * The density a floating window's app lays itself out at (FreeformTasks.density on every new window): the screen's
     * own times [WINDOW_SCALE], so a window ~60% of the screen wide is still a tablet-wide layout (>= 600 dp: Chrome's
     * tab strip, desktop sites) at about the physical size of the app full screen. Its pixels, never a scaled bitmap.
     */
    fun windowDpi(context: Context): Int = (context.resources.configuration.densityDpi * WINDOW_SCALE).roundToInt()

    private const val WINDOW_SCALE = 0.8f

    /**
     * The top of home's bottom bar (search pill + dock) on the screen, px; 0 = not told yet (home's page reports it:
     * windows.area, ui/desktops.ts). Windows open and maximise above it, never over it.
     */
    @Volatile
    var barTop = 0

    /**
     * Where floating windows may be (screen px): under the status bar and a window's own title bar (WindowFrame.BAR_DP),
     * above home's bottom bar ([barTop]; a sixth of the screen kept free until home has said where it is).
     */
    fun area(context: Context): Rect {
        val wm = context.getSystemService(android.view.WindowManager::class.java)
        val screen = wm.maximumWindowMetrics.bounds
        val density = context.resources.displayMetrics.density
        val status = runCatching { wm.currentWindowMetrics.windowInsets.getInsets(android.view.WindowInsets.Type.statusBars()).top }.getOrDefault(0)
        val top = screen.top + status + (WindowFrame.BAR_DP * density).toInt()
        val gap = (GAP_DP * density).toInt()
        val bottom = (if (barTop > top) barTop else screen.bottom - screen.height() / 6) - gap
        return Rect(screen.left, top, screen.right, maxOf(top + 1, bottom))
    }

    private const val GAP_DP = 8

    /** 60% of the screen's width x 70% of its height (inside [area]), cascading down and right from the upper left. */
    private fun nextBounds(context: Context): Rect {
        val screen = context.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds
        val a = area(context)
        val step = (STEP_DP * context.resources.displayMetrics.density).toInt() * cascade
        cascade = (cascade + 1) % CASCADE_STEPS
        val w = minOf(screen.width() * 6 / 10, a.width())
        val h = minOf(screen.height() * 7 / 10, a.height())
        val left = (a.left + screen.width() / 10 + step).coerceAtMost(a.right - w)
        val top = (a.top + step).coerceAtMost(a.bottom - h)
        return Rect(left, top, left + w, top + h)
    }
}
