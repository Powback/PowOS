package dev.omalauncher.shell

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import andro.marchy.RootShell
import dev.omalauncher.system.FreeformTasks

/**
 * The system's own window menu offers "Desktop window" (D1, the user 2026-10-30: "The menu here, which has, like, split
 * screen or floating window, should also have an option to put it back as a desktop window. You know like the dot dot
 * dot."). That menu - the "..." app handle at the top of a full-screen app - is NOT AOSP WM Shell's desktop-mode handle
 * menu (which has a Desktop button): it is OnePlus' own FullscreenCaptionHandleMenu (com.android.wm.shell.fullscreen,
 * OxygenOS 16 SystemUI.apk, dexdump), whose items are fixed in initPopupListWindow - Split screen, Floating window
 * (string caption_menu_text_zoom), Close, and inner split. AOSP's handle menu would need DesktopModeWindowDecorViewModel,
 * which this build makes only when DesktopModeStatus.canEnterDesktopModeOrShowAppHandle (framework
 * config_isDesktopModeSupported false here) - turning that on swaps the whole window decoration of every freeform task
 * and system_server's desktop rules, so it isn't the route.
 *
 * So, with web windows on: OnePlus' "Floating window" item is relabelled "Desktop window" (a fabricated runtime resource
 * overlay on SystemUI's string, com.android.shell:[NAME], as [SplitSideBySide]/OemCaption), and an app that goes from
 * full screen to floating WITHOUT PowOS doing it (that item makes OnePlus' zoom window, WINDOWING_MODE_ZOOM 100; any
 * other system path to freeform likewise) becomes a PowOS web window ([onFloat] = ShellBridge.toWebWindow, the same path
 * as the switcher's "PowOS desktop window"): at its freeform bounds, else its last place by hand, else centred. PowOS's own floats (FreeformTasks.toWindow, setFullScreen back to a window,
 * Tasks.float) are marked ([FreeformTasks.markOwnFloat]) and left alone. Web windows off: the overlay is disabled (the
 * item says "Floating window" again) and nothing is converted.
 *
 * HACK: a SystemUI resource overlay from root, because OnePlus' menu takes no extra item and SystemUI can't be patched
 * (no code hooks). Real fix: a "Desktop window" item of PowOS's own in that menu (a SystemUI change: a 5th
 * PopupListItem in FullscreenCaptionHandleMenu.initPopupListWindow and a MenuHandler call that tells PowOS the task).
 */
object SystemFloat {
    private const val TAG = "PowosSystemFloat"
    private const val NAME = "PowosDesktopWindowItem"
    private const val TARGET = "com.android.systemui"
    private const val ID = "com.android.shell:$NAME"
    private const val RES = "$TARGET:string/caption_menu_text_zoom"
    const val LABEL = "Desktop window"

    /** Debounce of the task listener's bursts, ms. */
    private const val SETTLE_MS = 120L

    private val io by lazy { Handler(HandlerThread("powos-system-float").apply { start() }.looper) }
    private var stop: (() -> Unit)? = null
    private var onFloat: ((Int) -> Unit)? = null

    /** App tasks last seen full screen on the main display (task id): the ones a float of the system's starts from. */
    private val full = java.util.concurrent.ConcurrentHashMap.newKeySet<Int>()

    /** The overlay's state last applied (null: not yet this run). */
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
        if (labelled != on) label(on)
        if (!on) {
            full.clear()
            return
        }
        // Freeform or OnePlus' zoom window (its menu's item makes the latter, WINDOWING_MODE_ZOOM).
        val floated = FreeformTasks.floatingApps(ctx).filter { (id, pkg) -> id in full && pkg != ctx.packageName && !FreeformTasks.isOwnFloat(id) }
        full.clear()
        FreeformTasks.fullScreen(ctx, hiddenToo = true).forEach { (id, pkg) -> if (pkg != ctx.packageName) full += id }
        floated.forEach { (id, pkg) ->
            Log.i(TAG, "task $id ($pkg) floated by the system (its menu's \"$LABEL\"): to a web window")
            onFloat?.invoke(id)
        }
    }

    /** The menu item says [LABEL] ([on]) or OnePlus' own "Floating window" again; one root call, skipped when already so. */
    private fun label(on: Boolean) {
        val listed = RootShell.run("cmd overlay list $TARGET | grep -F '$ID'; cmd overlay lookup $TARGET $RES").output
        val enabled = listed.contains("[x] $ID")
        val r =
            when {
                on && enabled && listed.trim().endsWith(LABEL) -> null
                // 0x03: TypedValue.TYPE_STRING.
                on -> RootShell.run("cmd overlay fabricate --target $TARGET --name $NAME $RES 0x03 '$LABEL' && cmd overlay enable $ID")
                enabled -> RootShell.run("cmd overlay disable $ID")
                else -> null
            }
        labelled = on
        Log.i(TAG, "system menu item ${if (on) "\"$LABEL\"" else "back to OnePlus' own"}: ${r?.let { "rc ${it.code} ${it.output.takeLast(200)}" } ?: "already so"}")
    }
}
