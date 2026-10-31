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
 */
internal class RenderWatch {
    enum class Act { NONE, PROBE, STALL, RELOAD }

    /** When the probe / the stall's resend went (uptime ms; 0: none pending), and the back-off's end after a reload. */
    var probedAt = 0L
        private set
    var stalledAt = 0L
        private set
    private var backoffUntil = 0L

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
        // Nothing to watch, or the page answered what was asked: a new watch from here.
        if (resting(now, live, homeShown) || answered(lastFrame)) clear()
        if (resting(now, live, homeShown) || now - lastFrame < PROBE_MS) return Act.NONE
        return when {
            stalledAt != 0L -> due(now, stalledAt, RELOAD_MS) { reload(now) }
            probedAt != 0L -> due(now, probedAt, REBIND_MS) { Act.STALL.also { stalledAt = now } }
            else -> Act.PROBE.also { probedAt = now }
        }
    }

    private fun resting(
        now: Long,
        live: Int,
        homeShown: Boolean,
    ) = live == 0 || !homeShown || now < backoffUntil

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
        /** No geometry for this long: probed (a working page answers at once). */
        const val PROBE_MS = 1_000L

        /** A probe unanswered this long: a stall - re-bound (root re-attached, visibility poked, resent): 1.5 s in. */
        const val REBIND_MS = 500L

        /** The rebind unanswered this long: home's page reloaded - never before 4 s without geometry. */
        const val RELOAD_MS = 2_500L

        /** How often [WebWindows] looks while there are windows (the steps above land within this of their time). */
        const val WATCH_MS = 250L

        /** After a reload, no look for this long: the page boots and its sender starts. */
        const val BACKOFF_MS = 30_000L
    }
}
