package dev.omalauncher.shell

import android.content.Context
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import andro.marchy.WebWindowSource
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * The ship gate's Linux window check (tools/phone/verify/window-render.sh --hidden; 10-31: Dolphin "loaded forever" and
 * no ship check covered a Linux window). [WebWindows.selftestLinux] arms it; [WebWindows.linuxOpened] hands it the next
 * KWin window of [appId] instead of offering that to the page (no "webwindows.adopt", never in WebWindows' list). The
 * window goes through the same consumer a Linux web window uses (native_consumer.c via [WebWindowSource.start], on a
 * [ConsumerLane]) - into an offscreen [ImageReader], never a layer. Its frames are measured here, it is resized once
 * (KWin's relayout draws a second frame), then the consumer is stopped (timed) and the window quit. [json] = the state.
 */
internal class LinuxSelftest(
    private val context: Context,
    private val main: Handler,
    val appId: String,
) {
    private val t0 = SystemClock.uptimeMillis()
    @Volatile var kwin = -1
    @Volatile private var kwinApp = ""
    @Volatile private var upMs = -1L
    @Volatile private var frames = 0
    @Volatile private var content = 0
    @Volatile private var best = ""
    @Volatile private var stopMs = -1L
    @Volatile var kwinClosed = false
    @Volatile var state = "armed"
    @Volatile private var error = ""
    @Volatile private var handle = 0L
    private var resized = false
    private val lane = ConsumerLane("powos-ww-selftest")
    private val thread = HandlerThread("powos-ww-selftest-frames")
    private var reader: ImageReader? = null

    fun matches(id: String) = id.equals(appId, true) || id.substringAfterLast('.').equals(appId, true)

    fun json(): String =
        JSONObject().put("state", state).put("app", appId).put("kwin", kwin).put("kwinApp", kwinApp).put("upMs", upMs)
            .put("frames", frames).put("content", content).put("best", best).put("stopMs", stopMs)
            .put("kwinClosed", kwinClosed).put("error", error).put("ageMs", SystemClock.uptimeMillis() - t0).toString()

    /** Main thread: KWin window [id] of [app] is the check's - its consumer starts into the offscreen reader. */
    fun take(
        id: Int,
        app: String,
    ) {
        kwin = id
        kwinApp = app
        state = "starting"
        WindowLog.i(TAG, "selftest: KWin window $id ($app) taken offscreen, ${W}x$H")
        thread.start()
        val usage = HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_READ_OFTEN
        val r = ImageReader.newInstance(W, H, PixelFormat.RGBA_8888, MAX_IMAGES, usage)
        reader = r
        r.setOnImageAvailableListener({ onImage(it) }, Handler(thread.looper))
        lane.run { startConsumer(r) }
        main.postDelayed({ if (state == "up" || state == "starting") end("") }, FRAMES_MS)
    }

    private fun startConsumer(r: ImageReader) {
        WebWindowSource.configure(context)
        val h = WebWindowSource.start(r.surface, kwin, W, H)
        if (h == 0L) {
            main.post { end("consumer did not start") }
            return
        }
        handle = h
        upMs = SystemClock.uptimeMillis() - t0
        WebWindowSource.crop(h, W, H)
        WebWindowSource.size(kwin, W, H)
        WindowLog.i(TAG, "selftest: KWin window $kwin consumer up")
        main.post { if (state == "starting") state = "up" }
    }

    /** Frames thread: one queued buffer - counted, measured; the first with content resizes the window once. */
    private fun onImage(ir: ImageReader) {
        val img = runCatching { ir.acquireNextImage() }.getOrNull() ?: return
        val st = runCatching { stats(img) }.getOrNull()
        img.close()
        frames++
        if (st == null || st.first >= MAX_DOMINANT || st.second < MIN_EDGES) return
        content++
        best = "dominant=%.4f edges=%.4f".format(st.first, st.second)
        if (!resized) {
            resized = true
            WebWindowSource.size(kwin, W * 3 / 4, H * 3 / 4)
            handle.takeIf { it != 0L }?.let { WebWindowSource.crop(it, W * 3 / 4, H * 3 / 4) }
        }
        if (content >= 2) main.post { if (state == "up") end("") }
    }

    /** Main thread: over ([why] = its error, "" = measured): the consumer stopped (timed), the window quit. */
    fun end(why: String) {
        if (state == "stopping" || state == "done") return
        error = why
        state = "stopping"
        WindowLog.i(TAG, "selftest: ending (${why.ifEmpty { "measured" }}): $frames frames, $content with content")
        Thread({ stopConsumer() }, "powos-ww-selftest-stop").start()
    }

    private fun stopConsumer() {
        val s0 = SystemClock.uptimeMillis()
        val f =
            lane.stop {
                val h = handle
                handle = 0
                WebWindowSource.stop(h)
            }
        val ok = runCatching { f?.get(ConsumerLane.STOP_MS * 3, TimeUnit.MILLISECONDS) }.isSuccess
        stopMs = if (ok) SystemClock.uptimeMillis() - s0 else -1L
        if (!ok) lane.abandon()
        reader?.close()
        thread.quitSafely()
        main.post {
            if (kwin >= 0 && !kwinClosed) WebWindowSource.quit(context, kwin)
            // KWin's "closed" (WebWindows.linuxClosed sets kwinClosed) within a few s; the result says either way.
            main.postDelayed({
                state = "done"
                WindowLog.i(TAG, "selftest: done ${json()}")
            }, CLOSE_WAIT_MS)
        }
    }

    companion object {
        private const val TAG = "PowosWebWindows"
        const val W = 640
        const val H = 480
        const val ARM_MS = 30_000L
        private const val FRAMES_MS = 15_000L
        private const val CLOSE_WAIT_MS = 3_000L
        private const val MAX_IMAGES = 8
        private const val MAX_DOMINANT = 0.995
        private const val MIN_EDGES = 0.001
        private const val EDGE = 48

        /** Dominant colour share (4 bits/channel) and the share of neighbouring samples that differ (window-render.py's). */
        fun stats(img: Image): Pair<Double, Double> {
            val pl = img.planes[0]
            val w = minOf(img.width, W * 3 / 4)
            val h = minOf(img.height, H * 3 / 4)
            val counts = HashMap<Int, Int>()
            var edges = 0
            var pairs = 0
            for (y in 0 until h step 4) {
                val row = IntArray((w + 1) / 2) { pl.buffer.getInt(y * pl.rowStride + it * 2 * pl.pixelStride) }
                row.forEach { px -> counts.merge((px shr 4 and 0xf) or (px shr 8 and 0xf0) or (px shr 12 and 0xf00), 1, Int::plus) }
                pairs += row.size - 1
                edges += (1 until row.size).count { diff(row[it], row[it - 1]) > EDGE }
            }
            val n = counts.values.sum()
            if (n == 0) return 1.0 to 0.0
            return (counts.values.max().toDouble() / n) to (if (pairs <= 0) 0.0 else edges.toDouble() / pairs)
        }

        private fun diff(
            a: Int,
            b: Int,
        ) = (0..2).sumOf { Math.abs((a shr (it * 8) and 0xff) - (b shr (it * 8) and 0xff)) }
    }
}
