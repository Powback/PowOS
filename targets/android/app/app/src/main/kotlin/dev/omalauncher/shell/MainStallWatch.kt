package dev.omalauncher.shell

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Printer
import android.view.Choreographer
import org.json.JSONArray
import org.json.JSONObject

/**
 * The fps meter's native side (perf.native): while a recording runs, every main-thread message that holds the UI thread
 * over [BLOCK_MS], with what it was - the Looper's dispatch line (handler class, callback), the bridge call running or
 * last run, and the main thread's stack sampled [SAMPLE_MS] into it (the binder / file / su call it sat in) - plus the
 * Choreographer's frame gaps over [BLOCK_MS]. The WebView draws on this thread (synchronous compositor), so a block here
 * is a page frame and the page's input stalled with ~0 script time (perf-1793386754351: 333 + 292 ms).
 * Off between recordings: no Printer (Looper builds no dispatch strings), no sampler, no frame callback.
 */
object MainStallWatch {
    private const val BLOCK_MS = 50L
    private const val SAMPLE_MS = 40L
    private const val MAX_ENTRIES = 200
    private const val STACK_DEPTH = 24

    private val main = Looper.getMainLooper()
    private val mainThread = main.thread

    /** The bridge call on the main thread now (ShellBridge.call), and the last one with when it ended. */
    @Volatile var call: String? = null
    @Volatile var lastCall: String? = null
    @Volatile var lastCallEnd = 0L

    @Volatile private var on = false
    @Volatile private var started = 0L
    @Volatile private var line: String? = null
    @Volatile private var bridgeAtStart: String? = null
    @Volatile private var stack: String? = null
    private var sampler: HandlerThread? = null
    private var samplerHandler: Handler? = null
    private val blocks = ArrayList<JSONObject>()
    private val gaps = ArrayList<JSONObject>()
    private var lastFrame = 0L

    private val printer =
        Printer { s ->
            if (s.startsWith(">>>>> ")) begin(s) else if (s.startsWith("<<<<< ")) end()
        }

    private val sample =
        Runnable {
            if (started != 0L) stack = mainThread.stackTrace.take(STACK_DEPTH).joinToString(" < ") { "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" }
        }

    private val frames =
        object : Choreographer.FrameCallback {
            override fun doFrame(frameTimeNanos: Long) {
                if (!on) return
                val now = frameTimeNanos / 1_000_000
                if (lastFrame != 0L && now - lastFrame > BLOCK_MS) {
                    synchronized(gaps) { if (gaps.size < MAX_ENTRIES) gaps += JSONObject().put("at", epoch(lastFrame)).put("ms", now - lastFrame).put("lastCall", lastCall) }
                }
                lastFrame = now
                Choreographer.getInstance().postFrameCallback(this)
            }
        }

    private fun begin(s: String) {
        started = SystemClock.uptimeMillis()
        line = s
        bridgeAtStart = call
        stack = null
        samplerHandler?.postDelayed(sample, SAMPLE_MS)
    }

    private fun end() {
        val t0 = started
        started = 0L
        samplerHandler?.removeCallbacks(sample)
        if (t0 == 0L) return
        val ms = SystemClock.uptimeMillis() - t0
        if (ms <= BLOCK_MS) return
        val e =
            JSONObject().put("at", epoch(t0)).put("ms", ms).put("msg", line?.removePrefix(">>>>> Dispatching to ")?.take(300))
                .put("bridge", bridgeAtStart ?: call).put("lastCall", lastCall).put("lastCallAgoMs", if (lastCallEnd == 0L) JSONObject.NULL else t0 - lastCallEnd)
                .put("stack", stack ?: JSONObject.NULL)
        synchronized(blocks) { if (blocks.size < MAX_ENTRIES) blocks += e }
    }

    /** Uptime ms -> epoch ms (the page maps those onto its own clock). */
    private fun epoch(uptime: Long) = System.currentTimeMillis() - (SystemClock.uptimeMillis() - uptime)

    /** On the main thread: starts a recording (dropping the last one's entries). */
    fun start() {
        if (on) stop()
        synchronized(blocks) { blocks.clear() }
        synchronized(gaps) { gaps.clear() }
        sampler = HandlerThread("powos-stallwatch").apply { start() }.also { samplerHandler = Handler(it.looper) }
        lastFrame = 0L
        on = true
        main.setMessageLogging(printer)
        Choreographer.getInstance().postFrameCallback(frames)
    }

    /** On the main thread: stops and returns { blocks, gaps } (epoch ms; empty when nothing was recording). */
    fun stop(): JSONObject {
        if (on) {
            on = false
            main.setMessageLogging(null)
            Choreographer.getInstance().removeFrameCallback(frames)
            sampler?.quitSafely()
            sampler = null
            samplerHandler = null
            started = 0L
        }
        val b = synchronized(blocks) { JSONArray(blocks.toList()) }
        val g = synchronized(gaps) { JSONArray(gaps.toList()) }
        return JSONObject().put("thresholdMs", BLOCK_MS).put("blocks", b).put("frameGaps", g)
    }
}
