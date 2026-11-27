package dev.omalauncher.shell

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
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
 * also an ordinary screensaver (Settings > Display > Screen saver, "when charging"; no root): then it shows StandBy
 * (shell/ui/standby.tsx: a big clock and two swipeable stacks - the lock glance's alarm, event and weather, what's
 * playing - in landscape, the aod screen upright), interactive: swipes are the stacks', a tap ends the dream (the
 * lock screen under it shows). In the dark (the light sensor) the page turns its dim red night look ("standby.dark").
 */
class PowosDozeService : DreamService() {
    private var host: ShellHost? = null
    private var glance: LockGlance.Watch? = null
    private val main = Handler(Looper.getMainLooper())

    /** Started as the doze component (Android dozes the panel), not as a screensaver. */
    private val dozing by lazy {
        runCatching { DreamService::class.java.getMethod("canDoze").invoke(this) as Boolean }.getOrDefault(false)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // StandBy takes swipes (its stacks) and taps (standby.exit); the doze screen none (a touch wakes the phone).
        isInteractive = !dozing
        isFullscreen = true
        isScreenBright = false
        val runtime = (application as App).runtime
        runtime.start()
        host =
            ShellHost(this, null, runtime, if (dozing) MODE else STANDBY).also {
                if (!dozing) it.bridge.standbyExit = { main.post { finish() } }
                setContentView(it.web)
            }
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
        if (dozing) return
        // StandBy's glance stack: the lock face's state and pushes (LockGlance), the same "lock.glance".
        glance = LockGlance.Watch(this) { host?.bridge?.emit("lock.glance", it) }.also { it.start() }
        getSystemService(SensorManager::class.java)?.let { sm ->
            sm.getDefaultSensor(Sensor.TYPE_LIGHT)?.let { sm.registerListener(light, it, SensorManager.SENSOR_DELAY_NORMAL) }
        }
    }

    override fun onDreamingStopped() {
        glance?.stop()
        glance = null
        runCatching { getSystemService(SensorManager::class.java)?.unregisterListener(light) }
        super.onDreamingStopped()
    }

    /** The last dark/light sent: the page hears a change, with a margin so a room at the edge doesn't flicker it. */
    private var dark: Boolean? = null
    private val light =
        object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                val lux = e.values.firstOrNull() ?: return
                val now = if (dark == true) lux < DARK_LUX * 2 else lux < DARK_LUX
                if (now == dark) return
                dark = now
                host?.bridge?.emit("standby.dark", now)
            }

            override fun onAccuracyChanged(s: Sensor?, accuracy: Int) = Unit
        }

    override fun onDetachedFromWindow() {
        host?.destroy()
        host = null
        super.onDetachedFromWindow()
    }

    private companion object {
        const val TAG = "PowosDoze"
        const val MODE = "aod"
        const val STANDBY = "standby"

        /** Below this (lux) the room is dark: StandBy's night look. */
        const val DARK_LUX = 5f
    }
}
