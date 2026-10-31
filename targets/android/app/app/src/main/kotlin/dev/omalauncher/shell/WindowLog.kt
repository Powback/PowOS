package dev.omalauncher.shell

import android.util.Log
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * The web windows' event log that outlives logcat: every WebWindows / WebWindowLaunch / FreeformTasks line (open, launch,
 * VD and layer binds, mirror, live, follow, root reparent, input, close, task removals) goes to logcat AND to a ring
 * file in the app's files dir: files/window-log.txt, rotated to window-log.1.txt at [CAP] bytes (2 x 512 KB, hours of
 * window events). Why (2026-10-31): web windows broke twice in a night and logcat had kept only ~30 s - the next P0 is
 * read from this file (tools/phone/verify/window-render.sh copies it into a FAIL's output), not a live repro.
 * Writes run on one background thread (never the main one); before [init] (App.onCreate) lines go to logcat only.
 * The per-frame "w.f f..." placing lines stay logcat-only: they'd fill the ring in minutes.
 */
object WindowLog {
    const val FILE = "window-log.txt"
    private const val CAP = 512 * 1024L
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "powos-windowlog").apply { isDaemon = true } }
    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    @Volatile private var dir: File? = null

    fun init(filesDir: File) {
        dir = filesDir
    }

    fun i(tag: String, msg: String): Int = Log.i(tag, msg).also { add('I', tag, msg) }

    fun w(tag: String, msg: String): Int = Log.w(tag, msg).also { add('W', tag, msg) }

    fun e(tag: String, msg: String): Int = Log.e(tag, msg).also { add('E', tag, msg) }

    fun w(tag: String, msg: String, t: Throwable?): Int = Log.w(tag, msg, t).also { add('W', tag, if (t == null) msg else "$msg: $t") }

    private fun add(level: Char, tag: String, msg: String) {
        val d = dir ?: return
        if (msg.startsWith("w.f f")) return
        val at = System.currentTimeMillis()
        io.execute {
            runCatching {
                val f = File(d, FILE)
                if (f.length() > CAP) f.renameTo(File(d, "window-log.1.txt"))
                FileWriter(f, true).use { it.write("${stamp.format(Date(at))} $level $tag: $msg\n") }
            }
        }
    }
}
