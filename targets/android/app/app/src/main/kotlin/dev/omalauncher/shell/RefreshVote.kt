package dev.omalauncher.shell

/**
 * The fast-refresh vote's rule ([HighRefresh]), pure so the JVM tests drive it with a fake clock: HIGH while a finger
 * is down, while any holder holds (the switcher following a swipe, the page's own transition - refresh.ts "boost", an
 * overlay's gesture, a window drag), and for [IDLE_MS] after the last of them let go (a page swipe settling, a fling);
 * idle (the system's choice) otherwise - no 120 Hz while nothing moves.
 *
 * Every call answers whether the vote is HIGH now; [releaseAt] is when an idle check is due (0: none pending), which
 * the caller schedules and answers with [poll].
 */
internal class RefreshVote(
    private val idleMs: Long = IDLE_MS,
) {
    private val holders = mutableSetOf<String>()
    private var touching = false

    /** When the vote goes idle unless something new comes (uptime ms; 0: not counting down). */
    var releaseAt = 0L
        private set

    var high = false
        private set

    /** A touch event on the window: [down] true for a finger going down, false for its up/cancel; moves don't count. */
    fun touch(
        down: Boolean,
        now: Long,
    ): Boolean {
        touching = down
        return settle(now)
    }

    /** [by] holds the vote ([on]) or lets go of it; one letting go keeps the others'. */
    fun hold(
        by: String,
        on: Boolean,
        now: Long,
    ): Boolean {
        if (on) holders += by else holders -= by
        return settle(now)
    }

    /** The idle check at [now]: idle once [releaseAt] passed with nothing holding. */
    fun poll(now: Long): Boolean {
        if (high && !busy() && releaseAt != 0L && now >= releaseAt) {
            high = false
            releaseAt = 0L
        }
        return high
    }

    private fun busy() = touching || holders.isNotEmpty()

    private fun settle(now: Long): Boolean {
        if (busy()) {
            high = true
            releaseAt = 0L
        } else if (high) {
            releaseAt = now + idleMs
        }
        return high
    }

    companion object {
        /** Quiet this long after the last touch or holder: the vote is given back. */
        const val IDLE_MS = 1_000L
    }
}
