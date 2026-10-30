package dev.omalauncher.shell

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Printer
import android.view.Choreographer
import android.view.FrameMetrics
import android.view.Window
import org.json.JSONArray
import org.json.JSONObject

/**
 * The fps meter's native side (perf.native): while a recording runs, every main-thread message that holds the UI thread
 * over [BLOCK_MS], with what it was - the Looper's dispatch line (handler class, callback), the bridge call running or
 * last run, and the main thread's stack sampled [SAMPLE_MS] into it (the binder / file / su call it sat in) - plus the
 * Choreographer's frame gaps over [BLOCK_MS]. The WebView draws on this thread (synchronous compositor), so a block here
 * is a page frame and the page's input stalled with ~0 script time (perf-1793386754351: 333 + 292 ms).
 * Off between recordings: no Printer (Looper builds no dispatch strings), no sampler, no frame callback.
 *
 * A frame gap with no long message (perf-1793396392624: 375 + 333 ms gaps, the longest message 56 ms) is the UI thread
 * waiting outside any Looper message - an input event dispatched from the native poll, a binder call, a blocking
 * SurfaceControl transaction - or the RenderThread / GPU / SurfaceFlinger holding the frame. So during a gap the sampler
 * also takes the main thread's stack and the RenderThread's kernel state (/proc: R running, S sleeping + its wchan,
 * D in the kernel), and home's window reports every slow frame's phases (FrameMetrics: input, animation, layout, draw,
 * sync, command issue, swap, GPU), so the next recording names the thread and the phase.
 */
object MainStallWatch {
    private const val BLOCK_MS = 50L
    private const val SAMPLE_MS = 40L
    private const val MAX_ENTRIES = 200
    private const val STACK_DEPTH = 24
    private const val GAP_DEPTH = 10
    private const val MAX_GAP_SAMPLES = 6

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
    private val slowFrames = ArrayList<JSONObject>()
    private var lastFrame = 0L

    /** When the last frame callback ran (uptime ms), read by the sampler to spot a gap as it happens. */
    @Volatile private var lastFrameAt = 0L

    /** What the sampler saw during the gap now open (distinct lines, oldest first), attached to the gap when it closes. */
    private val gapSamples = LinkedHashSet<String>()
    private var renderTid = -1
    private var metricsWindow: Window? = null
    @Volatile private var frameCount = 0
    @Volatile private var missedCount = 0

    private val metrics =
        Window.OnFrameMetricsAvailableListener { _, m, _ ->
            frameCount++
            val total = m.getMetric(FrameMetrics.TOTAL_DURATION)
            if (android.os.Build.VERSION.SDK_INT >= 31 && total > m.getMetric(FrameMetrics.DEADLINE)) missedCount++
            if (total / 1_000_000 <= BLOCK_MS) return@OnFrameMetricsAvailableListener
            val ms = { id: Int -> Math.round(m.getMetric(id) / 100_000.0) / 10.0 }
            val e =
                JSONObject().put("at", epoch(m.getMetric(FrameMetrics.INTENDED_VSYNC_TIMESTAMP) / 1_000_000)).put("ms", ms(FrameMetrics.TOTAL_DURATION))
                    .put("delay", ms(FrameMetrics.UNKNOWN_DELAY_DURATION)).put("input", ms(FrameMetrics.INPUT_HANDLING_DURATION))
                    .put("animation", ms(FrameMetrics.ANIMATION_DURATION)).put("layout", ms(FrameMetrics.LAYOUT_MEASURE_DURATION))
                    .put("draw", ms(FrameMetrics.DRAW_DURATION)).put("sync", ms(FrameMetrics.SYNC_DURATION))
                    .put("command", ms(FrameMetrics.COMMAND_ISSUE_DURATION)).put("swap", ms(FrameMetrics.SWAP_BUFFERS_DURATION))
            if (android.os.Build.VERSION.SDK_INT >= 31) e.put("gpu", ms(FrameMetrics.GPU_DURATION)).put("deadline", ms(FrameMetrics.DEADLINE))
            synchronized(slowFrames) { if (slowFrames.size < MAX_ENTRIES) slowFrames += e }
        }

    /** The sampler's beat while recording: a gap open with no long message running = the UI thread or RenderThread elsewhere. */
    private val gapWatch =
        object : Runnable {
            override fun run() {
                if (!on) return
                val last = lastFrameAt
                if (last != 0L && started == 0L && SystemClock.uptimeMillis() - last > BLOCK_MS) {
                    val main = mainThread.stackTrace.take(GAP_DEPTH).joinToString(" < ") { "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" }
                    val line = "main=${threadState(android.os.Process.myPid())} $main | rt=${if (renderTid > 0) threadState(renderTid) else "?"}"
                    synchronized(gapSamples) { if (gapSamples.size < MAX_GAP_SAMPLES) gapSamples += line }
                }
                samplerHandler?.postDelayed(this, SAMPLE_MS)
            }
        }

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
                    val seen = synchronized(gapSamples) { JSONArray(gapSamples.toList()).also { gapSamples.clear() } }
                    synchronized(gaps) {
                        if (gaps.size < MAX_ENTRIES) gaps += JSONObject().put("at", epoch(lastFrame)).put("ms", now - lastFrame).put("lastCall", lastCall).put("seen", seen)
                    }
                } else {
                    synchronized(gapSamples) { gapSamples.clear() }
                }
                lastFrame = now
                lastFrameAt = SystemClock.uptimeMillis()
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

    /** A thread's kernel state from /proc: "R", "S:binder_wait_for_work", "D:..." (wchan when the kernel shows it). */
    private fun threadState(tid: Int): String =
        runCatching {
            val stat = java.io.File("/proc/self/task/$tid/stat").readText()
            val state = stat.substringAfterLast(") ").take(1)
            val wchan = runCatching { java.io.File("/proc/self/task/$tid/wchan").readText().trim() }.getOrDefault("")
            if (wchan.isEmpty() || wchan == "0") state else "$state:$wchan"
        }.getOrDefault("?")

    /** The app's RenderThread (HWUI: the WebView's frames are drawn and swapped there), by its /proc name. */
    private fun findRenderThread(): Int =
        java.io.File("/proc/self/task").listFiles()?.firstOrNull { f ->
            runCatching { java.io.File(f, "comm").readText().trim() == "RenderThread" }.getOrDefault(false)
        }?.name?.toIntOrNull() ?: -1

    /** Uptime ms -> epoch ms (the page maps those onto its own clock). */
    private fun epoch(uptime: Long) = System.currentTimeMillis() - (SystemClock.uptimeMillis() - uptime)

    /** On the main thread: starts a recording (dropping the last one's entries); [window] = home's, for its frame phases. */
    fun start(window: Window? = null) {
        if (on) stop()
        synchronized(blocks) { blocks.clear() }
        synchronized(gaps) { gaps.clear() }
        synchronized(slowFrames) { slowFrames.clear() }
        synchronized(gapSamples) { gapSamples.clear() }
        frameCount = 0
        missedCount = 0
        sampler = HandlerThread("powos-stallwatch").apply { start() }.also { samplerHandler = Handler(it.looper) }
        renderTid = findRenderThread()
        lastFrame = 0L
        lastFrameAt = 0L
        on = true
        samplerHandler?.postDelayed(gapWatch, SAMPLE_MS)
        metricsWindow = window?.also { w -> runCatching { w.addOnFrameMetricsAvailableListener(metrics, samplerHandler) } }
        main.setMessageLogging(printer)
        Choreographer.getInstance().postFrameCallback(frames)
    }

    /** On the main thread: stops and returns { blocks, gaps } (epoch ms; empty when nothing was recording). */
    fun stop(): JSONObject {
        if (on) {
            on = false
            main.setMessageLogging(null)
            Choreographer.getInstance().removeFrameCallback(frames)
            metricsWindow?.let { w -> runCatching { w.removeOnFrameMetricsAvailableListener(metrics) } }
            metricsWindow = null
            sampler?.quitSafely()
            sampler = null
            samplerHandler = null
            started = 0L
        }
        val b = synchronized(blocks) { JSONArray(blocks.toList()) }
        val g = synchronized(gaps) { JSONArray(gaps.toList()) }
        val f = synchronized(slowFrames) { JSONArray(slowFrames.toList()) }
        return JSONObject().put("thresholdMs", BLOCK_MS).put("blocks", b).put("frameGaps", g)
            .put("frames", JSONObject().put("count", frameCount).put("missed", missedCount).put("slow", f))
    }
}
