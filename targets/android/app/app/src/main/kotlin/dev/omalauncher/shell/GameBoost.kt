package dev.omalauncher.shell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import android.util.Log
import java.io.File

/**
 * The CPU boost while the user plays a game (board broforce-games-black-noise-flicker-artifacts-ove,
 * docs/research/broforce-fps.md): Broforce ran 20-38 fps CPU-bound - its main thread 95 % of one core, on gold/prime
 * cores OxygenOS' performance HAL held at 1.92 / 1.71 GHz of 2.80 / 3.19 GHz, migrating across cpu3-7, uclamp.min 0.
 * Generic for every game, never one title: while a game window ([WebWindows.isGame]: steam_app_<id>, or a Game desktop
 * file) is the one in front - its window task Android's top activity, or its web window in home full screen or the
 * one last pressed - assets/game-boost.sh (as root) lifts the big clusters' clocks, puts the game's threads in a
 * uclamp.min 75 % group, its hottest thread on the prime core and the rest on the other big cores; everything goes back
 * when the game leaves the front, closes, or the screen turns off. Thermal limits are never touched.
 *
 * Crash-safe: once a second, while boosted, the app renews a lease file; the root holder restores on its own when the
 * lease is [LEASE_S] s old (the app died, froze or was killed) or the game's processes are gone.
 */
object GameBoost {
    private const val TAG = "PowosGameBoost"
    const val TICK_MS = 1000L

    /** The holder restores this long after the lease's last renewal (game-boost.sh LEASE_S). */
    const val LEASE_S = 4

    /** What a tick does. */
    sealed class Action {
        /** Boost [appId] (a game came to the front, or another game took its place: the script swaps them). */
        data class Engage(
            val appId: String,
        ) : Action()

        /** Put everything back ([why]: the log's reason). */
        data class Restore(
            val why: String,
        ) : Action()

        /** Still the same game in front: the lease renewed. */
        object Renew : Action()

        /** No game, nothing boosted. */
        object Idle : Action()
    }

    /** The state machine: one game boosted at a time, only while it is in front and the screen is on. */
    class Machine {
        /** The game boosted now, null: none. */
        var engaged: String? = null
            private set

        fun step(
            front: String?,
            screenOn: Boolean,
        ): Action {
            val want = front?.takeIf { screenOn }
            val was = engaged
            return when {
                want == null && was == null -> Action.Idle
                want == null -> {
                    engaged = null
                    Action.Restore(if (!screenOn) "screen off" else "no game in front")
                }
                want != was -> {
                    engaged = want
                    Action.Engage(want)
                }
                else -> Action.Renew
            }
        }
    }

    /** A web window as [webFront] needs it. */
    data class WebWin(
        val id: Int,
        val appId: String,
        val game: Boolean,
        val closed: Boolean,
        val minimised: Boolean,
        val full: Boolean,
    )

    /**
     * The game whose web window the user plays: while home is in front, a game's open, unminimised window that is full
     * screen, or the one last pressed ([focused]). Its app id, else null.
     */
    fun webFront(
        homeInFront: Boolean,
        wins: List<WebWin>,
        focused: Int,
    ): String? {
        if (!homeInFront) return null
        val games = wins.filter { it.game && !it.closed && !it.minimised }
        return (games.firstOrNull { it.full } ?: games.firstOrNull { it.id == focused })?.appId
    }

    /**
     * The game in front: home's web window one ([web]), else the front window task's app ([task], KWin's app id) if it
     * is a game's ([WebWindows.isGame] with its desktop file's [categories]).
     */
    fun front(
        web: String?,
        task: String?,
        categories: (String) -> String?,
    ): String? = web ?: task?.takeIf { it.isNotBlank() && WebWindows.isGame(it, categories(it)) }

    /** The script's command line for [action] (null: no root call). */
    fun command(
        script: String,
        lease: String,
        action: Action,
    ): String? =
        when (action) {
            is Action.Engage -> "sh $script engage ${shellQuote(action.appId)} $lease"
            is Action.Restore -> "sh $script restore"
            else -> null
        }

    private fun shellQuote(s: String) = "'" + s.replace("'", "'\\''") + "'"

    private val machine = Machine()
    private var handler: Handler? = null
    private lateinit var script: File
    private lateinit var lease: File
    private lateinit var power: PowerManager
    private lateinit var categoriesOf: (String) -> String?
    private val tick = Runnable { tick() }

    /** Starts the ticks (rooted PowOS only; once). [categories]: a Linux app id's desktop categories, null if none. */
    @Synchronized
    fun start(
        context: Context,
        categories: (String) -> String?,
    ) {
        if (handler != null) return
        val app = context.applicationContext
        power = app.getSystemService(PowerManager::class.java)
        categoriesOf = categories
        lease = File(app.filesDir, "game-boost.lease")
        script = File(app.filesDir, "game-boost.sh")
        val h = Handler(HandlerThread("powos-game-boost").apply { start() }.looper)
        handler = h
        h.post {
            runCatching {
                val bytes = app.assets.open("game-boost.sh").use { it.readBytes() }
                if (!script.isFile || !script.readBytes().contentEquals(bytes)) script.writeBytes(bytes)
            }.onFailure { Log.w(TAG, "game-boost.sh not written: $it") }
            // A boost an earlier app process left (it was killed while a game played): its lease is stale, the holder
            // restores by itself within LEASE_S; nothing to do here.
        }
        // The screen: off restores at once (not a lease timeout later) and the ticks stop until it is on again.
        app.registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(
                    c: Context,
                    intent: Intent,
                ) {
                    h.removeCallbacks(tick)
                    h.post(tick)
                }
            },
            IntentFilter(Intent.ACTION_SCREEN_OFF).apply { addAction(Intent.ACTION_SCREEN_ON) },
        )
        h.post(tick)
    }

    private fun tick() {
        val h = handler ?: return
        val on = power.isInteractive
        val front =
            runCatching {
                front(WebWindows.frontGame(), andro.marchy.PowosWindowActivity.frontAppId(), categoriesOf)
            }.getOrNull()
        val action = machine.step(front, on)
        when (action) {
            is Action.Engage -> runCatching { lease.writeText("${System.currentTimeMillis()}\n") }
            is Action.Restore -> lease.delete()
            Action.Renew -> lease.setLastModified(System.currentTimeMillis())
            Action.Idle -> {}
        }
        command(script.path, lease.path, action)?.let { cmd ->
            val r = runCatching { andro.marchy.RootShell.run(cmd, null, 10_000) }.getOrNull()
            Log.i(TAG, "$action: ${r?.code} ${r?.output?.lines()?.lastOrNull().orEmpty()}")
        }
        h.removeCallbacks(tick)
        if (on) h.postDelayed(tick, TICK_MS)
    }
}
