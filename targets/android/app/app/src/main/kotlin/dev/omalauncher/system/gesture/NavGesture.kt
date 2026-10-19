package dev.omalauncher.system.gesture

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.graphics.Region
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.WindowManager
import com.android.systemui.shared.recents.ISystemUiProxy
import dev.omalauncher.shell.PowosLockActivity
import dev.omalauncher.system.ShadeHost
import dev.omalauncher.system.Switcher
import dev.omalauncher.system.Tasks

/**
 * Gesture navigation's swipes from the bottom edge, PowOS's as the recents provider (docs/NATIVE-SYSTEM-UI.md): swipe
 * up for home, swipe up and hold for PowOS's switcher, along the bottom edge for the previous app. What the finger
 * means is [NavGestureClassifier]'s; this is the doing:
 *
 * - Only in gesture navigation (in three-button mode the bar's buttons are SystemUI's, and the overview button reaches
 *   PowOS through ILauncherProxy), only from the bar's strip at the bottom, and not while SystemUI says the system
 *   gestures are off: the lock screen or its bouncer, SystemUI's own shade, the device dozing, a full-screen app's
 *   hidden bar (its first swipe only brings the bar back - SystemUI's).
 * - A swipe up over an app: the app's window follows the finger ([RecentsTransition]) when WM Shell's recents transition
 *   can be had, toward its card in the switcher - a layer of home's own page that comes up behind it ([Switcher]) -
 *   and lands on home (let go), on its card (held: the switcher stays up, it's home's) or back full screen; without it
 *   (or over home) the swipe goes the plain way - a home intent, home with the switcher up, a task brought to the front.
 * - The screen pinned: only swipe up and hold does something - it unpins (ISystemUiProxy.stopScreenPinning), as
 *   Quickstep's.
 * - Back stays SystemUI's (its EdgeBackGestureHandler takes the left and right edges, whichever app is the recents
 *   provider: it runs while gesture navigation is on and its nav bar is attached, nothing about the provider).
 */
class NavGesture(
    private val service: Context,
) : GestureConsumer {
    /** SystemUI's: the calls made back (unpin, the switcher shown). Set once SystemUI connected. */
    var systemUi: ISystemUiProxy? = null

    /** WM Shell's IRecentTasks, for the recents transition (null: the plain way only). */
    var recentTasks: IBinder? = null

    /** SystemUI's QuickStepContract.SYSUI_STATE_* flags (ILauncherProxy.onSystemUiStateChanged). */
    var systemUiState = 0L

    /** The navigation bar's touch region SystemUI reports (ILauncherProxy.onActiveNavBarRegionChanges), display px. */
    var activeRegion: Region? = null

    private val display: Display = service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    private val displayContext = service.createDisplayContext(display)
    private val slop = ViewConfiguration.get(displayContext).scaledTouchSlop.toFloat()
    private var screen = Rect()
    private var classifier: NavGestureClassifier? = null
    private var transition: RecentsTransition? = null
    private var pinned = false

    /** Where the finger went down (screen px): the window follows it sideways. */
    private var downX = 0f

    /** The hold state last logged. */
    private var armedLogged = false

    /** Counts swipes: a fallback of one that ended (its transition called off) mustn't act once the next has begun. */
    private var swipe = 0

    /** The task the swipe began over (null: home, or PowOS's own screens). */
    private var from: Int? = null

    init {
        refresh()
    }

    /** The display's size changed (rotation, folding): the strip and the distances follow. */
    fun refresh() {
        screen = runCatching { displayContext.getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds }.getOrElse { Rect(0, 0, 1080, 2400) }
    }

    override fun onDown(e: MotionEvent): Boolean {
        if (!inStrip(e.rawX, e.rawY) || !gestural()) return false
        if (blocked()) {
            Log.i(TAG, "not now: SystemUI's state 0x${systemUiState.toString(16)} turns the system gestures off")
            return false
        }
        pinned = systemUiState and SYSUI_SCREEN_PINNED != 0L
        transition = null
        from = null
        downX = e.rawX
        armedLogged = false
        swipe++
        Log.i(TAG, "gesture: down at ${e.rawX.toInt()},${e.rawY.toInt()}")
        classifier = NavGestureClassifier(displayContext.resources.displayMetrics.density, screen.height().toFloat(), slop).also { it.down(e.rawX, e.rawY, e.eventTime) }
        return true
    }

    override fun onEvent(e: MotionEvent): GestureConsumer.Verdict {
        val c = classifier ?: return GestureConsumer.Verdict.DROP
        when (e.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                val axis = c.move(e.rawX, e.rawY, e.eventTime)
                if (axis != null) Log.i(TAG, "gesture: $axis after ${e.eventTime - e.downTime} ms")
                if (c.axis == NavGestureClassifier.Axis.UP && c.armed != armedLogged) {
                    armedLogged = c.armed
                    Log.i(TAG, "gesture: ${if (c.armed) "held (the switcher on release)" else "moving again"} at lift ${c.lift.toInt()} px")
                }
                when (axis) {
                    NavGestureClassifier.Axis.UP -> {
                        began()
                        return GestureConsumer.Verdict.TAKE
                    }
                    NavGestureClassifier.Axis.SIDEWAYS -> return if (pinned) drop() else GestureConsumer.Verdict.TAKE
                    NavGestureClassifier.Axis.IGNORED -> {
                        Log.i(TAG, "gesture: downwards from the bar - not ours")
                        return drop()
                    }
                    else -> {}
                }
                if (c.axis == NavGestureClassifier.Axis.UP) transition?.drag(c.lift, e.rawX - downX, c.homeness())
                return GestureConsumer.Verdict.FOLLOW
            }
            MotionEvent.ACTION_POINTER_DOWN ->
                // A second finger before the swipe is decided: not a system gesture (a pinch, two-finger scrolling).
                if (c.axis == NavGestureClassifier.Axis.NONE) return drop()
            MotionEvent.ACTION_UP -> {
                classifier = null
                val outcome = c.up(e.rawX, e.rawY, e.eventTime)
                ended(outcome, c.why)
                return GestureConsumer.Verdict.FOLLOW
            }
            MotionEvent.ACTION_CANCEL -> {
                classifier = null
                ended(NavGestureClassifier.Outcome.None, "cancelled (the touch was taken)")
                return GestureConsumer.Verdict.DROP
            }
        }
        return GestureConsumer.Verdict.FOLLOW
    }

    private fun drop(): GestureConsumer.Verdict {
        classifier = null
        return GestureConsumer.Verdict.DROP
    }

    /** The swipe up is on: the app under it starts following the finger, if it can. */
    private fun began() {
        if (pinned) return
        // Over home's switcher there's no app under the finger: home's (the plain way).
        from = if (Switcher.open && Switcher.homeVisible) null else Tasks.visible(service)
        val tasks = recentTasks ?: run { Log.i(TAG, "gesture: no recents transition - SystemUI gave no IRecentTasks"); return }
        if (from == null) run { Log.i(TAG, "gesture: over home (no app's window to move): the plain way"); return }
        if (!RecentsTransition.enabled(service) || Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) run { Log.i(TAG, "gesture: the recents transition is off"); return }
        // Behind the app: PowOS's web home (the switcher is a layer of it), or the recents activity (the desktop is home).
        val home = Switcher.target(service) ?: run { Log.i(TAG, "gesture: no recents transition - PowOS isn't the home app"); return }
        val t = RecentsTransition.start(service, tasks, home, Rect(screen)) ?: return
        // The window heads for its card in home's switcher layer, which follows the window frame by frame.
        t.slot = { Switcher.slot }
        t.onFrame = Switcher::drag
        Switcher.begin(from)
        transition = t
    }

    private fun ended(
        outcome: NavGestureClassifier.Outcome,
        why: String = "",
    ) {
        val t = transition
        transition = null
        val over = from
        Log.i(TAG, "gesture: $outcome (over task $over, animated ${t != null}; $why)")
        if (pinned) {
            if (outcome == NavGestureClassifier.Outcome.Switcher) runCatching { systemUi?.stopScreenPinning() }.onFailure { Log.w(TAG, "can't unpin", it) }
            return
        }
        when (outcome) {
            NavGestureClassifier.Outcome.Home -> {
                // Up with PowOS's shade down: the shade goes up, as SystemUI's does.
                if (ShadeHost.current?.closeIfOpen() == true) {
                    backToApp(t)
                    return
                }
                home(t)
            }
            NavGestureClassifier.Outcome.Switcher -> {
                if (systemUiState and SYSUI_OVERVIEW_DISABLED != 0L) return home(t)
                if (t == null) return switcher(over)
                // Onto its card; the transition finishes to home once the card shows the app's snapshot - home's page is
                // showing the switcher already, so it simply stays up.
                val mine = swipe
                t.end(RecentsTransition.End.SWITCHER, hold = { release -> Switcher.settle(over, release) }) { ok ->
                    Switcher.settled(ok)
                    if (ok) runCatching { systemUi?.onOverviewShown(false) } else if (swipe == mine) switcher(over)
                }
            }
            is NavGestureClassifier.Outcome.QuickSwitch -> {
                backToApp(t)
                quickSwitch()
            }
            NavGestureClassifier.Outcome.None -> backToApp(t)
        }
    }

    /** Let go for home: the window shrinks away, home's switcher layer collapses into home. */
    private fun home(t: RecentsTransition?) {
        if (t == null) return goHome()
        Switcher.end("home")
        // The recents activity was what came up behind the app (the desktop is home): home is started after it.
        val viaRecents = !Switcher.onHome
        val mine = swipe
        // Called off (a next swipe's transition took over): the plain home intent - unless that next swipe is under way.
        t.end(RecentsTransition.End.HOME) { ok -> if ((!ok || viaRecents) && swipe == mine) goHome() }
    }

    /** Back to the app (let go early, or the shade was put away instead): its window full screen again. */
    private fun backToApp(t: RecentsTransition?) {
        if (t == null) return
        Switcher.end("app")
        t.end(RecentsTransition.End.APP) {}
    }

    /** Home, as the home button: home comes to the front (its page closes the switcher, as for Home pressed). */
    private fun goHome() {
        runCatching {
            service.startActivity(
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED),
            )
        }.onFailure { Log.w(TAG, "can't go home", it) }
    }

    /** The switcher without the transition: home brought to the front with it up. */
    private fun switcher(over: Int?) {
        Switcher.show(service, over)
        runCatching { systemUi?.onOverviewShown(over == null) }
    }

    /** To the app used before this one (the newest task that isn't the one in front). */
    private fun quickSwitch() {
        val current = if (Switcher.open && Switcher.homeVisible) null else Tasks.visible(service)
        val previous = runCatching { Tasks.list(service, 6) }.getOrDefault(emptyList()).firstOrNull { it.id != current } ?: return
        // Over the switcher: it goes once home is out of sight (Switcher.homeStopped), not before the app is there.
        Tasks.open(service, previous.id)
    }

    private fun blocked(): Boolean {
        val s = systemUiState
        if (s and (SYSUI_KEYGUARD_SHOWING or SYSUI_BOUNCER_SHOWING or SYSUI_NOTIFICATION_PANEL_EXPANDED or SYSUI_QUICK_SETTINGS_VISIBLE or SYSUI_DEVICE_DOZING or SYSUI_HOME_DISABLED) != 0L) return true
        // PowOS's lock face over the lock screen (it occludes it: SystemUI clears KEYGUARD_SHOWING for OCCLUDED): the
        // swipe up from the bottom is the face's own unlock, not home's - taken here, it cut the face's swipe short.
        if (s and SYSUI_KEYGUARD_OCCLUDED != 0L && PowosLockActivity.current != null) return true
        return s and SYSUI_NAV_BAR_HIDDEN != 0L && s and SYSUI_ALLOW_GESTURE_IGNORING_BAR_VISIBILITY == 0L
    }

    /** Gesture navigation is on (config_navBarInteractionMode 2, the overlay SystemUI's setting switches). */
    @SuppressLint("DiscouragedApi")
    private fun gestural(): Boolean {
        val res = service.resources
        val id = res.getIdentifier("config_navBarInteractionMode", "integer", "android")
        val mode =
            if (id != 0) {
                res.getInteger(id)
            } else {
                runCatching { Settings.Secure.getInt(service.contentResolver, "navigation_mode") }.getOrDefault(0)
            }
        return mode == NAV_MODE_GESTURAL
    }

    /** In the navigation bar's strip: the gesture height at the bottom of the screen, or SystemUI's reported region. */
    @SuppressLint("DiscouragedApi", "InternalInsetResource")
    private fun inStrip(
        x: Float,
        y: Float,
    ): Boolean {
        if (activeRegion?.contains(x.toInt(), y.toInt()) == true) return true
        val res = service.resources
        val height =
            listOf("navigation_bar_gesture_height", "navigation_bar_frame_height", "navigation_bar_height")
                .firstNotNullOfOrNull { name -> res.getIdentifier(name, "dimen", "android").takeIf { it != 0 }?.let(res::getDimensionPixelSize)?.takeIf { it > 0 } }
                ?: (24 * res.displayMetrics.density).toInt()
        return y >= screen.bottom - height && x >= screen.left && x < screen.right
    }

    private companion object {
        const val TAG = "PowosNavGesture"
        const val NAV_MODE_GESTURAL = 2

        // QuickStepContract.SYSUI_STATE_* (this phone's SystemUI: QuickStepContract.getSystemUiStateString).
        const val SYSUI_SCREEN_PINNED = 1L shl 0
        const val SYSUI_NAV_BAR_HIDDEN = 1L shl 1
        const val SYSUI_NOTIFICATION_PANEL_EXPANDED = 1L shl 2
        const val SYSUI_BOUNCER_SHOWING = 1L shl 3
        const val SYSUI_KEYGUARD_SHOWING = 1L shl 6
        const val SYSUI_KEYGUARD_OCCLUDED = 1L shl 9
        const val SYSUI_OVERVIEW_DISABLED = 1L shl 7
        const val SYSUI_HOME_DISABLED = 1L shl 8
        const val SYSUI_QUICK_SETTINGS_VISIBLE = 1L shl 11
        const val SYSUI_ALLOW_GESTURE_IGNORING_BAR_VISIBILITY = 1L shl 17
        const val SYSUI_DEVICE_DOZING = 1L shl 21
    }
}
