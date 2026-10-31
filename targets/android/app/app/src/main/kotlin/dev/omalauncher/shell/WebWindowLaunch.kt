package dev.omalauncher.shell

import android.app.ActivityOptions
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Display
import java.util.concurrent.ConcurrentHashMap

/**
 * Launches straight into a web window (docs/WEB_WINDOWS.md; the user, 10-30 23:07: "it opened like full screen and then
 * turned into window"). On the unfolded desktop with web windows on, every PowOS launch path (notifications, widgets,
 * quick settings tiles, settings search, links, media, the AI - AppWindows.launch) asks home's page for the app's
 * window FIRST ("webwindows.launch": its frame shows at once, as a dock tap's does), and the launch itself is held here
 * until that window's trusted display exists: then it starts there (ActivityOptions.setLaunchDisplayId), never on
 * display 0. Before, the launch went to display 0 as a freeform (or full-screen) task and SystemFloat's hand-over /
 * WebWindows.follow moved it into its window afterwards - the full-screen flash. Those stay as the safety net for
 * what doesn't come through here (another app starting an activity, OnePlus' floating window).
 *
 * Its app has a window already: the launch goes onto that window's display at once (the page raises the window). A
 * full-screen app out of a window: onto display 0, plain (no freeform). No window made within [WAIT_MS] (the page
 * refused it: an unresizeable app, a narrow home), or the page fell back to apps.launch: the launch goes the old way
 * ([Pending.fallback]: AppWindows' freeform options), so nothing is ever lost.
 */
object WebWindowLaunch {
    private const val TAG = "PowosWebWindows"

    /** How long a held launch waits for its window's display before it goes the old way. */
    private const val WAIT_MS = 2500L

    /** A launch: [start] does it (given its options, [base] made the window's), [fallback] is the old way. */
    class Pending(
        val base: ActivityOptions?,
        val start: (Bundle) -> Unit,
        val fallback: () -> Unit,
    ) {
        val at: Long = SystemClock.uptimeMillis()
    }

    /** Held launches by package: the latest one per app (a second tap replaces the first). */
    private val pending = ConcurrentHashMap<String, Pending>()
    private val main = Handler(Looper.getMainLooper())

    /** Home is the activity in front (ShellActivity's resume/pause): else it is brought up with the window. */
    @Volatile var homeInFront = false

    /**
     * [pkg]'s launch [p] into its web window. False: not routed (no home page, no drawer app for [pkg]) - the caller
     * launches it as before. [Pending.fallback] runs if no window comes.
     */
    fun route(
        context: Context,
        pkg: String,
        p: Pending,
    ): Boolean {
        if (pkg == context.packageName) return false
        val shown = WebWindows.displayOfApp(pkg)
        val routed = if (shown != null && shown != -1) now(context, pkg, p, shown) else hold(context, pkg, p, shown == null)
        if (routed && !homeInFront) frontHome(context)
        return routed
    }

    /** [pkg] has a window ([shown]: its display, or [WebWindows.FULL_APP]): the page raises it, [p] starts there now. */
    private fun now(
        context: Context,
        pkg: String,
        p: Pending,
        shown: Int,
    ): Boolean {
        if (!ShellBridge.openOnHome(context, pkg)) return false
        val full = shown == WebWindows.FULL_APP
        WindowLog.i(TAG, "launch $pkg: " + if (full) "its window's app is full screen: on display 0, plain" else "onto its window's display $shown at once")
        run(pkg, p, if (full) Display.DEFAULT_DISPLAY else shown)
        return true
    }

    /** [p] held for [pkg]'s window ([asked]: a new one asked of home; else one being made), the old way after [WAIT_MS]. */
    private fun hold(
        context: Context,
        pkg: String,
        p: Pending,
        asked: Boolean,
    ): Boolean {
        // Held first, then the page asked: its window can't take the launch before it's here.
        pending[pkg] = p
        if (!ShellBridge.openOnHome(context, pkg)) {
            pending.remove(pkg, p)
            return false
        }
        WindowLog.i(TAG, "launch $pkg: held for its web window's display (${if (asked) "window asked of home" else "window being made"})")
        main.postDelayed({
            if (pending.remove(pkg, p)) {
                WindowLog.w(TAG, "launch $pkg: no window display after $WAIT_MS ms: launched the old way")
                runCatching(p.fallback).onFailure { WindowLog.w(TAG, "launch $pkg (old way) failed", it) }
            }
        }, WAIT_MS)
        return true
    }

    /**
     * WebWindows.launch: window [displayId] of [pkg] is ready - a held launch of [pkg] starts on it. True: one did (the
     * window's own launcher-intent launch is skipped).
     */
    fun take(
        pkg: String,
        displayId: Int,
    ): Boolean {
        val p = pending.remove(pkg) ?: return false
        WindowLog.i(TAG, "launch $pkg: its window's display $displayId came ${SystemClock.uptimeMillis() - p.at} ms after the tap")
        run(pkg, p, displayId)
        return true
    }

    /** No window for [pkg] after all (the page fell back, WebWindows refused): its held launch goes the old way. True: one did. */
    fun refused(pkg: String): Boolean {
        val p = pending.remove(pkg) ?: return false
        WindowLog.i(TAG, "launch $pkg: no web window for it: launched the old way")
        runCatching(p.fallback).onFailure { WindowLog.w(TAG, "launch $pkg (old way) failed", it) }
        return true
    }

    private fun run(
        pkg: String,
        p: Pending,
        displayId: Int,
    ) {
        val opts = (p.base ?: ActivityOptions.makeBasic()).setLaunchDisplayId(displayId)
        runCatching { p.start(opts.toBundle()) }.onFailure {
            WindowLog.w(TAG, "launch $pkg on display $displayId refused (${it.message}): the old way instead")
            p.base?.setLaunchDisplayId(Display.DEFAULT_DISPLAY)
            runCatching(p.fallback).onFailure { e -> WindowLog.w(TAG, "launch $pkg (old way) failed", e) }
        }
    }

    /** Home up under the new window (a launch from the shade over a full-screen app): its page holds the window. */
    private fun frontHome(context: Context) {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).setPackage(context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(home, ActivityOptions.makeBasic().setLaunchDisplayId(Display.DEFAULT_DISPLAY).toBundle()) }
            .onFailure { WindowLog.w(TAG, "home to the front for a launch failed", it) }
    }
}
