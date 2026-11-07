package andro.marchy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** perf-1793735444160: surfaceChanged -> startNative -> awaitPendingStop held the main thread 450-560 ms per swipe. */
class NativeStarterTest {
    private val mainQueue = LinkedBlockingQueue<Runnable>()
    private val stopThread = Executors.newSingleThreadExecutor()
    private val release = CountDownLatch(1)
    private var stops = 0
    private val starter = NativeStarter(stopThread, { mainQueue.put(it) }) {
        release.await(5, TimeUnit.SECONDS) // a slow teardown (joins the render and event threads)
        stops++
    }

    /** Runs the main thread's queue until [n] posts ran (or a second passed). */
    private fun drainMain(n: Int) = repeat(n) { mainQueue.poll(1, TimeUnit.SECONDS)?.run() }

    @Test
    fun startWithAPendingStopReturnsAtOnceAndStartsOnceTheStopIsDone() {
        starter.stop() // surfaceDestroyed: the teardown still running
        var started = 0
        val t0 = System.nanoTime()
        starter.start(NativeStarter.key(this, 1080, 2400, 1)) { started++ } // surfaceChanged on the main thread
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertTrue("startNative held the main thread $ms ms", ms < 50)
        assertTrue(starter.busy())
        assertEquals(0, started)
        release.countDown()
        drainMain(1)
        assertEquals(1, started)
        assertEquals(2, stops) // the queued stop, then the start's own stop - never overlapping a start
    }

    @Test
    fun aStopAfterAStartDropsTheQueuedStart() {
        var started = 0
        starter.start(null) { started++ }
        starter.stop() // surfaceDestroyed before the start ran
        release.countDown()
        stopThread.submit {}.get(5, TimeUnit.SECONDS)
        drainMain(1)
        assertEquals(0, started)
    }

    @Test
    fun theSameSurfaceAtTheSameSizeIsUnchangedUntilAStop() {
        release.countDown()
        val surface = Any()
        val key = NativeStarter.key(surface, 1080, 2400, 1)
        assertFalse(starter.unchanged(key))
        starter.start(key) {}
        assertTrue(starter.unchanged(NativeStarter.key(surface, 1080, 2400, 1)))
        assertFalse(starter.unchanged(NativeStarter.key(surface, 1080, 1500, 1))) // the IME shrank it: reconnect
        assertFalse(starter.unchanged(null))
        starter.stop()
        assertFalse(starter.unchanged(key))
    }

    /** A page swipe's surfaceChanged calls (same surface, size, format) never stop or restart the desktop. */
    @Test
    fun aPageSwipesSurfaceChangedBurstReconnectsNothing() {
        release.countDown()
        val surface = Any()
        var started = 0
        // MainActivity.surfaceChanged: start only when not unchanged.
        val changed = { w: Int, h: Int ->
            val key = NativeStarter.key(surface, w, h, 1)
            if (!starter.unchanged(key)) starter.start(key) { started++ }
        }
        changed(2268, 2440) // first connect
        stopThread.submit {}.get(5, TimeUnit.SECONDS)
        drainMain(1)
        repeat(20) { changed(2268, 2440) } // 10 swipes there and back
        stopThread.submit {}.get(5, TimeUnit.SECONDS)
        assertEquals(1, started)
        assertEquals(1, stops) // only the first connect's own stop
        assertFalse(starter.busy())
    }
}
