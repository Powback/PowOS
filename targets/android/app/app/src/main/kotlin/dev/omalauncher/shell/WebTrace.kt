package dev.omalauncher.shell

import android.os.Build
import android.webkit.TracingConfig
import android.webkit.TracingController
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * The fps meter recording's Chrome trace: every WebView of the app (home, the bar, the shade...) through Android's
 * TracingController, the same trace chrome://tracing / Perfetto / DevTools' Performance panel open - main-thread tasks
 * with JS stacks (v8 CPU profiler samples), layout/paint/raster, user timing, compositor frames. Started with the
 * recording (perf.native true), stopped with it into [dir]/perf-<ms>.trace.json; the meter's JSON names the file
 * (native.chromeTrace). Ring-buffered (RECORD_CONTINUOUSLY): a long recording keeps its newest part.
 * Off = nothing traced. Never while a check holds it (one tracing session per process: start fails, said in the trace).
 */
object WebTrace {
    /** What the trace carries (DevTools' Performance panel's own set, plus V8's sampler and user timing). */
    val CATEGORIES = listOf(
        "devtools.timeline", "disabled-by-default-devtools.timeline", "disabled-by-default-devtools.timeline.frame",
        "disabled-by-default-devtools.timeline.stack", "v8.execute", "disabled-by-default-v8.cpu_profiler",
        "blink.user_timing", "blink", "cc", "viz", "gpu", "toplevel", "latencyInfo",
    )
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "web-trace") }

    /**
     * A shell file's response headers: always the file as it is now (an edit shows on the next load, not a cached copy),
     * and a page may sample its own JS stacks (Document-Policy js-profiling: shell/ui/jsprofile.ts's Profiler, the fps
     * meter's traces) - without it the Profiler is refused.
     */
    fun shellHeaders(path: String, origin: String): Map<String, String> =
        mapOf("Cache-Control" to "no-store", "Access-Control-Allow-Origin" to origin) +
            (if (path.endsWith(".html")) mapOf("Document-Policy" to "js-profiling") else emptyMap())

    @Volatile private var on = false
    @Volatile var error: String? = null
        private set

    fun start(): Boolean {
        if (on) return true
        error = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false.also { error = "TracingController needs Android 9" }
        return runCatching {
            TracingController.getInstance().start(
                TracingConfig.Builder().addCategories(CATEGORIES).setTracingMode(TracingConfig.RECORD_CONTINUOUSLY).build(),
            )
            on = true
        }.onFailure { error = "trace start: ${it.message}" }.isSuccess
    }

    /** Stops into [dir] (the last [keep] traces kept); the file, or null (not tracing: [error] says why). */
    fun stop(dir: File, keep: Int = 6): File? {
        if (!on || Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        on = false
        dir.mkdirs()
        dir.listFiles { f -> f.name.endsWith(".trace.json") }?.sortedBy { it.lastModified() }?.dropLast(keep - 1)?.forEach { it.delete() }
        val file = File(dir, "perf-${System.currentTimeMillis()}.trace.json")
        return runCatching {
            // The stream is written on [io] and closed by the controller when the trace is complete.
            TracingController.getInstance().stop(FileOutputStream(file), io)
            file
        }.onFailure { error = "trace stop: ${it.message}" }.getOrNull()
    }
}
