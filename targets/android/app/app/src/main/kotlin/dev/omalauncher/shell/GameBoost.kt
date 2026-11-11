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
 * when the game leaves the front, closes, or the screen turns off. Thermal limits are never touched; under the
 * vendor's thermal controller the boost marks the game in front ([VENDOR_GAME_KEY]) so the vendor applies its game table.
 *
 * Crash-safe: once a second, while boosted, the app renews a lease file; the root holder restores on its own when the
 * lease is [LEASE_S] s old (the app died, froze or was killed) or the game's processes are gone.
 */
object GameBoost {
    private const val TAG = "PowosGameBoost"
    const val TICK_MS = 1000L

    /** The holder restores this long after the lease's last renewal (game-boost.sh LEASE_S). */
    const val LEASE_S = 4

    /**
     * The vendor's game class: game-boost.sh sets this Settings.Global key to the boosted game's app id when it holds
     * a boost under a vendor thermal controller (OxygenOS' horae) and deletes it on every restore (the lease going
     * stale, the game exiting, `restore`, a killed holder's next engage/restore); the PowOS Vector module
     * (targets/android/oplus-hook, scope com.oplus.battery) then answers appType [VENDOR_APP_TYPE_GAME] for
     * com.powos.app, so the vendor's own game thermal table applies. Unset - home, every other use - the vendor's own.
     */
    const val VENDOR_GAME_KEY = "powos_game_front"

    /** com.oplus.battery's appType for a game: category_4 of /odm/etc/temperature_profile/sys_thermal_control_config*.xml. */
    const val VENDOR_APP_TYPE_GAME = 4

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
     * A launch boosts its game this long from the tap ([launching]): Wine's boot and the game's own load (Unity's Mono
     * JIT through FEX, ~1 core busy for 8 s) come before its window is the front task (board broforce-launch-time).
     */
    const val LAUNCH_S = 60L

    /**
     * The game launching now: the newest of [marks] (powos-open-task's run/game-launch/<app id>, its mtime = the tap,
     * as (app id, mtime ms)) younger than [LAUNCH_S] at [nowMs], if it is a game's ([WebWindows.isGame]); else null.
     */
    fun launching(
        marks: List<Pair<String, Long>>,
        nowMs: Long,
        categories: (String) -> String?,
    ): String? = launchingMark(marks, nowMs, categories)?.first

    /** [launching]'s mark itself: (app id, the tap's ms) - a launch's identity for [LaunchHold]. */
    fun launchingMark(
        marks: List<Pair<String, Long>>,
        nowMs: Long,
        categories: (String) -> String?,
    ): Pair<String, Long>? =
        marks
            .filter { (id, at) -> id.isNotBlank() && nowMs - at in 0..LAUNCH_S * 1000 }
            .sortedByDescending { it.second }
            .firstOrNull { (id, _) -> WebWindows.isGame(id, categories(id)) }

    /** A launch's hold ends this long after its window came when no first frame was seen ([LaunchHold]). */
    const val FRAME_CAP_S = 30L

    /** The first frame: the game's window task presented new frames on this many ticks in a row ([LaunchHold]). */
    const val FRAME_TICKS = 2

    /**
     * What a tick saw: the fresh launch [mark] ([launchingMark]), home's game web window [web], the front window task's
     * app id [task] and its presented frames [presents] (null: none known), at [nowMs].
     */
    data class Seen(
        val mark: Pair<String, Long>?,
        val web: String?,
        val task: String?,
        val presents: Long?,
        val nowMs: Long,
    )

    /**
     * A launch boosted from its tap to its FIRST FRAME, not to its window (board broforce-launch-time,
     * docs/research/game-launch-time.md 11-11): window -> first frame is ~9 s of Unity's load JIT-compiled through FEX,
     * the most clock-bound part of the launch. The launch mark ([launchingMark]) alone ends LAUNCH_S after the tap and
     * goes when powos-open-task drops it, whatever the game drew by then (11-11 Broforce: window 55 s after the tap
     * when Steam re-ran its install scripts). So the launched game stays the one in front from its tap until:
     * - its first frame: its window task in front presented new frames on [FRAME_TICKS] ticks in a row (a map / clear
     *   of Wine's window is one or two presents, a drawing game presents every tick; a re-created window's counter
     *   starts over, which never counts as a rise),
     * - [FRAME_CAP_S] after its window came with no such frames (a game that never presents through a task: a web
     *   window, a static menu),
     * - [LAUNCH_S] after the tap with no window of it in front (the launch failed or went elsewhere).
     * The screen going off and another game in front still win ([Machine], [front]); the holder still restores when the
     * game's processes are gone. One launch at a time: a new tap (another mark) starts a new hold; a released launch
     * never holds again.
     */
    class LaunchHold {
        /** The game held now, null: none. */
        var app: String? = null
            private set

        /** Why the last [step] released the hold (the log's), null: it didn't. */
        var released: String? = null
            private set

        private var mark: Pair<String, Long>? = null
        private var windowAt = -1L
        private var last = -1L
        private var rising = 0

        /** One tick ([seen]): the launched game held now, null: none. */
        fun step(seen: Seen): String? {
            released = null
            seen.mark?.takeIf { it != mark }?.let { start(it) }
            val a = app ?: return null
            if ((seen.web ?: seen.task) == a) window(seen.presents, seen.nowMs)
            val why = why(seen.nowMs)
            if (why != null) {
                app = null
                released = why
            }
            return app
        }

        private fun start(launch: Pair<String, Long>) {
            mark = launch
            app = launch.first
            windowAt = -1
            last = -1
            rising = 0
        }

        /** Its window in front: when it came, and whether its presents rose since the last tick. */
        private fun window(
            presents: Long?,
            nowMs: Long,
        ) {
            if (windowAt < 0) windowAt = nowMs
            val p = presents ?: -1
            rising = if (p >= 0 && last >= 0 && p > last) rising + 1 else 0
            last = p
        }

        private fun why(nowMs: Long): String? {
            val tap = mark?.second ?: nowMs
            return when {
                windowAt < 0 -> if (nowMs - tap > LAUNCH_S * 1000) "no window of it in $LAUNCH_S s" else null
                rising >= FRAME_TICKS -> "its first frame"
                nowMs - windowAt > FRAME_CAP_S * 1000 -> "no first frame $FRAME_CAP_S s after its window"
                else -> null
            }
        }
    }

    /**
     * The game in front: home's web window one ([web]), else the front window task's app ([task], KWin's app id) if it
     * is a game's ([WebWindows.isGame] with its desktop file's [categories]), else a game being launched ([launch],
     * [launching]: boosted from the tap, before its window exists).
     */
    fun front(
        web: String?,
        task: String?,
        launch: String? = null,
        categories: (String) -> String?,
    ): String? = web ?: task?.takeIf { it.isNotBlank() && WebWindows.isGame(it, categories(it)) } ?: launch

    /**
     * GQ1 (board broforce-fps-low-cpu-bound-under-fex, docs/research/broforce-fps.md "Non-game load"): home's page is
     * paused (WebView.onPause: the page hidden, no rAF, no compositor frames) while a game's immersive full screen
     * ([gameFull]) covers all of it - nothing of the page is on screen then, yet its window-geometry rAF loop
     * (ui/webwindows.tsx tick) woke the renderer, the browser side and RenderThread 60x a second (11-04 under Broforce:
     * 120 BeginFrames/s, 37 ms/s of script; the WebView renderer ~14-17 % and com.powos.app's main thread ~10 % of a
     * core). Running whenever any of the page can show or takes a gesture: the switcher (home's own page) up
     * ([switcher]), or a gesture from the full screen's edge strip under way ([edge]: the status bar's pull and the
     * home gesture reach the page).
     */
    fun pageQuiet(
        gameFull: Boolean,
        switcher: Boolean,
        edge: Boolean,
    ): Boolean = gameFull && !switcher && !edge

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

    /**
     * A tick's game in front: [front] with the launch [hold] ([LaunchHold]: the tap to the first frame) as the launch,
     * else the fresh mark (as before the hold).
     */
    fun tickFront(
        hold: LaunchHold,
        seen: Seen,
        categories: (String) -> String?,
    ): String? {
        val held = hold.step(seen)
        return front(seen.web, seen.task, held ?: seen.mark?.first, categories)
    }

    private val machine = Machine()
    private val launchHold = LaunchHold()
    private var handler: Handler? = null
    private lateinit var script: File
    private lateinit var lease: File
    private lateinit var marks: File
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
        marks = File(app.filesDir, "run/game-launch")
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

    /** The game in front now ([tickFront] over what the app sees). */
    private fun frontNow(): String? {
        val now = System.currentTimeMillis()
        val mark = marks.listFiles()?.let { fs -> launchingMark(fs.map { it.name to it.lastModified() }, now, categoriesOf) }
        val task = andro.marchy.PowosWindowActivity.frontAppId()
        val presents = andro.marchy.PowosWindowActivity.frontPresents()?.get(1)
        return tickFront(launchHold, Seen(mark, WebWindows.frontGame(), task, presents, now), categoriesOf)
            .also { launchHold.released?.let { Log.i(TAG, "launch hold released: $it") } }
    }

    private fun tick() {
        val h = handler ?: return
        val on = power.isInteractive
        val front = runCatching { frontNow() }.getOrNull()
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
