package dev.omalauncher.system

import android.animation.ValueAnimator
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import dev.omalauncher.App
import dev.omalauncher.shell.ShellActivity
import dev.omalauncher.shell.ShellBridge
import dev.omalauncher.shell.ShellHost
import dev.omalauncher.shell.SwitcherActivity
import java.util.WeakHashMap
import org.json.JSONArray
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * PowOS's switcher (the recents screen), Quickstep's way: a layer of home itself (shell/ui/recents.tsx, over home's
 * page), not a window of its own. The recents transition a swipe up starts ([dev.omalauncher.system.gesture.RecentsTransition])
 * launches home behind the app; home's page shows the layer from the swipe's first frame - the task cards, the app's
 * own card where its window is shrinking to - and the window lands on that card. Let go there (up and hold) and the
 * transition finishes to home, whose page is already showing the switcher: nothing to start after it, nothing that
 * could come up in the wrong order.
 *
 * The native side only moves the real window and forwards: the gesture's progress to the page every frame, where the
 * app's card is from the page ([slot]), the fresh snapshot of that app before its window goes. The overview button
 * (and the recents activity, a trampoline) bring home to the front with the layer up.
 *
 * When home is the engine's desktop (HomeDesktop, the inner screen's "auto" home) there is no web home to carry it:
 * then the layer is the recents activity's own page ([SwitcherActivity] hosting the warm [page], mode=recents) and
 * that activity is the transition's target instead - Quickstep's fallback recents, the same layer and the same flow.
 *
 * Events to home's page: "recents.begin" { from, tasks } (a swipe up began over task [from]), "recents.drag"
 * { progress, x, y } (every frame of it), "recents.end" { to: "switcher" | "home" | "app", snapshot } (where it went),
 * "recents.show" { from, tasks } (shown without a swipe), "recents.hide" (home went away), "switcher.toggle".
 */
object Switcher {
    private const val TAG = "PowosSwitcher"
    private const val STALE_GESTURE_MS = 2_000L

    /** On the home intents that show the layer: home's page isn't sent "system.home" for them (it would close it). */
    const val EXTRA_RECENTS = "dev.omalauncher.recents"

    private val main = Handler(Looper.getMainLooper())

    /** Home's page (ShellActivity's, while it lives) and its window's refresh-rate boost. */
    private var shell: ShellBridge? = null
    private var shellBoost: ((Boolean) -> Unit)? = null
    private var shellBlur: ((Float) -> Unit)? = null

    /** The recents activity's page (kept warm: a swipe shows it from its first frame) and its window's boost. */
    private var warm: ShellHost? = null
    private var hostBoost: ((Boolean) -> Unit)? = null
    private var hostBlur: ((Float) -> Unit)? = null

    /** The layer is home's page's (PowOS's web home is the home app), else the recents activity's. */
    /** Home has reported its main page with no panel or app open. */
    var homeMainPage = false

    var onHome = true
        private set

    /** The page that carries the layer now. */
    private val home: ShellBridge? get() = if (onHome) shell else warm?.bridge
    private val boost: ((Boolean) -> Unit)? get() = if (onHome) shellBoost else hostBoost
    private val blur: ((Float) -> Unit)? get() = if (onHome) shellBlur else hostBlur

    /** How far the wallpaper behind the layer is blurred (0..1), and the animation taking it somewhere. */
    private var depth = 0f
    private var depthAnim: ValueAnimator? = null

    /** The window the depth was last set on: another one now (home's page vs the recents activity), the old one cleared. */
    private var blurOn: ((Float) -> Unit)? = null

    /**
     * The depth to the window the layer is on now. A layer that moved windows (onHome changed between a swipe's
     * blur and its settle) left its old window blurred - at 140 dp the whole wallpaper behind home ("my whole
     * background is blurred"): cleared first.
     */
    private fun applyDepth(v: Float) {
        val b = blur
        if (b !== blurOn) {
            blurOn?.invoke(0f)
            blurOn = b
        }
        b?.invoke(v)
    }

    private fun depthNow(v: Float) {
        depthAnim?.cancel()
        depthAnim = null
        depth = v
        applyDepth(v)
    }

    /** The blur eased to [target], as the page's layer settles (its 240 ms). */
    private fun depthTo(target: Float) {
        depthAnim?.cancel()
        depthAnim =
            ValueAnimator.ofFloat(depth, target).apply {
                duration = 240
                addUpdateListener {
                    depth = it.animatedValue as Float
                    applyDepth(depth)
                }
                // Settled shut: no window keeps any of it (an animation cut short, a stale target).
                if (target == 0f) {
                    addListener(
                        object : android.animation.AnimatorListenerAdapter() {
                            override fun onAnimationEnd(animation: android.animation.Animator) {
                                if (depth == 0f) {
                                    shellBlur?.invoke(0f)
                                    hostBlur?.invoke(0f)
                                }
                            }
                        },
                    )
                }
                start()
            }
    }

    /** The layer's page is started (on screen, or being brought there by a recents transition). */
    var homeVisible = false
        private set

    /** The layer is up (shown, or a swipe up is building it). */
    var open = false
        private set(v) {
            if (field == v) return
            field = v
            // Home's panels aren't over the windows while the switcher is up (PanelLift); back after, if still open.
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                if (v) dev.omalauncher.shell.PanelLift.dropNow("switcher") else dev.omalauncher.shell.PanelLift.current?.again()
            }
            // The floating windows' frames go while the switcher is up, and come back after.
            WindowFrames.current?.let { f -> android.os.Handler(android.os.Looper.getMainLooper()).post { f.refresh() } }
            // The web windows (a layer of home above its page) go too: the switcher is home's page, so they'd cover it.
            dev.omalauncher.shell.WebWindows.switcherOpen(v)
        }

    /** The task it was opened over (null: home). */
    var from: Int? = null
        private set

    /** A swipe up owns the layer (its begin until it ended): home's stop or start doesn't touch it meanwhile. */
    private var gesture = false

    /** When the swipe that owns the layer last did anything (begin, a frame, its ending): uptime ms. */
    private var gestureAt = 0L

    /** Where each page laid the first card out (screen px) and its corner radius. */
    private val slots = WeakHashMap<ShellBridge, Pair<Rect, Float>>()

    /** Where the app's own card is in the layer (screen px), as its page last laid it out; null before it said. */
    val slot: Rect? get() = home?.let { slots[it]?.first }

    /** The card's corner radius (screen px). */
    val slotRadius: Float get() = home?.let { slots[it]?.second } ?: 0f

    /** The task list laid out ahead for the next swipe ([homeStopped]); null before the first. */
    private var cachedTasks: JSONArray? = null

    /** The transition waiting for the page to show the app's card before its window goes (see [settle]). */
    private var release: (() -> Unit)? = null

    /** Home's page (ShellActivity) is up: the layer is its, while PowOS's web home is the home app. */
    fun attach(
        bridge: ShellBridge,
        refresh: (Boolean) -> Unit,
        blurBehind: (Float) -> Unit,
    ) {
        shell = bridge
        shellBoost = refresh
        shellBlur = blurBehind
    }

    fun detach(bridge: ShellBridge) {
        if (shell !== bridge) return
        shell = null
        shellBoost = null
        shellBlur = null
    }

    /** Home's activity went (not a configuration change): made again in the background, for the next swipe. */
    fun homeGone(context: Context) {
        main.post { if (shell == null && homeIsShell(context)) preloadHome(context) }
    }

    /** The recents activity shows the warm page (the desktop is home): its window's boost. */
    fun attachHost(
        refresh: ((Boolean) -> Unit)?,
        blurBehind: ((Float) -> Unit)?,
    ) {
        hostBoost = refresh
        hostBlur = blurBehind
    }

    /** The recents activity's page, made once and kept warm (no window of its own: the activity borrows it). */
    fun page(context: Context): ShellHost =
        warm ?: run {
            val app = context.applicationContext as App
            app.runtime.start()
            ShellHost(app, null, app.runtime, "recents").also { warm = it }
        }

    /**
     * SystemUI connected (the process just started): the page a swipe up shows is made now, not by the swipe - when
     * the desktop is home, the recents activity's warm page; else home itself, preloaded ([preloadHome]).
     */
    fun prepare(context: Context) {
        if (!homeIsShell(context)) page(context) else preloadHome(context)
    }

    /**
     * Home's activity made in the background, invisible (created and stopped, its page loaded and its tiles
     * rasterized), when it isn't there - as Quickstep preloads its recents activity: a swipe up after a restart (an
     * update, the process killed) otherwise waited for WM to create home and its WebView to load, ~160 ms, as long as
     * the swipe. IActivityTaskManager.preloadRecentsActivity, which the recents provider may call.
     *
     * HACK: preloadRecentsActivity is hidden (reflected past the checks, HiddenApi); nothing happens where it isn't
     * there. Real fix: none for an app - Quickstep calls it through the platform's own ActivityManagerWrapper.
     */
    fun preloadHome(context: Context) {
        if (shell != null) return
        val app = context.applicationContext
        thread(name = "powos-home-preload") {
            runCatching {
                HiddenApi.allow()
                val atm = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
                val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).setPackage(app.packageName)
                    .setComponent(ComponentName(app, "andro.marchy.HomeShell"))
                    .putExtra(EXTRA_RECENTS, true)
                atm.javaClass.getMethod("preloadRecentsActivity", Intent::class.java).invoke(atm, home)
                Log.i(TAG, "home preloaded")
            }.onFailure { Log.w(TAG, "can't preload home", it) }
        }
    }

    /** Whether PowOS's web home (ShellActivity, through .HomeShell) is the home app now. */
    fun homeIsShell(context: Context): Boolean {
        val info = context.packageManager.resolveActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo ?: return false
        return info.packageName == context.packageName && (info.targetActivity ?: info.name) == ShellActivity::class.java.name
    }

    /**
     * What a recents transition launches behind the app: PowOS's home when it's the web home (the layer is its page),
     * the recents activity when PowOS's desktop is home; null when another app is home (no transition: the plain way).
     */
    fun target(context: Context): ComponentName? {
        val info = context.packageManager.resolveActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo ?: return null
        if (info.packageName != context.packageName) return null
        onHome = (info.targetActivity ?: info.name) == ShellActivity::class.java.name
        if (!onHome) page(context)
        return if (onHome) ComponentName(info.packageName, info.name) else ComponentName(context, SwitcherActivity::class.java)
    }

    fun homeStarted(bridge: ShellBridge) {
        if (bridge !== home) return
        homeVisible = true
        PetOverlay.current?.homeVisible(true)
    }

    /** The layer's page went out of sight (an app opened from a card, or over it): the layer goes, unless a swipe owns it. */
    fun homeStopped(bridge: ShellBridge) {
        if (bridge !== home) return
        homeVisible = false
        PetOverlay.current?.homeVisible(false)
        hideStopped()
        // The app that just came up is the newest task now: the cards are laid out for the next swipe already (the
        // page renders them hidden, their snapshots load), so it shows them from its first frame.
        if (!gesture) bridge.emit("recents.tasks", JSONObject().put("tasks", tasks().also { cachedTasks = it }))
    }

    private fun hideStopped() {
        if (gesture || !open) return
        open = false
        from = null
        depthNow(0f)
        home?.emit("recents.hide", null)
    }

    /** The page laid the app's card out at [rect] (screen px). */
    fun slot(
        bridge: ShellBridge,
        rect: Rect,
        radius: Float,
    ) {
        slots[bridge] = rect to radius
    }

    // The swipe up (NavGesture).

    /** A swipe up began over task [over], its window following the finger: the layer comes up behind it. */
    fun begin(over: Int?) {
        gesture = true
        gestureAt = SystemClock.uptimeMillis()
        open = true
        from = over
        release = null
        boost?.invoke(true)
        // The list as laid out ahead (home's last stop): listing them now (binder calls, icons) held the first frames.
        val list = cachedTasks ?: tasks()
        Log.i(TAG, "begin over $over: ${if (home == null) "no page to show it" else "on ${if (onHome) "home's page" else "the recents activity"}"}, home ${if (homeVisible) "started" else "not started"}, slot $slot")
        home?.emit("recents.begin", JSONObject().put("from", over ?: JSONObject.NULL).put("tasks", list))
        // Then the list as it is now, off the gesture's thread (an app opened since home last stopped isn't in the
        // cached one): the page swaps it in under the swipe.
        val page = home
        if (cachedTasks != null && page != null) {
            thread(name = "powos-recents-list") {
                val fresh = page.recentTasks()
                main.post {
                    cachedTasks = fresh
                    if (gesture && page === home) page.emit("recents.update", JSONObject().put("tasks", fresh))
                }
            }
        }
    }

    /** A frame of the swipe: [progress] 0 (the app full screen) .. 1 (on its card); [dx], [dy] screen px. */
    fun drag(
        progress: Float,
        dx: Float,
        dy: Float,
        homeness: Float,
    ) {
        if (!gesture) return
        gestureAt = SystemClock.uptimeMillis()
        val d = density()
        depthNow(progress * (1f - homeness))
        // A string, not a JSONObject, sent now (this is the display frame's callback): every frame, as cheap as it can be.
        home?.emitNow("recents.drag", "{\"progress\":$progress,\"x\":${dx / d},\"y\":${dy / d},\"home\":$homeness}")
    }

    /**
     * The swipe was let go for home or back to the app: its window settles there (RecentsTransition's spring) and the
     * layer follows it frame by frame - it's no longer up (a fresh swipe or Home doesn't see it as open).
     */
    fun ending() {
        if (!gesture) return
        gestureAt = SystemClock.uptimeMillis()
        open = false
    }

    /** The window got where the swipe went (home or the app): the page lets the layer go - it's already there. */
    fun end(to: String) {
        if (!gesture) return
        gesture = false
        open = false
        from = null
        release = null
        boost?.invoke(false)
        depthTo(0f)
        home?.emit("recents.end", JSONObject().put("to", to))
    }

    /**
     * The swipe went to the switcher and the window is on its card: the app's snapshot is taken (its window as it is
     * now), the page puts it on the card - and only once the page says it shows it does [then] finish the transition,
     * so the window goes when the card under it looks the same: no frame without one or the other.
     */
    fun settle(
        over: Int?,
        then: () -> Unit,
    ) {
        val page = home
        if (!gesture || page == null) return then()
        release = then
        thread(name = "powos-recents-shot") {
            if (over != null) Tasks.capture(over)
            main.post {
                if (release !== then) return@post
                page.emit("recents.end", JSONObject().put("to", "switcher").put("from", over ?: JSONObject.NULL).put("snapshot", over?.let(::snapshotUrl) ?: JSONObject.NULL))
                // HACK: a safety net, not the mechanism: a page that never answers (hung, reloading) mustn't keep the
                // app's window on its card forever. Real fix: none needed while the page answers (it does in a frame).
                main.postDelayed({ if (release === then) ready(page) }, READY_TIMEOUT_MS)
            }
        }
    }

    /** The page shows the app's card ([settle]): the transition may finish. */
    fun ready(bridge: ShellBridge) {
        if (bridge !== home) return
        val r = release ?: return
        release = null
        r()
    }

    /**
     * The transition to the switcher is over (finished, or called off by an app that opened meanwhile); not [ok]: it
     * never came up - the layer the swipe opened is let go, so the plain way ([show]) can bring it up.
     */
    fun settled(ok: Boolean = true) {
        if (!gesture) return
        gesture = false
        boost?.invoke(false)
        release = null
        if (!ok) {
            open = false
            from = null
        }
        // An app came up instead: home is going (or gone) - the layer with it.
        if (!homeVisible) hideStopped()
    }

    // Without a swipe.

    /**
     * The switcher over the app in front ([over]): home comes to the front with the layer up. The app's snapshot is
     * taken first (while its window is still there), the page told, then home started: in that order, each after the
     * one before.
     */
    fun show(
        context: Context,
        over: Int? = if (open && homeVisible) from else Tasks.visible(context),
    ) {
        // A swipe whose transition never came back (WM Shell had no controller for it: its end, settled, never
        // called) left the layer owned - every switcher after it did nothing (2026-10-20). Owned but quiet for
        // [STALE_GESTURE_MS], with the finger long gone: let go of it.
        if (gesture && SystemClock.uptimeMillis() - gestureAt > STALE_GESTURE_MS) {
            Log.w(TAG, "show: the last swipe never ended (${SystemClock.uptimeMillis() - gestureAt} ms quiet): let go of it")
            gesture = false
            release = null
            boost?.invoke(false)
        }
        if (gesture) {
            Log.i(TAG, "show: a swipe owns the layer")
            return
        }
        // Up already by our account: the page is told again (its show is idempotent) - had it closed the layer without
        // telling us, a bare return here left the switcher dead from home.
        if (open && homeVisible) {
            Log.i(TAG, "show: up already - the page told again")
            home?.emit("recents.show", state())
            return
        }
        val app = context.applicationContext
        onHome = homeIsShell(app)
        if (!onHome) page(app)
        thread(name = "powos-recents-show") {
            if (over != null) Tasks.capture(over)
            main.post {
                if (gesture) return@post
                open = true
                from = over
                depthTo(1f)
                home?.emit("recents.show", state())
                // Started by the recents provider: allowed from the background (BackgroundActivityStartController's
                // "Recents Component").
                runCatching {
                    app.startActivity(
                        if (onHome) {
                            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).setPackage(app.packageName)
                                .putExtra(EXTRA_RECENTS, true)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                        } else {
                            Intent(app, SwitcherActivity::class.java).putExtra(EXTRA_RECENTS, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        },
                    )
                }.onFailure { Log.w(TAG, "can't bring the switcher up", it) }
            }
        }
    }

    /** The overview button: the switcher; pressed again while it shows, the page decides (it switches back). */
    fun toggle(context: Context) {
        if (open && homeVisible && !gesture) home?.emit("switcher.toggle", null) else show(context)
    }

    /** Home over the open switcher (the home swipe): the layer collapses into home with its own spring. */
    fun close() {
        if (gesture || !open) return
        open = false
        from = null
        depthTo(0f)
        home?.emit("recents.end", JSONObject().put("to", "home"))
    }

    /** Away (SystemUI's onOverviewHidden, a quick switch): the layer closes. */
    fun hide() {
        if (gesture || !open) return
        open = false
        from = null
        depthNow(0f)
        home?.emit("recents.hide", null)
    }

    /**
     * The page closed the layer itself (a tap beside the cards, Back, the last card removed): on home's page, home is
     * what's left; on the recents activity's, home is brought up (the activity goes once it's out of sight).
     */
    fun closed(
        context: Context,
        bridge: ShellBridge,
    ) {
        if (bridge !== home || gesture) return
        open = false
        from = null
        depthTo(0f)
        if (!onHome) {
            runCatching {
                context.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }.onFailure { Log.w(TAG, "can't go home", it) }
        }
    }

    /** For a page that just loaded (home started cold for the switcher): whether the layer is up, over what. */
    fun state(): JSONObject = JSONObject().put("open", open).put("from", from ?: JSONObject.NULL).put("tasks", tasks())

    private fun tasks(): JSONArray = home?.recentTasks() ?: JSONArray()

    private fun snapshotUrl(id: Int) = "${ShellHost.ORIGIN}/_task/$id?v=${System.nanoTime()}"

    private fun density(): Float = android.content.res.Resources.getSystem().displayMetrics.density

    private const val READY_TIMEOUT_MS = 1000L
}
