package dev.omalauncher.shell

import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.channels.Pipe
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * A Linux web window's consumer jobs (10-31 15:57: window 4's stop never returned and window 5's start, on the same
 * thread, waited forever - Dolphin "loading forever"): a stop whose consumer is blocked in a read returns once that
 * read's fd is closed, and one window's stuck stop never delays another window's start.
 */
class ConsumerLaneTest {
    @Test
    fun aStopWhoseReadIsBlockedReturnsWithinASecond() {
        val pipe = Pipe.open() // nothing ever writes to it
        val lane = ConsumerLane("test-lane-a")
        val reading = CountDownLatch(1)
        // The consumer's reader, blocked in a read (as its render thread in a wait on the compositor).
        val reader =
            Thread {
                reading.countDown()
                runCatching { pipe.source().read(ByteBuffer.allocate(1)) }
            }
        lane.run { reader.start() }
        assertTrue(reading.await(1, TimeUnit.SECONDS))
        Thread.sleep(50) // in the read
        val t0 = System.nanoTime()
        val stopped = lane.stop(unblock = { pipe.source().close() }) { reader.join() }!!
        stopped.get(1, TimeUnit.SECONDS)
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertTrue("stop took $ms ms", ms < 1_000)
        assertTrue(!reader.isAlive)
    }

    @Test
    fun aSecondWindowsStartIsNotDelayedByTheFirstsStop() {
        val first = ConsumerLane("test-lane-1")
        val never = CountDownLatch(1)
        // Window 1's stop never returns (the 15:57 hang).
        val stuck = first.stop { never.await() }!!
        Thread.sleep(50)
        val second = ConsumerLane("test-lane-2")
        val started = CountDownLatch(1)
        val t0 = System.nanoTime()
        second.run { started.countDown() }
        assertTrue("window 2's start waited", started.await(1, TimeUnit.SECONDS))
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertTrue("window 2's start took $ms ms", ms < 200)
        assertTrue(!stuck.isDone)
        first.abandon()
        never.countDown()
    }
}
