package dev.omalauncher.system

import android.app.Service
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Region
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.util.Log
import android.view.Display
import com.android.systemui.shared.recents.ILauncherProxy
import com.android.systemui.shared.recents.ISystemUiProxy
import dev.omalauncher.system.gesture.CornerPull
import dev.omalauncher.system.gesture.EdgeGestures
import dev.omalauncher.system.gesture.GestureMonitor
import dev.omalauncher.system.gesture.NavGesture
import dev.omalauncher.system.gesture.RecentsTransition

/**
 * PowOS as the phone's recents provider (docs/NATIVE-SYSTEM-UI.md, "Switcher and gestures"): the service SystemUI
 * binds in the package config_recentsComponentName names (action QUICKSTEP_SERVICE, guarded by STATUS_BAR_SERVICE so
 * only SystemUI can), as it binds the stock launcher's TouchInteractionService. Through it SystemUI hands over the
 * overview button ([ILauncherProxy.onOverviewToggle]: PowOS's switcher, a layer of home's page, [Switcher]), its
 * state and its ISystemUiProxy, and while it's bound PowOS's shade replaces SystemUI's ([ShadeHost]) - all of it what
 * the recents role grants.
 *
 * - Three-button navigation: home is PowOS as the home app, back stays SystemUI's, the overview button comes here.
 * - Gesture navigation: PowOS's gesture input ([GestureMonitor], an input monitor on the display) takes the swipes from
 *   the bottom edge ([NavGesture]: home, the switcher, the previous app; the app's window following the finger through
 *   WM Shell's recents transition, [RecentsTransition]) and the shade's pull from the top ([ShadeHost.pull]). Back stays
 *   SystemUI's edge swipe, except on PowOS's edge handles ([EdgeGestures]: Good Lock-style edge swipes, Quick Tools).
 *   Up from a bottom corner over an app: home's pull-up panels ([CornerPull] -> [HomePull]: home's own launcher).
 */
class PowosRecentsService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var shade: ShadeHost? = null
    private var gestures: GestureMonitor? = null
    private var nav: NavGesture? = null
    private var edge: EdgeGestures? = null
    private var quickTools: QuickToolsHost? = null
    private var pet: PetOverlay? = null
    private var frames: WindowFrames? = null
    private var gestureRetries = 0

    /** SystemUI's last state flags and nav bar region (they can come before the gesture input is up). */
    private var systemUiState = 0L
    private var navRegion: Region? = null

    /** SystemUI's ISystemUiProxy: what the gestures call back (unpin, the switcher shown). */
    private var systemUi: ISystemUiProxy? = null

    private val proxy =
        object : ILauncherProxy.Stub() {
            override fun onOverviewToggle() {
                main.post { Switcher.toggle(this@PowosRecentsService) }
            }

            override fun onOverviewShown(triggeredFromAltTab: Boolean) {
                main.post { Switcher.show(this@PowosRecentsService) }
            }

            override fun onOverviewHidden(
                triggeredFromAltTab: Boolean,
                triggeredFromHomeKey: Boolean,
            ) {
                main.post { Switcher.hide() }
            }

            override fun onActiveNavBarRegionChanges(activeRegion: Region?) {
                main.post {
                    navRegion = activeRegion
                    nav?.activeRegion = activeRegion
                }
            }

            override fun onInitialize(params: Bundle?) {
                val sysui = params?.getBinder(SYSTEM_UI_PROXY)?.let { ISystemUiProxy.Stub.asInterface(it) }
                val recentTasks = params?.getBinder(RecentsTransition.RECENT_TASKS)
                // The switcher's split screen (WM Shell's).
                Tasks.splitScreen = params?.getBinder("com.android.wm.shell.splitscreen.ISplitScreen")
                // WM Shell's transitions: a floating window's content follows a drag (TaskLeash).
                TaskLeash.shell = params?.getBinder(TaskLeash.KEY)
                // Every desktop window's surface, for the in-task frames (TaskSurfaces; fed by TaskLeash).
                TaskSurfaces.start(this@PowosRecentsService)
                Log.i(TAG, "SystemUI connected: ${params?.keySet()?.sorted()}")
                main.post {
                    RecentsWatchdog.onConnected()
                    systemUi = sysui
                    // The desktop home has no web page to carry the switcher: the recents activity's is warmed now.
                    Switcher.prepare(this@PowosRecentsService)
                    if (shade == null) shade = ShadeHost(this@PowosRecentsService).takeIf { it.start() }
                    if (quickTools == null) quickTools = runCatching { QuickToolsHost(this@PowosRecentsService).takeIf { it.begin() } }.onFailure { Log.w(TAG, "no Quick Tools", it) }.getOrNull()
                    // The pet over apps (docs/PET.md step d).
                    if (pet == null) pet = runCatching { PetOverlay(this@PowosRecentsService).takeIf { it.start() } }.onFailure { Log.w(TAG, "no pet overlay", it) }.getOrNull()
                    pet?.homeVisible(Switcher.homeVisible)
                    // PowOS's frames on the floating app windows (OxygenOS draws none).
                    if (frames == null) frames = runCatching { WindowFrames(this@PowosRecentsService).also { it.start() } }.onFailure { Log.w(TAG, "no window frames", it) }.getOrNull()
                    startGestures()
                    nav?.systemUi = sysui
                    edge?.systemUi = sysui
                    nav?.recentTasks = recentTasks
                }
            }

            override fun onSystemUiStateChanged(stateFlags: Long) {
                main.post {
                    shade?.systemUiState(stateFlags)
                    pet?.systemUiState(stateFlags)
                    frames?.systemUiState(stateFlags)
                    systemUiState = stateFlags
                    nav?.systemUiState = stateFlags
                    edge?.systemUiState = stateFlags
                }
            }

            override fun onUnbind(reply: IBinder?) {
                // SystemUI waits for this before it binds a new instance (LauncherProxyService.mIsPrevServiceCleanedUp).
                main.post {
                    release()
                    RecentsWatchdog.onDisconnected()
                    reply?.let(::sendResult)
                }
            }
        }

    override fun onCreate() {
        super.onCreate()
        HiddenApi.allow()
    }

    override fun onBind(intent: Intent?): IBinder = proxy

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        nav?.refresh()
        edge?.refresh()
        frames?.refresh()
        // Folded: no floating window stays freeform at its inner-screen bounds on the cover.
        FoldedWindows.displayChanged(this)
    }

    override fun onDestroy() {
        release()
        RecentsWatchdog.onDisconnected()
        super.onDestroy()
    }

    /** The gesture input: the bottom edge's swipes and the shade's pull, on one input monitor. */
    private fun startGestures() {
        if (gestures != null) return
        val n =
            nav ?: NavGesture(this).also {
                it.systemUiState = systemUiState
                it.activeRegion = navRegion
                nav = it
            }
        val e =
            edge ?: EdgeGestures(this).also {
                it.systemUiState = systemUiState
                it.systemUi = systemUi
                edge = it
            }
        // The bottom corners' pull-up panels wrap gesture navigation's swipes (both start in the bar's strip). The shade's
        // pull last: on home it follows any finger down on home's body, so the bar's strip and the edge handles come first.
        val consumers = listOfNotNull(CornerPull(this, n), e, shade?.pull)
        gestures = GestureMonitor.start(this, Display.DEFAULT_DISPLAY, consumers)
        // The handles are drawn only where the gestures can be taken.
        if (gestures != null) e.start()
        shade?.monitored = gestures != null
        // Still bound but no monitor (the input system refused it for now): try again shortly, a few times.
        if (gestures == null && systemUi != null && gestureRetries++ < 5) main.postDelayed({ if (systemUi != null) startGestures() }, 2_000L)
        if (gestures != null) gestureRetries = 0
        Log.i(TAG, if (gestures != null) "gesture input on" else "no gesture input: gesture navigation does nothing, the shade's strip takes the pull")
    }

    private fun release() {
        gestures?.dispose()
        gestures = null
        nav = null
        edge?.stop()
        edge = null
        quickTools?.stop()
        quickTools = null
        pet?.stop()
        pet = null
        frames?.stop()
        frames = null
        shade?.stop()
        shade = null
        systemUi = null
        TaskLeash.shell = null
    }

    /** IRemoteCallback.sendResult(Bundle) on [callback] (a hidden interface: its one call, made by hand). */
    private fun sendResult(callback: IBinder) {
        val data = Parcel.obtain()
        try {
            data.writeInterfaceToken(REMOTE_CALLBACK)
            data.writeTypedObject(Bundle(), 0)
            callback.transact(IBinder.FIRST_CALL_TRANSACTION, data, null, IBinder.FLAG_ONEWAY)
        } catch (e: Exception) {
            Log.w(TAG, "can't answer SystemUI's unbind", e)
        } finally {
            data.recycle()
        }
    }

    private companion object {
        const val TAG = "PowosRecents"

        /** The bundle key onInitialize keys SystemUI's ISystemUiProxy by: its descriptor (QuickStepContract.addInterface). */
        const val SYSTEM_UI_PROXY = "com.android.systemui.shared.recents.ISystemUiProxy"
        const val REMOTE_CALLBACK = "android.os.IRemoteCallback"
    }
}
