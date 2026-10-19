package dev.omalauncher.system

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import dev.omalauncher.App
import dev.omalauncher.shell.ShellHost
import org.json.JSONObject

/**
 * PowOS's notification shade, in the stock shade's place (docs/NATIVE-SYSTEM-UI.md, "Notification shade + quick
 * settings", option b): SystemUI keeps running and stops pulling its own shade down, and a pull from the top edge
 * brings PowOS's down instead - the web shell's shade page (shell/ui/shade.tsx, mode=shade), following the finger. A
 * thin host, as every slot: the windows, the touch and the flags here, everything shown is the shell.
 *
 * - SystemUI's shade off: StatusBarManager's disable flags (DISABLE_EXPAND, DISABLE2_NOTIFICATION_SHADE and
 *   _QUICK_SETTINGS). They're kept per binder token, and the token is this process's StatusBarManager's: if PowOS dies,
 *   the system drops them and SystemUI's shade is back by itself. Lifted while the lock screen shows (its shade stays
 *   SystemUI's until PowOS has a lock screen face), and lent to SystemUI when the page asks for the system's own
 *   panel (system.notifications: its quick settings, which PowOS can't show yet) until that one is closed again.
 * - The pull: a strip over the status bar (TYPE_STATUS_BAR_ADDITIONAL, which sits above the status bar and below
 *   SystemUI's shade window - the lock screen's, while it shows) that takes touches there; dragged down, it sends the
 *   finger to the page ("shade.drag" { q }, "shade.settle" { open }) as home's own swipe does. Not touchable while
 *   the status bar is hidden (a full-screen app's top edge is its own).
 * - The shade: TYPE_STATUS_BAR_SUB_PANEL, full screen and transparent (the page dims with its own scrim), above the
 *   status bar and SystemUI's windows. The page is kept warm: the window stays added, hidden while the shade is shut
 *   (the page says so: shade.closed), so the next pull shows it at once.
 *
 * Needs what the recents provider is granted (STATUS_BAR_SERVICE for the window types, STATUS_BAR for the flags):
 * [PowosRecentsService] runs it while SystemUI is bound to it.
 *
 * HACK: the strip takes the status bar's touches, so a tap on something SystemUI shows there (OnePlus's live
 * capsules) doesn't reach it. Real fix: an input monitor (InputManager.monitorGestureInput, MONITOR_INPUT) that sees
 * the pull without being in the way and pilfers it once it's a pull - the same monitor gesture navigation needs.
 */
class ShadeHost(
    private val service: Context,
) {
    private val display: Display = service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    private val shadeContext = service.createDisplayContext(display).createWindowContext(TYPE_SHADE, null)
    private val edgeContext = service.createDisplayContext(display).createWindowContext(TYPE_EDGE, null)
    private val shadeWm = shadeContext.getSystemService(WindowManager::class.java)
    private val edgeWm = edgeContext.getSystemService(WindowManager::class.java)

    /** Its token holds the disable flags: kept for the process's life, so they go when it does. */
    private val statusBar = service.getSystemService(Context.STATUS_BAR_SERVICE)

    private var host: ShellHost? = null
    private var shade: Root? = null
    private var edge: Edge? = null
    private var shadeParams: WindowManager.LayoutParams? = null
    private var edgeParams: WindowManager.LayoutParams? = null

    /** The lock screen shows (SystemUI's state): its shade is SystemUI's, and the strip lets the touches through. */
    private var keyguard = service.getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked

    /** SystemUI's own panel asked for (system.notifications), until it was open and closed again. */
    private var lent = false
    private var lentSeenOpen = false

    /** The status bar is showing: false while a full-screen app hides it. */
    private var statusBarShown = true
    private var shown = false

    /** Home pressed (or the switcher) while the shade is down: it goes up, as SystemUI's does. */
    private val closer =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                if (shown) settle(false)
            }
        }

    /** Puts PowOS's shade in place of SystemUI's; false (and nothing changed) without the recents permissions. */
    fun start(): Boolean {
        if (host != null) return true
        val missing = listOf(PERMISSION_STATUS_BAR_SERVICE, PERMISSION_STATUS_BAR).filter { service.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            Log.w(TAG, "not PowOS's shade: not granted $missing (PowOS isn't the recents provider)")
            return false
        }
        val runtime = (service.applicationContext as App).runtime
        runtime.start()
        val h = ShellHost(shadeContext, null, runtime, MODE)
        h.bridge.shade =
            object : ShadeSlot {
                override fun closed() = hide()
            }
        host = h
        val root = Root(shadeContext).apply { addView(h.web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)) }
        root.visibility = View.GONE
        shade = root
        shadeParams = shadeLayout().also { shadeWm.addView(root, it) }
        val strip = Edge(edgeContext)
        edge = strip
        edgeParams = edgeLayout(statusBarHeight()).also { edgeWm.addView(strip, it) }
        @Suppress("DEPRECATION")
        service.registerReceiver(closer, IntentFilter(Intent.ACTION_CLOSE_SYSTEM_DIALOGS))
        current = this
        flags()
        Log.i(TAG, "PowOS's shade in place of SystemUI's")
        return true
    }

    /** SystemUI's shade back: the windows gone, the flags lifted. */
    fun stop() {
        if (current === this) current = null
        runCatching { service.unregisterReceiver(closer) }
        edge?.let { runCatching { edgeWm.removeView(it) } }
        shade?.let { runCatching { shadeWm.removeView(it) } }
        edge = null
        shade = null
        host?.destroy()
        host = null
        disable(0, 0)
    }

    /**
     * SystemUI's state flags (ILauncherProxy.onSystemUiStateChanged, QuickStepContract.SYSUI_STATE_*): the lock screen
     * showing, its panel open.
     */
    fun systemUiState(state: Long) {
        keyguard = state and SYSUI_KEYGUARD_SHOWING != 0L
        val systemPanel = state and (SYSUI_NOTIFICATION_PANEL_EXPANDED or SYSUI_QUICK_SETTINGS_VISIBLE) != 0L
        if (lent) {
            if (systemPanel) {
                lentSeenOpen = true
            } else if (lentSeenOpen) {
                lent = false
            }
        }
        // Locked: PowOS's shade isn't shown over the lock screen (its notifications would be).
        if (keyguard && shown) settle(false)
        flags()
        edgeLayoutChanged()
    }

    /**
     * The page asked for SystemUI's own panel (its quick settings): the flags lifted until it has been open and shut
     * again, PowOS's shade going up meanwhile. If it never opens, they're back after a moment.
     */
    fun lend() {
        lent = true
        lentSeenOpen = false
        if (shown) settle(false)
        flags()
        edge?.postDelayed({
            if (lent && !lentSeenOpen) {
                lent = false
                flags()
            }
        }, LEND_TIMEOUT_MS)
    }

    private fun flags() {
        if (keyguard || lent) disable(0, 0) else disable(DISABLE_EXPAND, DISABLE2_QUICK_SETTINGS or DISABLE2_NOTIFICATION_SHADE)
    }

    /**
     * HACK: StatusBarManager.disable/disable2 are hidden API (reflected past the checks: [HiddenApi]); STATUS_BAR, the
     * permission they take, is granted. Real fix: none public - kiosk and setup flows use them the same way.
     */
    private fun disable(
        what: Int,
        what2: Int,
    ) {
        runCatching {
            HiddenApi.allow()
            statusBar.javaClass.getMethod("disable", Int::class.javaPrimitiveType).invoke(statusBar, what)
            statusBar.javaClass.getMethod("disable2", Int::class.javaPrimitiveType).invoke(statusBar, what2)
        }.onFailure { Log.w(TAG, "can't set the status bar's disable flags", it) }
    }

    /** Shows the shade window (the pull started): touchable and focused (Back reaches the page). */
    private fun show() {
        val root = shade ?: return
        if (shown) return
        shown = true
        root.visibility = View.VISIBLE
        shadeParams?.let {
            it.flags = it.flags and (WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE).inv()
            shadeWm.updateViewLayout(root, it)
        }
    }

    /** The page shut it (shade.closed): the window hidden, its page kept for the next pull. */
    private fun hide() {
        val root = shade ?: return
        if (!shown) return
        shown = false
        root.visibility = View.GONE
        shadeParams?.let {
            it.flags = it.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            shadeWm.updateViewLayout(root, it)
        }
    }

    private fun drag(q: Double) = host?.bridge?.emit("shade.drag", JSONObject().put("q", q))

    private fun settle(open: Boolean) = host?.bridge?.emit("shade.settle", JSONObject().put("open", open))

    private fun shadeLayout() =
        WindowManager.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
            TYPE_SHADE,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            title = "PowOS shade"
            gravity = Gravity.TOP or Gravity.START
            fitInsetsTypes = 0
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }

    private fun edgeLayout(height: Int) =
        WindowManager.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            height,
            TYPE_EDGE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            title = "PowOS top edge"
            gravity = Gravity.TOP or Gravity.START
            fitInsetsTypes = 0
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }

    /** The strip as the state says: touchable only while it's PowOS's shade to pull and the status bar shows. */
    private fun edgeLayoutChanged(height: Int? = null) {
        val strip = edge ?: return
        val p = edgeParams ?: return
        val touchable = statusBarShown && !keyguard && !lent
        val flags =
            if (touchable) p.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv() else p.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        val h = height ?: p.height
        if (flags == p.flags && h == p.height) return
        p.flags = flags
        p.height = h
        edgeWm.updateViewLayout(strip, p)
    }

    @SuppressLint("DiscouragedApi", "InternalInsetResource")
    private fun statusBarHeight(): Int {
        val res = service.resources
        val id = res.getIdentifier("status_bar_height", "dimen", "android")
        return if (id != 0) res.getDimensionPixelSize(id) else (24 * res.displayMetrics.density).toInt()
    }

    /** The shade window's root: Back reaches the page (it shuts the panel), as an activity's would. */
    private inner class Root(
        context: Context,
    ) : FrameLayout(context) {
        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            if (event.keyCode == KeyEvent.KEYCODE_BACK) {
                if (event.action == KeyEvent.ACTION_UP) host?.bridge?.emit("system.back", null)
                return true
            }
            return super.dispatchKeyEvent(event)
        }
    }

    /**
     * The top edge: a drag down from it pulls the shade, the page following the finger as home's swipe does (openness
     * = the distance over 60% of the screen; a flick or past a third opens it).
     */
    private inner class Edge(
        context: Context,
    ) : View(context) {
        private val slop = ViewConfiguration.get(context).scaledTouchSlop
        private var y0 = 0f
        private var dragging = false
        private var q = 0.0
        private var velocity: VelocityTracker? = null

        init {
            // The status bar's height (it changes on folding) and whether it shows: from the insets the window gets.
            setOnApplyWindowInsetsListener { _, insets ->
                statusBarShown = insets.isVisible(WindowInsets.Type.statusBars())
                val top = insets.getInsetsIgnoringVisibility(WindowInsets.Type.statusBars()).top
                edgeLayoutChanged(top.takeIf { it > 0 })
                insets
            }
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    y0 = e.rawY
                    dragging = false
                    q = 0.0
                    velocity = VelocityTracker.obtain().also { it.addMovement(e) }
                }
                MotionEvent.ACTION_MOVE -> {
                    velocity?.addMovement(e)
                    val dy = e.rawY - y0
                    if (!dragging && dy > slop) {
                        dragging = true
                        show()
                    }
                    if (dragging) {
                        val height = shade?.height?.takeIf { it > 0 } ?: resources.displayMetrics.heightPixels
                        q = (dy / (height * PULL_SPAN)).toDouble().coerceIn(0.0, 1.0)
                        drag(q)
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    val v = velocity
                    velocity = null
                    if (dragging) {
                        // px/ms of the screen, in CSS px as the page's flick threshold is.
                        val vy = v?.let { it.computeCurrentVelocity(1); it.yVelocity / resources.displayMetrics.density } ?: 0f
                        val open = e.actionMasked == MotionEvent.ACTION_UP && (vy > FLICK || (vy >= -FLICK && q > OPEN_AT))
                        settle(open)
                    }
                    v?.recycle()
                    dragging = false
                }
            }
            return true
        }
    }

    companion object {
        private const val TAG = "PowosShade"
        private const val MODE = "shade"

        /** The running shade host, for the bridge (system.notifications lends SystemUI's panel through it). */
        var current: ShadeHost? = null
            private set

        // WindowManager.LayoutParams' hidden system types: above the status bar (15) and SystemUI's shade (17), and
        // between the two (16). Both take STATUS_BAR_SERVICE (DisplayPolicy.validateAddingWindowLw).
        private const val TYPE_SHADE = 2017 // TYPE_STATUS_BAR_SUB_PANEL
        private const val TYPE_EDGE = 2041 // TYPE_STATUS_BAR_ADDITIONAL

        /** Hidden in the SDK: STATUS_BAR_SERVICE (signature|recents), STATUS_BAR (signature|privileged|recents). */
        private const val PERMISSION_STATUS_BAR_SERVICE = "android.permission.STATUS_BAR_SERVICE"
        private const val PERMISSION_STATUS_BAR = "android.permission.STATUS_BAR"

        // StatusBarManager's hidden disable flags.
        private const val DISABLE_EXPAND = 0x00010000
        private const val DISABLE2_QUICK_SETTINGS = 1
        private const val DISABLE2_NOTIFICATION_SHADE = 1 shl 2

        // QuickStepContract's SYSUI_STATE_* bits (this phone's SystemUI: getSystemUiStateString).
        private const val SYSUI_NOTIFICATION_PANEL_EXPANDED = 1L shl 2
        private const val SYSUI_KEYGUARD_SHOWING = 1L shl 6
        private const val SYSUI_QUICK_SETTINGS_VISIBLE = 1L shl 11

        /** As the page's: the pull's span (of the screen's height), a flick (CSS px/ms), the openness it opens at. */
        private const val PULL_SPAN = 0.6f
        private const val FLICK = 0.45f
        private const val OPEN_AT = 0.33

        private const val LEND_TIMEOUT_MS = 2000L
    }
}

/** What the shade page reaches through the bridge (shade.closed). */
interface ShadeSlot {
    /** The panel is shut: the window can go. */
    fun closed()
}
