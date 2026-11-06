package dev.omalauncher.shell

/**
 * The web windows' render watchdog's rule ([WebWindows.watch]), pure so the JVM tests drive it with a fake clock.
 *
 * Three "windows render empty" P0s on 2026-10-31 (00:50, 01:46, 14:20) had one signature: the host's windows were live
 * and mirrored, but no page geometry ("w.f") was applied any more - 01:46 a hex fill dropped by ShellNative's GEOMETRY
 * regex, 14:20 home's page reloaded and sent nothing. The device check (window-render.sh) never ran: it waits for an
 * idle phone. This one is passive and always on: no touch, only the page's own geometry channel.
 *
 * The page sends "w.f" only when the geometry changed, so a quiet second is normal. A window with no frame for
 * [PROBE_MS] gets a quiet probe first ([Act.PROBE]: "webwindows.resend", which a working page answers at once with
 * every window's geometry, changed or not). Unanswered [REBIND_MS] later it is a stall ([Act.STALL]: logged, the
 * windows' root re-attached to home's surface, the WebView's visibility poked, asked again); still unanswered
 * [RELOAD_MS] after that, the page is reloaded ([Act.RELOAD]: reported, the sender starts again) and the watch backs
 * off [BACKOFF_MS] - once per stall, never a reload loop. 10-31 15:37 (the old 2 s steps on a 2 s heartbeat): ~9 s
 * from the stall to windows back; now a rebind at 1.5 s, a reload no sooner than 4 s.
 *
 * Under memory pressure ([trimmed]: the system's onTrimMemory, 11-02 05:07-05:23 the idle phone at ~49 MB free, the
 * low-memory killer firing) a slow page is not a broken one: Chromium is trimming and swapping, and a reload throws the
 * page away and allocates a new one - more pressure, the next stall, another reload. Within [PRESSURE_MS] of a trim a
 * stall that is due a reload is rebound again instead ([Act.STALL] every [RELOAD_MS]): the windows keep their last
 * geometry and come back with the page's next "w.f"; a page still silent once the pressure passed is reloaded as before.
 */
internal class RenderWatch {
    enum class Act { NONE, PROBE, STALL, RELOAD }

    /** When the probe / the stall's resend went (uptime ms; 0: none pending), and the back-off's end after a reload. */
    var probedAt = 0L
        private set
    var stalledAt = 0L
        private set
    private var backoffUntil = 0L

    /** The last memory trim (uptime ms; 0: none). */
    private var trimmedAt = 0L

    /** Home's page (re)loaded at this uptime ms and hasn't sent a "w.f" since (0: none pending). */
    private var bootAt = 0L

    /**
     * Home's page (re)loaded at [now] (a shell update, a reload): it boots, asks the host for its windows and sends
     * their geometry once rebuilt - no probe, stall or reload for [BOOT_MS] or until its first "w.f". 11-06 23:46 (ship
     * bbe9e53c): a shell push reloaded home with a live window, the new page was still booting 4 s later and the watch
     * reloaded it again ("a resend unanswered: home reloaded"). A page silent past [BOOT_MS] is watched as before.
     */
    fun pageStarted(now: Long) {
        bootAt = now
        clear()
    }

    /** The system asked the app to trim memory at [now] (uptime ms): no reload for [PRESSURE_MS] from here. */
    fun trimmed(now: Long) {
        trimmedAt = now
    }

    /** Whether [now] is within [PRESSURE_MS] of the last trim. */
    fun underPressure(now: Long) = trimmedAt != 0L && now - trimmedAt < PRESSURE_MS

    /**
     * One look at [now] (uptime ms): [live] windows showing their app (not full screen), [homeShown] (home's page on a
     * lit screen: its frames run), [lastFrame] the last applied "w.f" (uptime ms, 0: none yet).
     */
    fun step(
        now: Long,
        live: Int,
        homeShown: Boolean,
        lastFrame: Long,
    ): Act {
        if (bootAt != 0L && lastFrame >= bootAt) bootAt = 0L
        // Nothing to watch, or the page answered what was asked: a new watch from here.
        if (resting(now, live, homeShown) || answered(lastFrame)) clear()
        if (resting(now, live, homeShown) || now - lastFrame < PROBE_MS) return Act.NONE
        return when {
            stalledAt != 0L -> due(now, stalledAt, RELOAD_MS) { afterStall(now) }
            probedAt != 0L -> due(now, probedAt, REBIND_MS) { Act.STALL.also { stalledAt = now } }
            else -> Act.PROBE.also { probedAt = now }
        }
    }

    private fun resting(
        now: Long,
        live: Int,
        homeShown: Boolean,
    ) = live == 0 || !homeShown || now < backoffUntil || (bootAt != 0L && now - bootAt < BOOT_MS)

    private fun answered(lastFrame: Long): Boolean {
        val pending = maxOf(probedAt, stalledAt)
        return pending != 0L && lastFrame >= pending
    }

    /** [act] once [after] ms passed since [since]. */
    private inline fun due(
        now: Long,
        since: Long,
        after: Long,
        act: () -> Act,
    ): Act = if (now - since >= after) act() else Act.NONE

    /** A stall's rebind unanswered: rebound again under memory pressure, else the page reloaded. */
    private fun afterStall(now: Long): Act = if (underPressure(now)) Act.STALL.also { stalledAt = now } else reload(now)

    private fun reload(now: Long): Act {
        clear()
        backoffUntil = now + BACKOFF_MS
        return Act.RELOAD
    }

    private fun clear() {
        probedAt = 0L
        stalledAt = 0L
    }

    companion object {
        /**
         * Whether a window owes the page's geometry - counted in [step]'s live: its content shows ([live]), not [closed],
         * and not [offHome] (full screen, in PiP, or minimised to the dock / left by the home gesture: on display 0,
         * never in a "w.f"). 11-03 22:50 (ship 9b16c2ce7) a minimised Linux window (Broforce) kept the watch probing
         * every second for ever, and the one probe a page busy coming back to front answered late was a "RENDER STALL"
         * + rebind (its consumer and root re-bound) for a window nobody could see.
         */
        fun owesGeometry(
            live: Boolean,
            closed: Boolean,
            offHome: Boolean,
        ) = live && !closed && !offHome

        /** No geometry for this long: probed (a working page answers at once). */
        const val PROBE_MS = 1_000L

        /** A probe unanswered this long: a stall - re-bound (root re-attached, visibility poked, resent): 1.5 s in. */
        const val REBIND_MS = 500L

        /** The rebind unanswered this long: home's page reloaded - never before 4 s without geometry. */
        const val RELOAD_MS = 2_500L

        /** How often [WebWindows] looks while there are windows (the steps above land within this of their time). */
        const val WATCH_MS = 250L

        /** After home's page (re)loads ([pageStarted]), this long to send its first "w.f" before it is watched. */
        const val BOOT_MS = 10_000L

        /** After a reload, no look for this long: the page boots and its sender starts. */
        const val BACKOFF_MS = 30_000L

        /** After a memory trim, this long with no reload: a stall is rebound (geometry kept), never the page dropped. */
        const val PRESSURE_MS = 60_000L

        /**
         * Whether onTrimMemory's [level] means memory is short: RUNNING_LOW / RUNNING_CRITICAL (the app in front, the
         * system killing others) or BACKGROUND and up; not RUNNING_MODERATE or UI_HIDDEN (only "your UI went away").
         */
        fun isPressure(level: Int) = level == TRIM_RUNNING_LOW || level == TRIM_RUNNING_CRITICAL || level >= TRIM_BACKGROUND

        // android.content.ComponentCallbacks2's levels (constants, so the JVM test needs no Android).
        const val TRIM_RUNNING_LOW = 10
        const val TRIM_RUNNING_CRITICAL = 15
        const val TRIM_UI_HIDDEN = 20
        const val TRIM_BACKGROUND = 40
    }
}

/**
 * A Linux web window's content check ([WebWindows.consumerCheck]), [CONSUMER_UP_MS] after its open, a reclaim by a
 * reloaded page, or a render stall's rebind: its consumer up ([UP]: nothing to do), its start running ([STARTING]:
 * logged), or never taken / failed ([REBIND]: started again on a new consumer thread). 10-31 16:00 Dolphin.
 */
internal object ConsumerCheck {
    enum class Act { UP, STARTING, REBIND }

    /** How long after an open or a reclaim the consumer must be up. */
    const val CONSUMER_UP_MS = 1_000L

    fun step(
        closed: Boolean,
        handle: Long,
        starting: Boolean,
    ): Act =
        when {
            closed || handle != 0L -> Act.UP
            starting -> Act.STARTING
            else -> Act.REBIND
        }
}
