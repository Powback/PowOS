package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Fix plan 1.2 (docs/WINDOWS_FIX_PLAN.md, C4): an Android window's body touches went to the helper as lines posted on
 * WebWindows' one worker thread (io), behind task polling, mirror retries, display resizes and the order check's
 * SurfaceFlinger dump - a hitch at the start of a drag. The model below is two single-thread queues writing one pipe:
 * a touch posted to the worker waits for whatever blocks it; posted to its own thread it goes out at once. The source
 * checks pin WebWindows to the second.
 */
class WebWindowsInputThreadTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n        }\n")

    /** ms until a touch line reaches the pipe while the io queue is blocked for [blockMs], posted to io or its own lane. */
    private fun touchDelay(
        ownLane: Boolean,
        blockMs: Long,
    ): Long {
        val io = Executors.newSingleThreadExecutor()
        val input = Executors.newSingleThreadExecutor()
        val pipe = Any()
        val sent = CountDownLatch(1)
        val busy = CountDownLatch(1)
        io.execute {
            busy.countDown()
            Thread.sleep(blockMs) // a dumpsys / a task poll on io
        }
        busy.await()
        val t0 = System.nanoTime()
        (if (ownLane) input else io).execute { synchronized(pipe) { sent.countDown() } }
        sent.await(5, TimeUnit.SECONDS)
        val ms = (System.nanoTime() - t0) / 1_000_000
        io.shutdownNow()
        input.shutdownNow()
        return ms
    }

    @Test
    fun aBlockedWorkerNoLongerDelaysATouch() {
        assertTrue("the old path: the touch waits out the blocked worker", touchDelay(ownLane = false, blockMs = 300) >= 250)
        assertTrue("the input lane: out at once", touchDelay(ownLane = true, blockMs = 300) < 100)
    }

    /** WebWindows does what the model needs: touches on their own thread, the pipe shared under one lock. */
    @Test
    fun touchesGoOnTheirOwnThread() {
        assertTrue("an input HandlerThread of its own", src.contains("HandlerThread(\"powos-ww-input\""))
        val touch = src.substringAfter("        fun touch(\n").substringBefore("\n        /**")
        assertTrue("Helper.touch posts to input", touch.contains("input.post {"))
        assertFalse("Helper.touch never posts to io", touch.contains("io.post"))
        val send = src.substringBefore("        private fun send(line: String): Boolean {").takeLast(40)
        assertTrue("send is under the Helper's lock (io and input both write the pipe)", send.contains("@Synchronized"))
        val stop = body("        fun stop() =")
        assertTrue("stop closes the pipe under the same lock", stop.contains("synchronized(this)"))
        assertEquals("only the body touches moved: create/resize/release stay on io", 1, Regex("input\\.post").findAll(src).count())
    }
}
