package dev.omalauncher.system

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Resources
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Keeps SystemUI bound to [PowosRecentsService] - and with it PowOS's gesture input (the swipe-up to home and the
 * switcher, the shade's pull), which lives only while SystemUI holds that binding.
 *
 * SystemUI's LauncherProxyService binds the recents provider at boot, on a user switch and when the provider's package
 * changes; when our process dies it retries with a backoff, but after a run of quick deaths (the low-memory killer
 * taking the app several times in a row, 2026-10-20 20:23-20:25) it was left unbound for good (mBound=false, no retry
 * pending): no input monitor, swipes did nothing until something re-triggered the bind.
 *
 * The trigger is the one SystemUI listens for: PACKAGE_CHANGED for this package. Flipping the service component
 * between ENABLED and DEFAULT (both mean enabled: nothing about it changes) with DONT_KILL_APP makes PackageManager send
 * it, no root and no restart. Checked at process start, on screen-on/unlock and a few seconds after SystemUI lets go of
 * the service - no polling. Only while PowOS is the recents provider (config_recentsComponentName names our package).
 *
 * HACK: a no-op component flip stands in for SystemUI retrying the bind itself. Real fix: LauncherProxyService
 * re-binding on every provider death without giving up (a SystemUI patch in the system module), or PowOS's own
 * system UI holding the binding.
 */
object RecentsWatchdog {
    private const val TAG = "PowosRecentsWatchdog"
    private const val GRACE_MS = 5_000L
    private const val MIN_POKE_GAP_MS = 30_000L
    private const val MAX_POKE_GAP_MS = 10 * 60_000L

    private val main = Handler(Looper.getMainLooper())
    private lateinit var app: Context
    private var started = false

    /** SystemUI has called onInitialize on the bound service (and not unbound it since). */
    @Volatile var connected = false
        private set

    private var lastPoke = 0L
    private var pokeGap = MIN_POKE_GAP_MS

    private val check = Runnable { checkNow() }

    fun start(context: Context) {
        if (started) return
        started = true
        app = context.applicationContext
        val filter = IntentFilter(Intent.ACTION_SCREEN_ON).apply { addAction(Intent.ACTION_USER_PRESENT) }
        app.registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) = schedule(2_000L)
            },
            filter,
        )
        schedule(GRACE_MS)
    }

    /** From [PowosRecentsService]: SystemUI connected (onInitialize). */
    fun onConnected() {
        connected = true
        pokeGap = MIN_POKE_GAP_MS
        main.removeCallbacks(check)
    }

    /** From [PowosRecentsService]: SystemUI let go of it (onUnbind/onDestroy) - give it a moment to rebind by itself. */
    fun onDisconnected() {
        connected = false
        schedule(GRACE_MS)
    }

    private fun schedule(delayMs: Long) {
        if (!started) return
        main.removeCallbacks(check)
        main.postDelayed(check, delayMs)
    }

    private fun checkNow() {
        if (connected || !isRecentsProvider()) return
        val now = SystemClock.elapsedRealtime()
        val since = now - lastPoke
        if (lastPoke != 0L && since < pokeGap) {
            schedule(pokeGap - since)
            return
        }
        lastPoke = now
        Log.w(TAG, "SystemUI isn't bound to the recents service: asking it to rebind (PACKAGE_CHANGED)")
        poke()
        // Not connected by the next check: try again, backing off (a SystemUI that refuses shouldn't be hammered).
        pokeGap = (pokeGap * 2).coerceAtMost(MAX_POKE_GAP_MS)
        schedule(GRACE_MS)
    }

    private fun poke() {
        val pm = app.packageManager
        val service = ComponentName(app, PowosRecentsService::class.java)
        val next =
            if (pm.getComponentEnabledSetting(service) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            }
        runCatching { pm.setComponentEnabledSetting(service, next, PackageManager.DONT_KILL_APP) }
            .onFailure { Log.w(TAG, "can't poke SystemUI's recents binding", it) }
    }

    private fun isRecentsProvider(): Boolean {
        val res = Resources.getSystem()
        val id = res.getIdentifier("config_recentsComponentName", "string", "android")
        if (id == 0) return false
        val name = runCatching { res.getString(id) }.getOrNull() ?: return false
        return ComponentName.unflattenFromString(name)?.packageName == app.packageName
    }
}
