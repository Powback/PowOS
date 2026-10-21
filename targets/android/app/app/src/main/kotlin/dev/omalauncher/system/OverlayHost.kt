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

    /** Hidden: no longer on screen (subclasses drop their blur). */
    protected open fun onHidden() = Unit

    private val closer =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
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
            }
        host = h
        watchdog = PageWatchdog(h.web, title) { hide() }
        val r = Root(context).apply { addView(h.web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)) }
        r.visibility = View.GONE
        root = r
        params = layout().also { wm.addView(r, it) }
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
    ) = host?.bridge?.emit(event, data)

    /** Visible for the gesture, not touchable yet. */
    protected fun show() {
        val r = root ?: return
        r.removeCallbacks(shutGone)
        if (shown) return
        shown = true
        open = false
        r.visibility = View.VISIBLE
        setFlags(touchable = false, focusable = false)
        watchdog?.start()
    }

    /** Settled open: touchable and focused once the page answers it's alive. */
    protected fun armOpen() {
        val web = host?.web ?: return
        root?.removeCallbacks(shutGone)
        PageWatchdog.probe(web) { alive, why ->
            if (!shown) return@probe
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
        shown = false
        open = false
        r.visibility = View.GONE
        setFlags(touchable = false, focusable = false)
        onHidden()
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
}
