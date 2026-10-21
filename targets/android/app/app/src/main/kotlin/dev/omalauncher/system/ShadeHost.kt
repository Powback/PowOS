package dev.omalauncher.system

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.os.PowerManager
import android.service.notification.NotificationListenerService.Ranking
import android.service.notification.StatusBarNotification
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
import dev.omalauncher.system.gesture.GestureConsumer
import dev.omalauncher.system.gesture.shadeOpens
import dev.omalauncher.widgets.runtime.MediaListener
import org.json.JSONObject
import kotlin.math.abs

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
 *   panel (system.notifications: OnePlus's control center, from PowOS's control center's own button) until that one is
 *   closed again. A pull on the status bar's right half brings PowOS's control center (shell/ui/control.tsx), the rest
 *   its notifications ("shade.panel").
 * - The pull: PowOS's gesture input ([pull], on the recents provider's input monitor - GestureMonitor) sees a finger go
 *   down on the status bar without taking it, and takes it (the status bar gets a cancel) only once it's dragged down:
 *   taps on the status bar stay SystemUI's (OnePlus's live capsules). Dragged down, the finger goes to the page
 *   ("shade.drag" { q }, "shade.settle" { open }) as home's own swipe does. Not while the status bar is hidden (a
 *   full-screen app's top edge is its own: its first swipe brings the bars back, SystemUI's).
 * - A strip over the status bar (TYPE_STATUS_BAR_ADDITIONAL, above the status bar and below SystemUI's shade window)
 *   tells the status bar's height and whether it shows (its insets). Never touchable while the monitor runs; without
 *   the monitor ([monitored] false) it takes the pull itself, see the HACK below.
 * - The shade: TYPE_STATUS_BAR_SUB_PANEL, full screen and transparent (the page dims with its own scrim), above the
 *   status bar and SystemUI's windows. The page is kept warm: the window stays added, hidden while the shade is shut
 *   (the page says so: shade.closed), so the next pull shows it at once.
 * - Heads-up banners: SystemUI shows none while its shade is off (its peek needs the panel enabled - its log says
 *   "PEEK=off|disabled panel" for every notification), so the shade shows them ([peek]): for a notification that
 *   would have had one (Notifications.peeks), the shade window comes up as a strip at the top - its height the page's
 *   banner's ("shade.peekHeight"), touchable, never focused (the app below keeps the keyboard) - and the page shows
 *   the banner ("shade.peek"): a tap opens it, up puts it away, down pulls the whole shade ("shade.expand"). Not on
 *   the lock screen (SystemUI's flags are lifted there, its own heads-up shows) nor with the screen off.
 *
 * Needs what the recents provider is granted (STATUS_BAR_SERVICE for the window types, STATUS_BAR for the flags):
 * [PowosRecentsService] runs it while SystemUI is bound to it.
 *
 * HACK (fallback only, when the input monitor can't be had - [monitored] false): the strip then takes the status bar's
 * touches itself, so a tap on something SystemUI shows there doesn't reach it. Real fix: the monitor, which is what
 * runs whenever MONITOR_INPUT is granted (it comes with the recents role, like everything here).
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

    /** The status bar is showing: false while a full-screen app hides it (the pet over apps keeps out then). */
    var statusBarShown = true
        private set(value) {
            if (field == value) return
            field = value
            PetOverlay.current?.update()
        }
    private var shown = false

    /** The window is up as a heads-up banner's strip ([peek]), not the whole shade. */
    private var peeking = false
    private val power = service.getSystemService(PowerManager::class.java)

    /** The status bar's height (px), from the strip's insets. */
    private var stripHeight = 0

    /**
     * PowOS's gesture input runs ([pull] gets the status bar's touches from the input monitor): the strip stays out of
     * the way. False: the strip takes the pull itself (the HACK above).
     */
    var monitored = false
        set(value) {
            field = value
            edgeLayoutChanged()
        }

    /** The pull under way (from the monitor or the strip). */
    private val pulling = Pull()

    /** Home pressed (or the switcher) while the shade is down: it goes up, as SystemUI's does. The screen off: a banner goes. */
    private val closer =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                if (intent.action == Intent.ACTION_SCREEN_OFF) {
                    if (peeking) unpeek()
                    return
                }
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

                override fun expand() = expandPeek()

                override fun peekHeight(px: Int) = sizePeek(px)
            }
        host = h
        watchdog =
            dev.omalauncher.shell.PageWatchdog(h.web, "PowOS shade") {
                if (peeking) host?.bridge?.emit("shade.peek", null)
                hide()
            }
        val root = Root(shadeContext).apply { addView(h.web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)) }
        root.visibility = View.GONE
        shade = root
        shadeParams = shadeLayout().also { shadeWm.addView(root, it) }
        val strip = Edge(edgeContext)
        edge = strip
        stripHeight = statusBarHeight()
        edgeParams = edgeLayout(stripHeight).also { edgeWm.addView(strip, it) }
        // Out of the way at once if the gesture input already runs.
        edgeLayoutChanged()
        @Suppress("DEPRECATION")
        service.registerReceiver(closer, IntentFilter(Intent.ACTION_CLOSE_SYSTEM_DIALOGS).apply { addAction(Intent.ACTION_SCREEN_OFF) })
        current = this
        MediaListener.posted = { sbn, ranking -> root.post { peek(sbn, ranking) } }
        flags()
        Log.i(TAG, "PowOS's shade in place of SystemUI's")
        return true
    }

    /** SystemUI's shade back: the windows gone, the flags lifted. */
    fun stop() {
        if (current === this) current = null
        MediaListener.posted = null
        runCatching { service.unregisterReceiver(closer) }
        edge?.let { runCatching { edgeWm.removeView(it) } }
        watchdog?.stop()
        watchdog = null
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
                // SystemUI never told of its panel open (its state bits): the flags back, which shuts it if it is.
                Log.w(TAG, "SystemUI's panel never showed as open; PowOS's shade back")
                lent = false
                flags()
            }
        }, LEND_TIMEOUT_MS)
    }

    /**
     * SystemUI's own panel, opened: its control center ([settings], OnePlus's quick settings) or its notifications. The
     * flags lent first; the expand a moment after, so SystemUI has the lifted flags before it's asked to open.
     * HACK: StatusBarManager.expandSettingsPanel / expandNotificationsPanel are hidden API (EXPAND_STATUS_BAR, granted).
     * Real fix: PowOS's own quick settings page (shell/ui/notifications.tsx's row grown into the whole control center).
     */
    @SuppressLint("WrongConstant")
    fun openSystemPanel(settings: Boolean) {
        lend()
        (edge ?: shade)?.postDelayed({
            runCatching {
                HiddenApi.allow()
                statusBar.javaClass.getMethod(if (settings) "expandSettingsPanel" else "expandNotificationsPanel").invoke(statusBar)
            }.onFailure { Log.w(TAG, "can't open SystemUI's panel", it) }
        }, EXPAND_DELAY_MS)
    }

    /** PowOS's shade is down (or coming down): other gestures leave the screen alone meanwhile. */
    val isShown get() = shown

    /**
     * Brings the shade down without a pull (an edge gesture): its control center ([control]) or its notifications.
     * False when it isn't PowOS's to show now (locked, lent to SystemUI).
     */
    fun openPanel(control: Boolean): Boolean {
        val h = host ?: return false
        if (keyguard || lent) return false
        h.bridge.emit("shade.panel", JSONObject().put("panel", if (control) "control" else "notifications"))
        show()
        settle(true)
        return true
    }

    /** Shuts PowOS's shade if it's down (a swipe up from the bottom edge): true if it was. */
    fun closeIfOpen(): Boolean {
        if (!shown) return false
        settle(false)
        return true
    }

    /** Whether a finger down at [y] (display px) may be the shade's pull. */
    private fun pullable(y: Float): Boolean {
        val edge = stripHeight.coerceAtLeast((24 * service.resources.displayMetrics.density).toInt())
        if (y > edge) return false
        val ok = host != null && !shown && !keyguard && !lent && statusBarShown
        // A finger down on the status bar that isn't a pull: why, as it's the first thing to ask when the shade won't come.
        if (!ok) Log.i(TAG, "not pulling: host=${host != null} shown=$shown keyguard=$keyguard lent=$lent statusBarShown=$statusBarShown")
        return ok
    }

    /**
     * The shade's pull on PowOS's gesture input (GestureMonitor): a finger down on the status bar is followed, and taken
     * once it's dragged down.
     */
    val pull =
        object : GestureConsumer {
            override fun onDown(e: MotionEvent): Boolean {
                if (!pullable(e.rawY)) return false
                // The status bar's right half pulls the control center, the rest the notifications - as on OnePlus's.
                val control = e.rawX > shadeWm.currentWindowMetrics.bounds.width() * CONTROL_SPLIT
                host?.bridge?.emit("shade.panel", JSONObject().put("panel", if (control) "control" else "notifications"))
                pulling.down(e)
                return true
            }

            override fun onEvent(e: MotionEvent): GestureConsumer.Verdict = shadeEvent(e)

            private fun shadeEvent(e: MotionEvent): GestureConsumer.Verdict =
                when (e.actionMasked) {
                    MotionEvent.ACTION_MOVE ->
                        when (pulling.move(e)) {
                            PullMove.STARTED -> GestureConsumer.Verdict.TAKE
                            PullMove.NOT_A_PULL -> GestureConsumer.Verdict.DROP
                            PullMove.NONE -> GestureConsumer.Verdict.FOLLOW
                        }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        pulling.up(e)
                        GestureConsumer.Verdict.DROP
                    }
                    else -> GestureConsumer.Verdict.FOLLOW
                }
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

    /**
     * Shows the shade window (the pull started), the whole screen - but not yet touchable or focused: the pull's touches
     * are the gesture input's, and the window only takes touches once the shade has settled open and its page answered
     * ([armOpen]). A page that can't (it never loaded, it hangs) must never leave an invisible window over the screen
     * eating every touch - it did, over the lock face (2026-10-20); [watchdog] takes the window away then.
     */
    private fun show() {
        val root = shade ?: return
        if (shown) return
        shown = true
        peeking = false
        root.visibility = View.VISIBLE
        setFlags(touchable = false, focusable = false, height = ViewGroup.LayoutParams.MATCH_PARENT)
        watchdog?.start()
    }

    /** The shade settled open: touchable and focused (Back reaches the page) once its page answers it's alive. */
    private fun armOpen() {
        val web = host?.web ?: return
        dev.omalauncher.shell.PageWatchdog.probe(web) { alive, why ->
            if (!shown) return@probe
            if (alive) {
                setFlags(touchable = true, focusable = true, height = ViewGroup.LayoutParams.MATCH_PARENT)
            } else {
                Log.w(TAG, "shade page isn't answering ($why): the shade goes")
                hide()
            }
        }
    }

    /** The shade settled shut: the page hides the window itself (shade.closed); should it not, the host does. */
    private fun armShut() {
        val root = shade ?: return
        root.removeCallbacks(shutGone)
        root.postDelayed(shutGone, SHUT_MAX_MS)
    }

    private val shutGone =
        Runnable {
            if (shown) {
                Log.w(TAG, "shade settled shut but its page never said closed: the window goes")
                hide()
            }
        }

    private fun setFlags(
        touchable: Boolean,
        focusable: Boolean,
        height: Int,
    ) {
        val root = shade ?: return
        shadeParams?.let {
            var f = it.flags
            f = if (touchable) f and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv() else f or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            f = if (focusable) f and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv() else f or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            if (f == it.flags && height == it.height) return
            it.flags = f
            it.height = height
            shadeWm.updateViewLayout(root, it)
        }
    }

    /** Whether the page answers, while the window is up (the shade or its banner): no answer, the window goes. */
    private var watchdog: dev.omalauncher.shell.PageWatchdog? = null

    /** The page shut it (shade.closed, the shade or its banner): the window hidden, its page kept for the next pull. */
    private fun hide() {
        val root = shade ?: return
        watchdog?.stop()
        root.removeCallbacks(shutGone)
        root.removeCallbacks(peekGone)
        if (!shown && !peeking) return
        shown = false
        peeking = false
        blur.set(0f)
        root.visibility = View.GONE
        setFlags(touchable = false, focusable = false, height = ViewGroup.LayoutParams.MATCH_PARENT)
    }

    /**
     * A notification was posted: if it would have had SystemUI's heads-up (Notifications.peeks), the banner - the shade
     * window as a strip at the top, touchable but not focusable, and the page told ("shade.peek").
     */
    private fun peek(
        sbn: StatusBarNotification,
        ranking: Ranking,
    ) {
        val h = host ?: return
        val root = shade ?: return
        val notifications = (service.applicationContext as App).runtime.widgets.notifications
        if (!notifications.peeks(sbn, ranking)) return
        // The shade down shows it already; locked, SystemUI's own heads-up does (its flags are lifted); screen off: none.
        if (shown || keyguard || lent || !power.isInteractive) return
        val item = notifications.item(sbn)
        if (!peeking) {
            peeking = true
            root.visibility = View.VISIBLE
            // Not touchable until the page says how tall its banner is (shade.peekHeight: it drew it); never focusable.
            setFlags(touchable = false, focusable = false, height = stripHeight + (PEEK_HEIGHT_DP * service.resources.displayMetrics.density).toInt())
            watchdog?.start()
        }
        h.bridge.emit("shade.peek", h.bridge.notificationJson(item))
        // The page puts the banner away itself (shade.closed); should it never, the strip mustn't stay over the top.
        root.removeCallbacks(peekGone)
        root.postDelayed(peekGone, PEEK_MAX_MS)
        Log.i(TAG, "banner for ${sbn.packageName} (${sbn.notification.channelId})")
    }

    /** The banner's strip as tall as the page's banner ([px], from the window's top). */
    private fun sizePeek(px: Int) {
        if (!peeking || px <= 0 || shade == null) return
        setFlags(touchable = true, focusable = false, height = px)
    }

    /** The banner pulled down (or its Reply): the whole shade, open. */
    private fun expandPeek() {
        if (!peeking && !shown) return
        show()
        settle(true)
    }

    private val peekGone = Runnable { if (peeking) unpeek() }

    /** The banner put away without the page (the screen went off, or the page never did). */
    private fun unpeek() {
        host?.bridge?.emit("shade.peek", null)
        hide()
    }

    /**
     * What's behind the shade (the app, home) blurred as it comes down, as SystemUI's shade blurs it: the shade page
     * only tints its panel over it (shell/ui/glass.ts, html.glass-behind). Not for the banner (a strip of the window).
     */
    private val blur = dev.omalauncher.shell.WindowBlur({ shade })

    private fun drag(q: Double) {
        if (shown) blur.set(q.toFloat())
        host?.bridge?.emit("shade.drag", JSONObject().put("q", q))
    }

    private fun settle(open: Boolean) {
        if (shown) blur.set(if (open) 1f else 0f)
        host?.bridge?.emit("shade.settle", JSONObject().put("open", open))
        if (!shown) return
        if (open) armOpen() else armShut()
    }

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
        val touchable = !monitored && statusBarShown && !keyguard && !lent
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
     * The pull, wherever its touches come from (the monitor, or the strip as the fallback): a drag down from the top edge
     * pulls the shade, the page following the finger as home's swipe does (openness = the distance over 60% of the
     * screen; a flick or past a third opens it: [shadeOpens]).
     */
    private inner class Pull {
        private val slop = ViewConfiguration.get(shadeContext).scaledTouchSlop
        private var x0 = 0f
        private var y0 = 0f
        private var dragging = false
        private var q = 0.0
        private var velocity: VelocityTracker? = null

        fun down(e: MotionEvent) {
            x0 = e.rawX
            y0 = e.rawY
            dragging = false
            q = 0.0
            velocity?.recycle()
            velocity = VelocityTracker.obtain().also { it.addMovement(e) }
        }

        fun move(e: MotionEvent): PullMove {
            velocity?.addMovement(e)
            val dx = e.rawX - x0
            val dy = e.rawY - y0
            var result = PullMove.NONE
            if (!dragging) {
                if (dy > slop && dy >= abs(dx)) {
                    dragging = true
                    show()
                    result = PullMove.STARTED
                } else if (abs(dx) > slop || dy < -slop) {
                    return PullMove.NOT_A_PULL
                }
            }
            if (dragging) {
                val height = shade?.height?.takeIf { it > 0 } ?: service.resources.displayMetrics.heightPixels
                q = (dy / (height * PULL_SPAN)).toDouble().coerceIn(0.0, 1.0)
                drag(q)
            }
            return result
        }

        fun up(e: MotionEvent) {
            val v = velocity
            velocity = null
            if (dragging) {
                // px/ms of the screen, in CSS px as the page's flick threshold is.
                val vy = v?.let { it.computeCurrentVelocity(1); it.yVelocity / service.resources.displayMetrics.density } ?: 0f
                settle(shadeOpens(vy, q, cancelled = e.actionMasked != MotionEvent.ACTION_UP))
            }
            v?.recycle()
            dragging = false
        }
    }

    /**
     * The strip over the status bar: tells the status bar's height and whether it shows (its insets). It takes the pull's
     * touches only without the input monitor (the HACK in the class comment).
     */
    private inner class Edge(
        context: Context,
    ) : View(context) {
        init {
            // The status bar's height (it changes on folding) and whether it shows: from the insets the window gets.
            setOnApplyWindowInsetsListener { _, insets ->
                val top = insets.getInsetsIgnoringVisibility(WindowInsets.Type.statusBars()).top
                // Hidden only if this window is told of a status bar at all (top > 0) and it's hidden: a window above the
                // status bar, as this one is, may be given no status bar inset, and that's not a full-screen app.
                statusBarShown = top == 0 || insets.isVisible(WindowInsets.Type.statusBars())
                if (top > 0) stripHeight = top
                edgeLayoutChanged(top.takeIf { it > 0 })
                insets
            }
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> pulling.down(e)
                MotionEvent.ACTION_MOVE -> pulling.move(e)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> pulling.up(e)
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

        /** As the page's: the pull's span (of the screen's height). A flick and the openness it opens at: [shadeOpens]. */
        private const val PULL_SPAN = 0.6f

        private const val LEND_TIMEOUT_MS = 5000L

        /** Lifted flags first, then the expand. */
        private const val EXPAND_DELAY_MS = 80L

        /** The status bar's right part (from this fraction of its width) pulls the control center, as on OnePlus's. */
        private const val CONTROL_SPLIT = 0.5f

        /** The banner's strip below the status bar until the page says how tall its banner is ("shade.peekHeight"). */
        private const val PEEK_HEIGHT_DP = 150

        /** Settled shut, the page says closed within this (its slide up is ~300 ms): else the host hides the window. */
        private const val SHUT_MAX_MS = 1_500L

        /** Longer than the page keeps any banner (shade.tsx): past this the host takes it away itself. */
        private const val PEEK_MAX_MS = 30_000L
    }
}

/** How a move of the shade's pull went. */
private enum class PullMove {
    /** Not decided yet. */
    NONE,

    /** It's a pull: the shade came down with it. */
    STARTED,

    /** Sideways or up: not a pull. */
    NOT_A_PULL,
}

/** What the shade page reaches through the bridge (shade.closed, shade.expand, shade.peekHeight). */
interface ShadeSlot {
    /** The panel (or the heads-up banner) is shut: the window can go. */
    fun closed()

    /** The heads-up banner pulled down: the whole shade. */
    fun expand()

    /** The heads-up banner is [px] (device px) tall from the window's top: the window as tall. */
    fun peekHeight(px: Int)
}
