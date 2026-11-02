package dev.omalauncher.shell

import dev.omalauncher.shell.RefreshVote.Companion.IDLE_MS
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The fast-refresh vote (10-31 trace: home paced at 60 Hz with cheap frames): HIGH from a finger down or a holder
 * (a transition, a gesture, a window drag), given back a second after the last of them - never stuck on, never
 * dropped mid-gesture.
 */
class RefreshVoteTest {
    @Test
    fun idleUntilSomethingMoves() {
        val v = RefreshVote()
        assertFalse(v.high)
        assertFalse(v.poll(10_000))
        assertEquals(0L, v.releaseAt)
    }

    @Test
    fun aTouchIsHighUntilASecondAfterItsUp() {
        val v = RefreshVote()
        assertTrue(v.touch(true, 1_000))
        assertEquals(0L, v.releaseAt)
        // A long hold: never released under the finger.
        assertTrue(v.poll(60_000))
        assertTrue(v.touch(false, 60_000))
        assertEquals(60_000 + IDLE_MS, v.releaseAt)
        assertTrue(v.poll(60_000 + IDLE_MS - 1))
        assertFalse(v.poll(60_000 + IDLE_MS))
        assertEquals(0L, v.releaseAt)
    }

    @Test
    fun aNewTouchInTheQuietSecondKeepsItHigh() {
        val v = RefreshVote()
        v.touch(true, 0)
        v.touch(false, 100)
        v.touch(true, 800)
        // The old release is void.
        assertTrue(v.poll(100 + IDLE_MS))
        v.touch(false, 900)
        assertTrue(v.poll(900 + IDLE_MS - 1))
        assertFalse(v.poll(900 + IDLE_MS))
    }

    @Test
    fun holdersKeepEachOthersVote() {
        val v = RefreshVote()
        assertTrue(v.hold("page", true, 0))
        assertTrue(v.hold("gesture", true, 10))
        v.hold("page", false, 20)
        assertEquals(0L, v.releaseAt)
        assertTrue(v.poll(5_000))
        v.hold("gesture", false, 5_000)
        assertTrue(v.poll(5_000 + IDLE_MS - 1))
        assertFalse(v.poll(5_000 + IDLE_MS))
    }

    @Test
    fun aHolderOutlivesTheFingerAndTheFingerAHolder() {
        val v = RefreshVote()
        v.hold("page", true, 0)
        v.touch(true, 10)
        v.touch(false, 20)
        // The page's transition still runs: no countdown.
        assertEquals(0L, v.releaseAt)
        assertTrue(v.poll(10_000))
        v.touch(true, 10_000)
        v.hold("page", false, 10_100)
        assertTrue(v.poll(30_000))
    }

    @Test
    fun lettingGoOfNothingStaysIdle() {
        val v = RefreshVote()
        assertFalse(v.hold("gesture", false, 0))
        assertFalse(v.touch(false, 0))
        assertEquals(0L, v.releaseAt)
    }

    /**
     * A shell gesture end to end (page swipe, launcher pull, shade pull, switcher): 120 from the finger's down, held
     * through the fling/settle the page animates after the up (refresh.ts "boost" while its transition runs), given
     * back IDLE_MS after the settle lands - not at the up, not before the settle ends.
     */
    @Test
    fun aGestureIsHighFromItsDownThroughItsSettle() {
        val v = RefreshVote()
        assertTrue(v.touch(true, 0))
        assertTrue(v.move(16))
        assertTrue(v.move(400))
        // The up starts the settle (a 600 ms transition): the page holds while it runs.
        assertTrue(v.touch(false, 450))
        assertTrue(v.hold("page", true, 452))
        assertEquals(0L, v.releaseAt)
        assertTrue(v.poll(450 + IDLE_MS))
        assertTrue(v.poll(1_050))
        // Landed: the tail, then idle.
        assertTrue(v.hold("page", false, 1_050))
        assertTrue(v.poll(1_050 + IDLE_MS - 1))
        assertFalse(v.poll(1_050 + IDLE_MS))
    }

    /** A gesture the host takes mid-way (WebWindows' window drag): its cancel isn't the finger's up - the moves keep it high. */
    @Test
    fun aTakenGestureStaysHighUnderTheFinger() {
        val v = RefreshVote()
        v.touch(true, 0)
        // The page's cancel when the host took the gesture.
        v.touch(false, 100)
        assertFalse(v.touching)
        assertTrue(v.move(116))
        assertTrue(v.touching)
        assertEquals(0L, v.releaseAt)
        // Seconds of drag: still high, nothing counting down.
        for (t in 132L..5_000L step 16) assertTrue(v.move(t))
        assertTrue(v.poll(5_000))
        v.touch(false, 5_010)
        assertTrue(v.poll(5_010 + IDLE_MS - 1))
        assertFalse(v.poll(5_010 + IDLE_MS))
    }

    /** Moves under a finger already counted change nothing (no re-arming, no release). */
    @Test
    fun movesAloneNeverReleaseOrRestartTheCount() {
        val v = RefreshVote()
        v.touch(true, 0)
        v.move(10)
        assertEquals(0L, v.releaseAt)
        v.touch(false, 20)
        assertEquals(20 + IDLE_MS, v.releaseAt)
    }
}
