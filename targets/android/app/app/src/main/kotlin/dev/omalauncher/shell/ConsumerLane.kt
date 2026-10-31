package dev.omalauncher.shell

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException

/**
 * One Linux web window's consumer jobs (its start, its stop), in order on a thread of its own: another window's start
 * never waits behind this one's stop. 10-31 15:57 window 4's stop never returned on the one thread all windows shared,
 * and Dolphin's window 5 (16:00:50) "loaded forever" behind it.
 *
 * The stop itself is bounded at its source (native_consumer.c: a web window's dequeue times out, so the render
 * thread it joins sees the stop); a stop still running after [STOP_MS] leaves only this window's daemon thread behind.
 */
internal class ConsumerLane(
    name: String,
) {
    private val exec: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, name).apply { isDaemon = true } }

    /** [job] after this lane's earlier ones; false once the lane is stopped or abandoned (nothing runs). */
    fun run(job: () -> Unit): Boolean =
        try {
            exec.execute(job)
            true
        } catch (_: RejectedExecutionException) {
            false
        }

    /**
     * The window going: [unblock] first, on the caller's thread (it closes what a blocked job waits on - a socket, a
     * pipe - so that job returns), then [stop] after this lane's earlier jobs, and no job after it. Never blocks: the
     * caller watches the future ([STOP_MS]). null = the lane was abandoned already.
     */
    fun stop(
        unblock: () -> Unit = {},
        stop: () -> Unit,
    ): Future<*>? {
        runCatching(unblock)
        val f =
            try {
                exec.submit(stop)
            } catch (_: RejectedExecutionException) {
                null
            }
        exec.shutdown()
        return f
    }

    /** Wedged (a job never returned): no job more on it; its thread is left, holding this window only. */
    fun abandon() {
        exec.shutdownNow()
    }

    companion object {
        /** A stop still running after this: logged as wedged, the window's thread left (other windows unaffected). */
        const val STOP_MS = 1_000L
    }
}
