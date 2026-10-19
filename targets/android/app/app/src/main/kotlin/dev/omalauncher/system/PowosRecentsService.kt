package dev.omalauncher.system

import android.app.Service
import android.content.Intent
import android.graphics.Region
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.util.Log
import com.android.systemui.shared.recents.ILauncherProxy

/**
 * PowOS as the phone's recents provider (docs/NATIVE-SYSTEM-UI.md, "Switcher and gestures"): the service SystemUI
 * binds in the package config_recentsComponentName names (action QUICKSTEP_SERVICE, guarded by STATUS_BAR_SERVICE so
 * only SystemUI can), as it binds the stock launcher's TouchInteractionService. Through it SystemUI hands over the
 * overview button ([ILauncherProxy.onOverviewToggle]: PowOS's switcher, [Switcher]) and its state, and while it's
 * bound PowOS's shade replaces SystemUI's ([ShadeHost]) - both use what the recents role grants.
 *
 * Three-button navigation only, for now: home is PowOS as the home app, back stays SystemUI's, the overview button
 * comes here. Gesture navigation needs an input monitor over the navigation bar's region
 * ([ILauncherProxy.onActiveNavBarRegionChanges]) and the recents transition (WM Shell's IRecentTasks, in
 * [onInitialize]'s bundle); without them, with gestures on, a swipe up does nothing.
 */
class PowosRecentsService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var shade: ShadeHost? = null

    /** SystemUI's ISystemUiProxy (for the gesture phase: the back gesture's events, the status bar's touches). */
    private var systemUi: IBinder? = null

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
                // Gesture navigation's region: not used until PowOS handles the gestures (three-button only so far).
            }

            override fun onInitialize(params: Bundle?) {
                systemUi = params?.getBinder(SYSTEM_UI_PROXY)
                Log.i(TAG, "SystemUI connected: ${params?.keySet()?.sorted()}")
                main.post {
                    // The switcher's page warmed now, so the first overview press shows it at once.
                    Switcher.page(this@PowosRecentsService)
                    if (shade == null) shade = ShadeHost(this@PowosRecentsService).takeIf { it.start() }
                }
            }

            override fun onSystemUiStateChanged(stateFlags: Long) {
                main.post { shade?.systemUiState(stateFlags) }
            }

            override fun onUnbind(reply: IBinder?) {
                // SystemUI waits for this before it binds a new instance (LauncherProxyService.mIsPrevServiceCleanedUp).
                main.post {
                    release()
                    reply?.let(::sendResult)
                }
            }
        }

    override fun onCreate() {
        super.onCreate()
        HiddenApi.allow()
    }

    override fun onBind(intent: Intent?): IBinder = proxy

    override fun onDestroy() {
        release()
        super.onDestroy()
    }

    private fun release() {
        shade?.stop()
        shade = null
        systemUi = null
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
