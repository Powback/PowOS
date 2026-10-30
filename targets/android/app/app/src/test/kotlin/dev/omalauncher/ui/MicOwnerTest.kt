package dev.omalauncher.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** AO3: one dictation in the app (SessionSlot), one open recorder (MicGate) - a second start ends the first first. */
class MicOwnerTest {
    private class Fake(
        val name: String,
        val log: MutableList<String>,
    ) {
        var cancelled = false

        fun cancel() {
            cancelled = true
            log += "cancel $name"
        }
    }

    @Test
    fun `a second start cancels the first before it starts`() {
        val log = mutableListOf<String>()
        val slot = SessionSlot<Fake> { it.cancel() }
        val a = slot.start { Fake("a", log).also { log += "start a" } }
        val b = slot.start { Fake("b", log).also { log += "start b" } }
        assertEquals(listOf("start a", "cancel a", "start b"), log)
        assertTrue(a.cancelled)
        assertFalse(b.cancelled)
        assertSame(b, slot.current)
    }

    @Test
    fun `an ended session is not cancelled again by the next start`() {
        val log = mutableListOf<String>()
        val slot = SessionSlot<Fake> { it.cancel() }
        val a = slot.start { Fake("a", log) }
        slot.ended(a)
        assertNull(slot.current)
        slot.start { Fake("b", log) }
        assertFalse(a.cancelled)
    }

    @Test
    fun `a stale end does not free the newer session`() {
        val log = mutableListOf<String>()
        val slot = SessionSlot<Fake> { it.cancel() }
        val a = slot.start { Fake("a", log) }
        val b = slot.start { Fake("b", log) }
        slot.ended(a)
        assertSame(b, slot.current)
    }

    /** Recorders as MicSource runs them: read while it's their turn, then released; never two open at once. */
    @Test
    fun `a second recorder opens only after the first is released`() {
        val gate = MicGate()
        val open = AtomicInteger(0)
        val maxOpen = AtomicInteger(0)
        val events = Collections.synchronizedList(mutableListOf<String>())
        val firstReading = CountDownLatch(1)

        fun recorder(name: String) =
            Thread {
                val turn = gate.enter()
                try {
                    maxOpen.accumulateAndGet(open.incrementAndGet(), ::maxOf)
                    events += "open $name"
                    firstReading.countDown()
                    // The read loop: until its turn ends (a newer start), at most 2 s.
                    val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
                    while (turn.mine && System.nanoTime() < until) Thread.sleep(5)
                    // Stopping and releasing takes a moment (measured 44 ms on the phone).
                    Thread.sleep(40)
                    events += "release $name"
                    open.decrementAndGet()
                } finally {
                    gate.leave(turn)
                }
            }.apply { start() }

        val a = recorder("a")
        assertTrue(firstReading.await(1, TimeUnit.SECONDS))
        val b = recorder("b")
        a.join(3000)
        b.join(3000)
        assertEquals(listOf("open a", "release a", "open b", "release b"), events.toList())
        assertEquals(1, maxOpen.get())
        assertEquals(0, gate.open)
    }
}
