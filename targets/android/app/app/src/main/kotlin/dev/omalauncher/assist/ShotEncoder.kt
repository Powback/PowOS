package dev.omalauncher.assist

import android.os.Handler
import android.os.Looper
import java.io.File
import java.io.OutputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Writes the assist screenshot off the main thread (PowosAssistSession.onHandleScreenshot): [encode] runs the
 * compress into a temp file on [worker], renames it over the target, and calls back on [main] - only for the newest
 * request still wanted ([cancel] drops the ones before it: a new summoning, the session gone). A failed write calls
 * nothing back and leaves the target as it was. [encode] and [cancel] are called from the main thread.
 */
class ShotEncoder(
    private val worker: Executor = WORKER,
    private val main: Executor = Executor { Handler(Looper.getMainLooper()).post(it) },
) {
    @Volatile private var generation = 0

    fun encode(
        file: File,
        write: (OutputStream) -> Unit,
        done: (File) -> Unit,
    ) {
        val wanted = ++generation
        worker.execute {
            if (wanted != generation) return@execute
            val tmp = File(file.parentFile, "${file.name}.tmp")
            val ok =
                runCatching {
                    tmp.outputStream().use(write)
                    tmp.renameTo(file)
                }.getOrElse {
                    android.util.Log.w("speech", "assist: screenshot not written: $it")
                    false
                }
            if (!ok) tmp.delete()
            main.execute { if (ok && wanted == generation) done(file) }
        }
    }

    fun cancel() {
        generation++
    }

    private companion object {
        val WORKER: Executor = Executors.newSingleThreadExecutor { r -> Thread(r, "assist-shot").apply { isDaemon = true } }
    }
}
