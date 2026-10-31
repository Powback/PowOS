package dev.omalauncher.shell

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import andro.marchy.RootShell
import dev.omalauncher.system.FreeformTasks

/**
 * The system's own window menu - the "..." app handle at the top of a full-screen app - is OnePlus'
 * FullscreenCaptionHandleMenu (com.android.wm.shell.fullscreen, OxygenOS 16 SystemUI.apk, dexdump), NOT AOSP WM Shell's
 * desktop-mode handle menu: its items are built in code in initPopupListWindow (Split View, Floating window - string
 * caption_menu_text_zoom -, Close, inner split) and its click handler dispatches by list position. A resource overlay
 * can only change their text, never add one.
 *
 * D1 (the user 2026-10-31 01:17: "we just replaced the text. But we were supposed to add a desk.window option in
 * addition to like the floating window thing"): the menu has BOTH. "Floating window" is OnePlus' own, unchanged (an
 * earlier "Desktop window" relabel - a fabricated overlay com.android.shell:[NAME] on that string - is disabled here),
 * and the task it floats stays a native floating window (FreeformTasks.isNativeFloat). "Desktop window" is a 4th item
 * added by the PowOS LSPosed module in SystemUI (targets/android/oplus-hook, Hook.desktopWindowItem) that sends
 * [ACTION] here ([CaptionMenuReceiver]): [toWebWindow] = ShellBridge.toWebWindow, the switcher's "Desktop window".
 *
 * And [handOver]: an app that floats WITHOUT the user picking a floating window - launched floating by any path on the
 * unfolded desktop (the launcher overlay, a notification, a widget, another app), or freeform by the app's own doing -
 * becomes a PowOS web window, at its freeform bounds, else its last place by hand, else centred. PowOS's own floats
 * are marked ([FreeformTasks.markOwnFloat]); the user's native floats ([FreeformTasks.isNativeFloat]) are left alone.
 */
object SystemFloat {
    private const val TAG = "PowosSystemFloat"
    private const val NAME = "PowosDesktopWindowItem"
    private const val TARGET = "com.android.systemui"
    private const val ID = "com.android.shell:$NAME"

    /** SystemUI (the PowOS LSPosed hook in the "..." menu) -> PowOS: extra "task" (id), "item" ([ITEM_DESKTOP]/[ITEM_FLOAT]). */
    const val ACTION = "com.powos.app.action.CAPTION_MENU"
    const val ITEM_DESKTOP = "desktop"
    const val ITEM_FLOAT = "float"

    /** Debounce of the task listener's bursts, ms. */
    private const val SETTLE_MS = 120L

    private val io by lazy { Handler(HandlerThread("powos-system-float").apply { start() }.looper) }
    private var stop: (() -> Unit)? = null
    private var onFloat: ((Int) -> Unit)? = null

    /** App tasks last seen full screen on the main display (task id): the ones a float of the system's starts from. */
    private val full = java.util.concurrent.ConcurrentHashMap.newKeySet<Int>()

    /** The old relabel overlay checked this run (null: not yet). */
    @Volatile private var labelled: Boolean? = null
    private val check = Runnable { check() }

    /** Home's bridge up: watch tasks; [float] gets a task the system just floated (main thread of the caller's choice). */
    fun start(
        context: Context,
        float: (Int) -> Unit,
    ) {
        this.context = context.applicationContext
        onFloat = float
        if (stop != null) return
        stop =
            FreeformTasks.listen {
                io.removeCallbacks(check)
                io.postDelayed(check, SETTLE_MS)
            }
        io.post(check)
    }

    /** Home's bridge [float] gone: the watch stops, unless a newer home bridge took it over meanwhile. */
    fun stop(float: (Int) -> Unit) {
        if (onFloat !== float) return
        stop?.invoke()
        stop = null
        onFloat = null
    }

    @Volatile private var context: Context? = null

    /** On [io]: the label follows the setting; a task gone full screen -> floating by the system's hand is handed over. */
    private fun check() {
        val ctx = context ?: return
        val on = WebWindows.on(ctx)
        if (labelled == null) unlabel()
        if (!on) {
            full.clear()
            return
        }
        handOver(ctx)
    }

    /**
     * Floating app tasks (freeform or OnePlus' zoom window - its menu's item makes the latter, WINDOWING_MODE_ZOOM) on
     * the main display to [onFloat]. The unfolded desktop: EVERY one, however it got there - launched with AppWindows'
     * freeform options (the launcher overlay, a notification, a widget, settings search, the AI), started floating by
     * another app, OnePlus' floating window, PowOS's own Tasks.float. Each task once ([handed]): one whose hand-over
     * failed (no drawer app) isn't asked again every task event; WindowFrames never dresses it meanwhile. Folded: the
     * system's own float of a full-screen app only, as before.
     */
    private fun handOver(ctx: Context) {
        val floating = FreeformTasks.floatingModes(ctx).filter { (_, pkg, _) -> pkg != null && pkg != ctx.packageName }
        val ids = floating.map { it.first }.toSet()
        handed.retainAll(ids)
        FreeformTasks.retainNativeFloats(ids)
        val desktop = dev.omalauncher.system.AppWindows.floating(ctx)
        // D1: a floating window the user picked ("..." / switcher "Floating window") stays native, folded or not.
        val floated =
            floating.filter { (id, _, mode) ->
                id !in handed && !FreeformTasks.isNativeFloat(id, mode) && (desktop || (id in full && !FreeformTasks.isOwnFloat(id)))
            }.map { (id, pkg, _) -> id to pkg }
        full.clear()
        FreeformTasks.fullScreen(ctx, hiddenToo = true).forEach { (id, pkg) -> if (pkg != ctx.packageName) full += id }
        floated.forEach { (id, pkg) ->
            Log.i(TAG, "task $id ($pkg) floating on the main display, not the user's pick (${if (desktop) "any launch path" else "from full screen"}): to a web window")
            handed += id
            onFloat?.invoke(id)
        }
    }

    /** Floating tasks handed to [onFloat] already (while they still float on the main display). */
    private val handed = java.util.concurrent.ConcurrentHashMap.newKeySet<Int>()

    /**
     * Task [id] into a web window (ShellBridge.toWebWindow on home's main thread): WindowFrames' adopt of a stray
     * full-screen app with web windows on. False: no home bridge watching.
     */
    fun toWebWindow(id: Int): Boolean {
        val float = onFloat ?: return false
        handed += id
        float(id)
        return true
    }

    /**
     * The "..." menu from SystemUI ([CaptionMenuReceiver]): [ITEM_DESKTOP] puts task [id] in a web window; [ITEM_FLOAT]
     * (OnePlus' own Floating window, about to float it) marks it the user's native floating window first.
     */
    fun captionMenu(
        id: Int,
        item: String?,
    ) {
        Log.i(TAG, "the \"...\" menu: $item for task $id")
        when (item) {
            ITEM_FLOAT -> FreeformTasks.markNativeFloat(id)
            ITEM_DESKTOP -> if (!toWebWindow(id)) Log.w(TAG, "task $id: no home bridge, no desktop window")
        }
    }

    /** OnePlus' "Floating window" item says so again: the old "Desktop window" relabel overlay disabled (one root call). */
    private fun unlabel() {
        labelled = false
        val listed = RootShell.run("cmd overlay list $TARGET | grep -F '$ID'").output
        if (!listed.contains("[x] $ID")) return
        val r = RootShell.run("cmd overlay disable $ID")
        Log.i(TAG, "the old \"Desktop window\" relabel of OnePlus' Floating window disabled: rc ${r.code} ${r.output.takeLast(200)}")
    }
}
