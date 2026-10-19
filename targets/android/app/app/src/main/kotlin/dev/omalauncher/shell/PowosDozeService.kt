package dev.omalauncher.shell

import android.service.dreams.DreamService
import android.util.Log
import android.view.Display
import dev.omalauncher.App

/**
 * The screen-off display (Android's doze component, docs/NATIVE-SYSTEM-UI.md): the shell's "aod" screen (shell/ui/
 * aod.tsx - the time, what's new, the battery) on the dark, low-power screen Android shows while the phone sleeps.
 * A thin host: the slot's window and its power state here, everything shown is the shell, hot-reloaded as anywhere.
 *
 * Android uses it as the doze component when the PowOS system module's overlay names it (config_dozeComponent); it's
 * also an ordinary screensaver (Settings > Display > Screen saver), which shows the same screen, just not dozing.
 */
class PowosDozeService : DreamService() {
    private var host: ShellHost? = null

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        isInteractive = false
        isFullscreen = true
        isScreenBright = false
        val runtime = (application as App).runtime
        runtime.start()
        host = ShellHost(this, null, runtime, MODE).also { setContentView(it.web) }
    }

    override fun onDreamingStarted() {
        super.onDreamingStarted()
        // Dozing (the panel's low-power mode, as SystemUI's DozeService) when Android started it as the doze
        // component; as a screensaver it just shows. HACK: canDoze/startDozing are hidden DreamService API - the doze
        // component's own (SystemUI calls them); reachable at our targetSdk, reflected so a release that closes them
        // leaves a plain dream. Real fix: none public - the doze component is a system role.
        runCatching {
            val canDoze = DreamService::class.java.getMethod("canDoze").invoke(this) as Boolean
            if (canDoze) {
                DreamService::class.java.getMethod("setDozeScreenState", Int::class.javaPrimitiveType).invoke(this, Display.STATE_DOZE)
                DreamService::class.java.getMethod("startDozing").invoke(this)
            }
            Log.i(TAG, "dreaming, dozing=$canDoze")
        }.onFailure { Log.w(TAG, "can't doze", it) }
    }

    override fun onDetachedFromWindow() {
        host?.destroy()
        host = null
        super.onDetachedFromWindow()
    }

    private companion object {
        const val TAG = "PowosDoze"
        const val MODE = "aod"
    }
}
