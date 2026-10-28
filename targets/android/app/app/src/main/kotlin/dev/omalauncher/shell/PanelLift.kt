package dev.omalauncher.shell

import android.content.ComponentCallbacks
import android.content.Context
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.SurfaceControl
import android.view.View
import android.view.WindowManager
import androidx.annotation.RequiresApi
import dev.omalauncher.system.AppWindows
import dev.omalauncher.system.HiddenApi
import dev.omalauncher.system.WindowFrames

/**
 * Home's panels above the floating windows (the user's rule: the shade, control center, launcher/drawer, search, AI
 * overlay and edit mode are ALWAYS above floating windows, and a window under a panel is blurred as the home behind it
 * is). The shade, control center and AI overlay are windows of their own above the task area already; the drawer (its
 * search, chat) and edit mode draw in home's own window, which WM keeps in the task area under every freeform task.
 *
 * So while the page says a home panel is open ("p.lift 1": ui/panellift.ts), home's window surface is stacked just
 * under [anchor] - a 1x1 transparent, untouchable TYPE_APPLICATION_OVERLAY window of PowOS's own, which sits above the
 * task area and under the status bar and the shade - with `Transaction.setRelativeLayer(home, anchor, -1)`. The windows
 * stay live and resumed and WM's state is untouched; home's frost blur regions (GlassBlur) then blur the windows as
 * they blur the wallpaper, touch follows (input is ordered by SurfaceFlinger's tree) and so does the IME. The window
 * bars and grips (overlays too, above the tasks) go under home in the same transaction, relative to it, so they are
 * blurred with their windows; no frame is added or re-added meanwhile (WindowFrames.underPanel). Dropped -
 * `setLayer(surface, 0)`, the z WM gives a window under its token and caches, so WM never has to resend it - when the
 * page says so ("p.lift 0"), on every launch (AppWindows.options), when the switcher comes up, when home stops, on a
 * fold (apps aren't windows there) and on a page reload. The page is told each time ("p.lifted 1|0").
 *
 * HACK: SurfaceControl.Transaction.setRelativeLayer and ViewRootImpl.getSurfaceControl are hidden (WM Shell's and
 * SystemUI's own calls), reflected past the checks ([HiddenApi]); without them nothing is lifted and windows cover the
 * drawer as before. Real fix: the drawer and edit mode in a window of their own above the task area (a rewrite of
 * home's gestures and state), or a platform-signed WM Shell hook that raises home's task over the freeform ones.
 */
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
internal class PanelLift(
    private val web: View,
    /** To the page: "p.lifted 1|0". */
    private val tell: (String) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    /** Overlays need a window context (the anchor); the configuration (a fold) is the app's. */
    private val context: Context =
        web.context.applicationContext.let { app ->
            app.createWindowContext(app.getSystemService(android.hardware.display.DisplayManager::class.java).getDisplay(android.view.Display.DEFAULT_DISPLAY), WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
        }

    /** The window home's surface is stacked under: made once, kept. */
    private var anchor: View? = null

    /** What the page asks for (a home panel is open). */
    private var wanted = false

    /** Lifted now: home's surface and the frame surfaces stacked with it. */
    private var lifted: List<SurfaceControl>? = null

    private val config =
        object : ComponentCallbacks {
            override fun onConfigurationChanged(c: Configuration) {
                if (!AppWindows.floating(context)) drop("fold")
            }

            override fun onLowMemory() = Unit
        }

    init {
        context.registerComponentCallbacks(config)
        current = this
    }

    /** The page's "p.hello": its own state starts over (a reload); nothing lifted. */
    fun hello() =
        main.post {
            wanted = false
            drop("page reload")
            makeAnchor()
        }

    /** The page's "p.lift 1|0". */
    fun want(on: Boolean) =
        main.post {
            wanted = on
            if (on) lift(ANCHOR_TRIES) else drop("panel closed")
        }

    /** Home is back in front (started, the switcher gone): lifted again if the page still has a panel open. */
    fun again() = main.post { if (wanted && lifted == null) lift(ANCHOR_TRIES) }

    /** Off, at once, from any thread (main: in this call). */
    fun drop(why: String) {
        if (Looper.myLooper() != main.looper) {
            main.post { drop(why) }
            return
        }
        val was = lifted ?: return tell("p.lifted 0")
        lifted = null
        runCatching {
            SurfaceControl.Transaction().apply { was.filter { it.isValid }.forEach { setLayer(it, 0) } }.apply()
        }.onFailure { Log.w(TAG, "can't put home back under the windows", it) }
        keyboardTouches(false)
        WindowFrames.current?.underPanel = false
        Log.i(TAG, "home under the windows again ($why)")
        tell("p.lifted 0")
    }

    fun close() {
        drop("closed")
        runCatching { context.unregisterComponentCallbacks(config) }
        anchor?.let { a -> runCatching { context.getSystemService(WindowManager::class.java).removeViewImmediate(a) } }
        anchor = null
        if (current === this) current = null
    }

    private fun lift(tries: Int) {
        if (!wanted || lifted != null) return
        // Folded, apps are full screen: no window is over home's panels.
        val set = relativeLayer?.takeIf { AppWindows.floating(context) } ?: return tell("p.lifted 0")
        val home = GlassBlur.surfaceOf(web) ?: return tell("p.lifted 0")
        val over = anchor?.let(GlassBlur::surfaceOf) ?: return waitForAnchor(tries)
        val frames = WindowFrames.current
        frames?.underPanel = true
        val bars = frames?.frameViews().orEmpty().mapNotNull(GlassBlur::surfaceOf)
        val ok = stack(set, home, over, bars)
        if (!ok) frames?.underPanel = false
        if (ok) lifted = listOf(home) + bars
        if (ok) keyboardTouches(true)
        tell(if (ok) "p.lifted 1" else "p.lifted 0")
    }

    /** While lifted: home's window takes no touch where the keyboard is (the listener; null when not lifted). */
    private var keyboardHole: Any? = null

    /**
     * WM layers the IME just above its target app's own surface, which stays where it was in the task area; lifted,
     * home's surface is above the keyboard, and input follows SurfaceFlinger's order - every tap on a key went to home,
     * which blurred the search and closed the keyboard (2026-10-28, the user: "the keyboard gets dismissed when I try to
     * use it"; e2e-launcher-keyboard.sh step 04 reproduces it, `dumpsys input`: HomeShell above InputMethod). So while
     * lifted, home's touchable region leaves out the keyboard's area (its ime inset) and those taps reach the keyboard
     * under it, drawn through home's transparent pixels as before. FLAG_NOT_TOUCH_MODAL: WM ignores the region of a
     * modal activity window (the task bounds instead); home is full screen, so nothing outside it changes.
     * HACK: ViewTreeObserver's internal-insets listener is hidden (the IME's and SystemUI's own touch regions), reflected
     * past the checks. Real fix: home's panels above the windows natively - desktop mode as KWin + the PowOS shell
     * (docs/DESKTOP-KWIN-NATIVE.md) - with no surface lifted over the IME.
     */
    private fun keyboardTouches(on: Boolean) {
        if (on == (keyboardHole != null)) return
        runCatching {
            HiddenApi.allow()
            val type = Class.forName("android.view.ViewTreeObserver\$OnComputeInternalInsetsListener")
            if (on) holeOn(type) else holeOff(type)
            web.rootView.requestLayout()
        }.onFailure { Log.w(TAG, "can't pass the keyboard's taps through home (on=$on)", it) }
    }

    private fun holeOn(type: Class<*>) {
        val listener = keyboardListener(type)
        android.view.ViewTreeObserver::class.java.getMethod("addOnComputeInternalInsetsListener", type).invoke(web.viewTreeObserver, listener)
        homeWindow()?.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
        keyboardHole = listener
    }

    private fun holeOff(type: Class<*>) {
        val listener = keyboardHole ?: return
        keyboardHole = null
        homeWindow()?.clearFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
        val observer = web.viewTreeObserver.takeIf { it.isAlive } ?: return
        android.view.ViewTreeObserver::class.java.getMethod("removeOnComputeInternalInsetsListener", type).invoke(observer, listener)
    }

    /** Home's activity window (the WebView's context may be wrapped). */
    private fun homeWindow(): android.view.Window? =
        generateSequence(web.context) { (it as? android.content.ContextWrapper)?.baseContext }
            .filterIsInstance<android.app.Activity>().firstOrNull()?.window

    /** The hidden OnComputeInternalInsetsListener, as a proxy calling [leaveOutKeyboard]. */
    private fun keyboardListener(type: Class<*>): Any =
        java.lang.reflect.Proxy.newProxyInstance(type.classLoader, arrayOf(type)) { proxy, method, args ->
            when (method.name) {
                "onComputeInternalInsets" -> leaveOutKeyboard(args!![0])
                "equals" -> proxy === args?.getOrNull(0)
                "hashCode" -> System.identityHashCode(proxy)
                else -> "PanelLift.keyboardHole"
            }
        }

    /** One InternalInsetsInfo: touchable everywhere but the keyboard's inset at the bottom. */
    private fun leaveOutKeyboard(info: Any) {
        val root = web.rootView
        val ime = root.rootWindowInsets?.getInsets(android.view.WindowInsets.Type.ime())?.bottom ?: 0
        info.javaClass.getMethod("setTouchableInsets", Int::class.javaPrimitiveType).invoke(info, TOUCHABLE_INSETS_REGION)
        (info.javaClass.getField("touchableRegion").get(info) as android.graphics.Region)
            .set(0, 0, root.width, (root.height - ime).coerceAtLeast(0))
    }

    /** The anchor's window isn't drawn yet (just made): its surface a frame or two later. */
    private fun waitForAnchor(tries: Int) {
        makeAnchor()
        if (tries > 0) {
            main.postDelayed({ lift(tries - 1) }, FRAME_MS)
            return
        }
        Log.w(TAG, "no anchor window: not lifted")
        tell("p.lifted 0")
    }

    /** One transaction: [home] just under [over], the frames' [bars] under home, bottom-most first. */
    private fun stack(
        set: java.lang.reflect.Method,
        home: SurfaceControl,
        over: SurfaceControl,
        bars: List<SurfaceControl>,
    ): Boolean =
        try {
            SurfaceControl.Transaction().apply {
                set.invoke(this, home, over, -1)
                bars.forEachIndexed { i, b -> set.invoke(this, b, home, i - bars.size) }
            }.apply()
            Log.i(TAG, "home over the windows (${bars.size} frame windows under it)")
            true
        } catch (e: Exception) {
            Log.w(TAG, "can't lift home over the windows", e)
            false
        }

    private fun makeAnchor() {
        if (anchor != null) return
        val view = View(context)
        val params =
            WindowManager.LayoutParams(
                1,
                1,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSPARENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                setTitle("PowOS panel anchor")
                fitInsetsTypes = 0
            }
        runCatching {
            context.getSystemService(WindowManager::class.java).addView(view, params)
            anchor = view
        }.onFailure { Log.w(TAG, "can't add the anchor window", it) }
    }

    companion object {
        private const val TAG = "PowosPanelLift"
        private const val ANCHOR_TRIES = 30
        private const val FRAME_MS = 16L
        /** ViewTreeObserver.InternalInsetsInfo.TOUCHABLE_INSETS_REGION (hidden). */
        private const val TOUCHABLE_INSETS_REGION = 3

        /** Home's, while its page is up. */
        @Volatile var current: PanelLift? = null
            private set

        /** Every launch, the switcher, home's stop: home's panels aren't over the windows any more. */
        fun dropNow(why: String) = current?.drop(why)

        private val relativeLayer: java.lang.reflect.Method? by lazy {
            runCatching {
                HiddenApi.allow()
                SurfaceControl.Transaction::class.java.getMethod("setRelativeLayer", SurfaceControl::class.java, SurfaceControl::class.java, Int::class.javaPrimitiveType)
            }.onFailure { Log.w(TAG, "no relative layers on this Android", it) }.getOrNull()
        }
    }
}
