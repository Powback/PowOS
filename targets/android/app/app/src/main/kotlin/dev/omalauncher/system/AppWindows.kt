package dev.omalauncher.system

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
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
     * The unfolded desktop with web windows on (`powos_web_windows` = 1): every app window is a web window then
     * (docs/WEB_WINDOWS.md) - whatever opened it. A task that still comes up as an Android freeform window (an intent
     * with these options, a notification, another app, OnePlus' floating window) is handed to ShellBridge.toWebWindow
     * (shell/SystemFloat, WindowFrames' adopt) and WindowFrames never dresses one.
     */
    fun webDesktop(context: Context): Boolean = floating(context) && dev.omalauncher.shell.WebWindows.on(context)

    // Not the web-windows setting: launches still get freeform options with powos_web_windows = 1 (a small window, not a
    // full-screen flash, for the moment before [webDesktop]'s hand-over moves the task onto its web window's display).

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
        // The app comes up over home: home's panels go back under the windows (shell/PanelLift).
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) dev.omalauncher.shell.PanelLift.dropNow("launch")
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
        // Folded, a window left from the inner screen comes back full screen, not freeform off the cover's edge.
        FoldedWindows.beforeOpen(context, id)
        // Sent full screen by its maximise button: it floats again at its place (adopt never floats it back).
        if (WindowFrames.current?.floatBack(id) == true) return base
        // A web window (on its own display; home's page owns it) comes back where it is, never pulled into freeform.
        if (dev.omalauncher.shell.WebWindowDisplays.isWebWindow(context, id)) return base
        // A web window's app made a full-screen app (its bar's full screen button): it comes back full screen.
        if (dev.omalauncher.shell.WebWindowDisplays.fullScreenWindow(id) != null) return base
        if (!floating(context) || FreeformTasks.list(context).any { it.id == id }) return base
        return options(context, base) ?: base
    }

    /** [options] as a Bundle (startActivity / PendingIntent.send take one); null folded without [base]. */
    fun bundle(
        context: Context,
        base: ActivityOptions? = null,
    ): Bundle? = options(context, base)?.toBundle()

    /**
     * THE launch of an app's activity from PowOS ([start] does it, given its options): on the web desktop
     * ([webDesktop]) straight into [pkg]'s web window - home's page makes the window first, the activity starts on its
     * display (shell/WebWindowLaunch) - never full screen or freeform on display 0 first and moved after (the user,
     * 10-30 23:07). Elsewhere, or not routable (no home page, [pkg] null or without a drawer app), [start] runs now
     * with [bundle]'s options, as before. Exceptions of an immediate [start] reach the caller; a held one's are logged.
     */
    fun launch(
        context: Context,
        pkg: String?,
        base: ActivityOptions? = null,
        start: (Bundle?) -> Unit,
    ) {
        if (pkg != null && webDesktop(context) &&
            dev.omalauncher.shell.WebWindowLaunch.route(context, pkg, dev.omalauncher.shell.WebWindowLaunch.Pending(base, start) { start(bundle(context, base)) })
        ) {
            return
        }
        start(bundle(context, base))
    }

    /** [launch] of [intent] (a new task) with context.startActivity. */
    fun startActivity(
        context: Context,
        intent: Intent,
        base: ActivityOptions? = null,
    ) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        launch(context, packageOf(context, intent), base) { context.startActivity(intent, it) }
    }

    /**
     * [launch] of [pi] (a notification's, a tile's, a media session's): its creator's window when it starts an
     * activity; a broadcast or service (a reply, a trampoline) is sent now as before - nothing to put in a window.
     */
    fun send(
        context: Context,
        pi: PendingIntent,
        fill: Intent? = null,
        base: ActivityOptions? = null,
    ) {
        val pkg = if (android.os.Build.VERSION.SDK_INT >= 31 && pi.isActivity) pi.creatorPackage else null
        launch(context, pkg, base) { pi.send(context, 0, fill, null, null, null, it) }
    }

    /** The app [intent] opens: its package or component's, else the one activity it resolves to (null: a chooser, none). */
    fun packageOf(
        context: Context,
        intent: Intent,
    ): String? {
        intent.component?.let { return it.packageName }
        intent.`package`?.let { return it }
        val info = runCatching { context.packageManager.resolveActivity(intent, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo }.getOrNull() ?: return null
        // The resolver ("android") is a chooser between apps: no one app's window to make.
        return info.packageName.takeIf { it != "android" }
    }

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
        // The frame's whole bar window (glass + touch strip) under the status bar: above every overlay, it took the
        // touches of a bar reaching into it, and a window there read as a bar over the status bar (2026-10-24).
        val top = screen.top + status + ((WindowFrame.BAR_DP + WindowFrame.HIT_DP) * density).toInt()
        val gap = (GAP_DP * density).toInt()
        val bottom = (if (barTop > top) barTop else screen.bottom - screen.height() / 6) - gap
        return Rect(screen.left, top, screen.right, maxOf(top + 1, bottom))
    }

    private const val GAP_DP = 8

    /**
     * [bounds] moved (and shrunk if it is bigger) so the whole window - all four edges, and so its title bar above it -
     * is inside [area]: every place a window is put back to (a saved place, a restore after maximise or full screen, the
     * dock) goes through this, so none comes back off the screen or under the status bar / home's bottom bar. Empty
     * bounds (unknown) stay empty.
     */
    fun onScreen(
        context: Context,
        bounds: Rect,
    ): Rect {
        if (bounds.isEmpty) return Rect(bounds)
        val a = area(context)
        val w = bounds.width().coerceAtMost(a.width())
        val h = bounds.height().coerceAtMost(a.height())
        val left = bounds.left.coerceIn(a.left, a.right - w)
        val top = bounds.top.coerceIn(a.top, a.bottom - h)
        return Rect(left, top, left + w, top + h)
    }

    /** 60% of the screen's width x 70% of its height (inside [area]), cascading down and right from the upper left. */
    fun nextBounds(context: Context): Rect {
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
