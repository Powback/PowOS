package dev.omalauncher.ui

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The app's one dictation (AO3, the user 2026-10-31: "I'm starting two microphone conversations"): every start, from
 * any window (home, the launcher overlay, the side button's panel, the pet), goes through [start], which ends the one
 * before it - [supersede] - before the new one is made. Plain JVM, so the rule has a unit test (MicOwnerTest).
 */
internal class SessionSlot<S : Any>(
    /** Ends a session a newer start replaced (cancelled: its words don't go anywhere; its owner is told). */
    private val supersede: (S) -> Unit,
) {
    var current: S? = null
        private set

    /** Ends the current session, then makes and holds the new one: never two at once, even for a moment. */
    fun start(make: () -> S): S {
        current?.let {
            current = null
            supersede(it)
        }
        return make().also { current = it }
    }

    /** [s] ended by itself: the slot is free (a later start has nothing to end). */
    fun ended(s: S) {
        if (current === s) current = null
    }
}

/**
 * The mic itself: one open recorder in the process. A new recording [enter]s only after the one before it has
 * [leave]n (its AudioRecord stopped and released) - measured 2026-10-31 00:11:12: a second start opened its AudioRecord
 * 27 ms before the first one's stop finished, two live recorders. [enter] stops the previous holder and waits for it
 * (up to [waitMs]; a stuck read must not block the mic forever). Called on the recording's own thread, never main.
 */
internal class MicGate(
    private val waitMs: Long = 1000,
) {
    class Turn {
        /** Still the mic's: the read loop goes on while true. */
        @Volatile var mine = true
        internal val left = CountDownLatch(1)
    }

    private var holder: Turn? = null

    /** Recorders open right now (0 or 1; more only if a holder outlived [waitMs]). */
    @Volatile var open = 0
        private set

    fun enter(): Turn {
        val turn = Turn()
        val before =
            synchronized(this) {
                val b = holder
                holder = turn
                b
            }
        before?.let {
            it.mine = false
            it.left.await(waitMs, TimeUnit.MILLISECONDS)
        }
        synchronized(this) { open++ }
        return turn
    }

    /** Its recorder is released: the next one may open. */
    fun leave(turn: Turn) {
        synchronized(this) {
            open--
            if (holder === turn) holder = null
        }
        turn.mine = false
        turn.left.countDown()
    }

    companion object {
        val shared = MicGate()
    }
}
