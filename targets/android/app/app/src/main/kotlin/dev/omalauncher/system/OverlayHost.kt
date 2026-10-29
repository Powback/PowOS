package dev.omalauncher.system

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import dev.omalauncher.App
import dev.omalauncher.shell.PageWatchdog
import dev.omalauncher.shell.ShellHost

/**
 * A shell page in a window over whatever is on screen, brought by a gesture and following the finger: what Quick Tools
 * ([QuickToolsHost]) and the pull-up panels over apps are built on. A thin host, as the shade's ([ShadeHost]): the
 * window, its flags and its lifetime here, everything shown is the page ([mode]).
 *
 * - TYPE_STATUS_BAR_SUB_PANEL (STATUS_BAR_SERVICE, the recents role's): above apps and the status bar. Full screen and
 *   transparent, added once and kept warm (GONE while shut), so the gesture shows it at once.
 * - [show] while the finger brings it: visible, not touchable (the gesture input has the finger). [armOpen] once it
 *   settled open: touchable and focused (Back reaches it) only after its page answered ([PageWatchdog]) - a page that
 *   can't answer never leaves an invisible window eating every touch. [armShut]: the page puts it away itself
 *   ([OverlaySlot.closed]); if it never says so, [hide] after a moment.
 * - Home, the switcher and the screen going off shut it ([onDismiss]).
 */
abstract class OverlayHost(
    protected val service: Context,
    private val mode: String,
    private val title: String,
) {
    private val display: Display = service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    protected val context: Context = service.createDisplayContext(display).createWindowContext(TYPE, null)
    private val wm = context.getSystemService(WindowManager::class.java)
    protected var host: ShellHost? = null
        private set
    protected var root: View? = null
        private set
    private var params: WindowManager.LayoutParams? = null
    private var watchdog: PageWatchdog? = null

    /** What the page was told since the window last went (by event name), for a page that reloaded meanwhile. */
    private val told = linkedMapOf<String, Any?>()

    /** A shell push's reload done while hidden ([OverlayReload]). */
    private var reload: OverlayReload? = null

    /** The window shows (coming in, open, or settling shut). */
    var shown = false
        private set

    /** Settled open (touchable). */
    var open = false
        private set

    /** Back pressed while it's focused (open). */
    protected abstract fun onBack()

    /** Home, the switcher, the screen off: shut it. */
    protected abstract fun onDismiss()

    /** Something was launched from the page (pull.launched): the app switch shows, the overlay goes at once. */
    protected open fun onLaunched() = hide()

    /** The page is up and can be seen (false while a shell push's reload runs: the window is at alpha 0). */
    protected val pageReady: Boolean get() = reload?.reloading != true

    /** The page came up after a reload while the window showed: what's behind it may be blurred now. */
    protected open fun onPageReady() = Unit

    /** Hidden: no longer on screen (subclasses drop their blur). */
    protected open fun onHidden() = Unit

    private val closer =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                // HACK: the system broadcasts CLOSE_SYSTEM_DIALOGS (reason "assist") when the side-button AI session starts;
                // the assist overlay opens OVER this panel, so it stays. Real fix: none needed, the reason is the contract.
                if (intent.action == Intent.ACTION_CLOSE_SYSTEM_DIALOGS &&
                    (intent.getStringExtra("reason") == "assist" || dev.omalauncher.system.PetOverlay.assistShowing)
                ) {
                    return
                }
                if (shown) onDismiss()
            }
        }

    fun start(): Boolean {
        if (host != null) return true
        val runtime = (service.applicationContext as App).runtime
        runtime.start()
        val h = ShellHost(context, null, runtime, mode)
        h.bridge.overlay =
            object : OverlaySlot {
                override fun closed() = hide()

                override fun launched() = onLaunched()

                override fun typing(on: Boolean) = typingWindow(on)
            }
        host = h
        watchdog = PageWatchdog(h.web, title) { hide() }
        val r = Root(context).apply { addView(h.web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)) }
        r.visibility = View.GONE
        root = r
        params = layout().also { wm.addView(r, it) }
        reload =
            OverlayReload(title, wm, { host?.web }, { root?.let { v -> params?.let { v to it } } }, { shown }) {
                // The pull came while the page reloaded: the new page hears the gesture so far, then the window counts.
                for ((event, data) in told) host?.bridge?.emit(event, data)
                onPageReady()
                watchdog?.start()
                if (wantOpen) armOpen()
            }.also { g -> h.filesGate = g::changed }
        @Suppress("DEPRECATION")
        service.registerReceiver(closer, IntentFilter(Intent.ACTION_CLOSE_SYSTEM_DIALOGS).apply { addAction(Intent.ACTION_SCREEN_OFF) })
        Log.i(TAG, "$title ready")
        return true
    }

    open fun stop() {
        runCatching { service.unregisterReceiver(closer) }
        watchdog?.stop()
        watchdog = null
        root?.let { runCatching { wm.removeView(it) } }
        root = null
        host?.destroy()
        host = null
    }

    protected fun emit(
        event: String,
        data: Any?,
    ) {
        // Kept from a gesture's start (some are told before the window shows) until the window goes.
        told[event] = data
        host?.bridge?.emit(event, data)
    }

    /** Settled open while the page was still reloading: opened once it's up. */
    private var wantOpen = false

    /** Visible for the gesture, not touchable yet. */
    protected fun show() {
        val r = root ?: return
        r.removeCallbacks(shutGone)
        if (shown) return
        shown = true
        open = false
        wantOpen = false
        r.visibility = View.VISIBLE
        setFlags(touchable = false, focusable = false)
        // A page reloading (a shell push) stays invisible (alpha 0) until it's up; the watchdog starts then.
        if (reload?.reloading != true) watchdog?.start()
    }

    /** Settled open: touchable and focused once the page answers it's alive. */
    protected fun armOpen() {
        if (reload?.reloading == true) {
            wantOpen = true
            return
        }
        val web = host?.web ?: return
        root?.removeCallbacks(shutGone)
        PageWatchdog.probeShown(web) { alive, why ->
            if (!shown) return@probeShown
            if (alive) {
                open = true
                setFlags(touchable = true, focusable = true)
            } else {
                Log.w(TAG, "$title: its page isn't answering ($why) - it goes")
                hide()
            }
        }
    }

    /** Settling shut: the page says closed when it's done; else the window goes after [SHUT_MAX_MS]. */
    protected fun armShut() {
        open = false
        setFlags(touchable = false, focusable = false)
        val r = root ?: return
        r.removeCallbacks(shutGone)
        r.postDelayed(shutGone, SHUT_MAX_MS)
    }

    private val shutGone =
        Runnable {
            if (shown) {
                Log.w(TAG, "$title settled shut but its page never said closed: the window goes")
                hide()
            }
        }

    /** Off screen, the page kept warm. */
    protected fun hide() {
        val r = root ?: return
        watchdog?.stop()
        r.removeCallbacks(shutGone)
        if (!shown) return
        // The panel closing takes its keyboard with it.
        host?.web?.let { w -> (context.getSystemService(Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager).hideSoftInputFromWindow(w.windowToken, 0) }
        shown = false
        open = false
        wantOpen = false
        told.clear()
        // Mid-reload the window stays up (alpha 0) for the page to finish loading; it goes when that's done.
        if (reload?.reloading != true) r.visibility = View.GONE
        setFlags(touchable = false, focusable = false)
        onHidden()
        reload?.hidden()
    }

    /**
     * The page's text field wants the keyboard ([on]) or let it go: while it types, this window is an IME target -
     * focusable, without FLAG_ALT_FOCUSABLE_IM - so the IME serves it, not the app or desktop window under it. Only
     * while open (touchable): the gesture-time window stays touch-through and non-focusable. Returns the window's flags
     * now, for the log.
     */
    fun typingWindow(on: Boolean): String {
        val r = root
        val p = params ?: return "$mode keyboard: no window"
        if (on && open && r != null) {
            setFlags(touchable = true, focusable = true)
            if (p.flags and WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM != 0) {
                p.flags = p.flags and WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM.inv()
                runCatching { wm.updateViewLayout(r, p) }
            }
        }
        return "$mode keyboard.${if (on) "show" else "hide"}: open=$open shown=$shown flags=0x${Integer.toHexString(p.flags)} notFocusable=${p.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE != 0} " +
            "altIm=${p.flags and WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM != 0} windowFocus=${host?.web?.hasWindowFocus()}"
    }

    private fun setFlags(
        touchable: Boolean,
        focusable: Boolean,
    ) {
        val r = root ?: return
        val p = params ?: return
        var f = p.flags
        f = if (touchable) f and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv() else f or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        f = if (focusable) f and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv() else f or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        if (f == p.flags) return
        p.flags = f
        runCatching { wm.updateViewLayout(r, p) }
    }

    private fun layout() =
        WindowManager.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
            TYPE,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            this.title = "PowOS ${this@OverlayHost.title}"
            gravity = Gravity.TOP or Gravity.START
            fitInsetsTypes = 0
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }

    private inner class Root(
        context: Context,
    ) : FrameLayout(context) {
        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            if (event.keyCode == KeyEvent.KEYCODE_BACK) {
                if (event.action == KeyEvent.ACTION_UP) onBack()
                return true
            }
            return super.dispatchKeyEvent(event)
        }
    }

    companion object {
        private const val TAG = "PowosOverlay"

        /** WindowManager.LayoutParams.TYPE_STATUS_BAR_SUB_PANEL (hidden). */
        private const val TYPE = 2017

        private const val SHUT_MAX_MS = 1_500L
    }
}

/** What an overlay's page reaches through the bridge (overlay.closed / pull.closed, pull.launched). */
interface OverlaySlot {
    /** The page is shut: the window can go. */
    fun closed()

    /** An app was launched from the page: the overlay goes now. */
    fun launched()

    /** The page's text field wants the keyboard ([on]) or let it go: the window made an IME target; its flags, for the log. */
    fun typing(on: Boolean): String
}
