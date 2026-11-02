package dev.omalauncher.shell

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.Executors

/**
 * Evidence of a blank home, kept where a reboot doesn't take it (RT1, 11-02 21:55: the phone rotated, the shell went
 * blank - only the status bar and a scrollbar - the user rebooted, and logcat went with it). When home's page reports
 * "blank" (ui/homedrawn.ts -> the boot guard -> [ShellErrors.report]), this writes, at once and off the main thread,
 * files/run/powos-ai-shared/blank-<epoch ms>.txt (PowOS: /run/powos-app/powos-ai-shared/): the page's report with its
 * state (viewport, window.screen, page, the AI page's and home's boxes), the rotation settings, the window manager's
 * rotation/focus lines, the display's state and the last [LOGCAT_LINES] lines of logcat. Nothing reloads home on a
 * blank today; should a watchdog ever do so, it must call [capture] first.
 */
object BlankCapture {
    private const val TAG = "BlankCapture"
    private const val LOGCAT_LINES = 2000

    /** One capture per this long at most (the page reports each new "why" once; a flapping one stays bounded). */
    private const val EVERY_MS = 60_000L

    /** The newest this many captures kept. */
    internal const val KEEP = 12

    private val worker = Executors.newSingleThreadExecutor { Thread(it, "blank-capture").apply { isDaemon = true } }
    private var last = 0L

    /** The page report's kind that is a blank home. */
    internal fun isBlank(kind: String) = kind == "blank"

    /** The captures to delete: every blank-*.txt past the newest [keep] (names carry their epoch ms). */
    internal fun stale(names: List<String>, keep: Int = KEEP): List<String> =
        names.filter { Regex("""blank-\d+\.txt""").matches(it) }.sortedByDescending { it.removePrefix("blank-").removeSuffix(".txt").toLong() }.drop(keep)

    /** The root commands whose output goes in, in order: (heading, command). */
    internal val commands =
        listOf(
            "rotation settings" to "echo accelerometer_rotation=\$(settings get system accelerometer_rotation) user_rotation=\$(settings get system user_rotation)",
            "device state" to "cmd device_state print-state 2>/dev/null; wm size; wm density",
            "window" to "dumpsys window | grep -E 'mCurrentRotation|mFocusedApp|mCurrentFocus|HomeShell|mDisplayRotation|mRotation='",
            "display" to "dumpsys display | grep -E 'mCurrentOrientation|DisplayDeviceInfo|mOverrideDisplayInfo' | head -20",
            "home's activity" to "dumpsys activity activities | grep -E 'topResumedActivity|HomeShell' | head -12",
            "logcat (last $LOGCAT_LINES)" to "logcat -d -v time -t $LOGCAT_LINES",
        )

    /** Every page report ([ShellErrors.report]): a real page's blank is captured; the gate's test page never. */
    fun onReport(context: Context, mode: String, kind: String, message: String) {
        if (isBlank(kind) && mode != GateTest.MODE) capture(context, mode, message)
    }

    /** Called on the main thread with the page's report ([mode], its message: why + the page's state). */
    fun capture(context: Context, mode: String, message: String) {
        val now = System.currentTimeMillis()
        if (now - last < EVERY_MS) return
        last = now
        val dir = File(context.filesDir, "run").takeIf { it.isDirectory }?.let { File(it, "powos-ai-shared") } ?: File(context.filesDir, "blank")
        worker.execute {
            runCatching {
                dir.mkdirs()
                val out = StringBuilder("PowOS blank home capture ${java.util.Date(now)} ($now)\npage: $mode\nreport: $message\n")
                for ((what, cmd) in commands) {
                    val r = andro.marchy.RootShell.run(cmd, null, 20_000)
                    out.append("\n===== $what (rc ${r.code}) =====\n").append(r.output).append('\n')
                }
                File(dir, "blank-$now.txt").apply { writeText(out.toString()); setReadable(true, false) }
                stale(dir.list()?.toList() ?: emptyList()).forEach { File(dir, it).delete() }
                Log.w(TAG, "home blank: evidence in ${File(dir, "blank-$now.txt")}")
            }.onFailure { Log.w(TAG, "can't capture the blank", it) }
        }
    }
}
