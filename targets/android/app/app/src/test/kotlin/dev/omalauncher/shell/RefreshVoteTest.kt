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
}
