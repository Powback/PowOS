package dev.omalauncher.shell

import android.content.Context
import android.util.Log
import dev.omalauncher.BuildConfig
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.linux.shellQuote
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Every shell page's errors, told (2026-10-20: a hot-pushed apps/pages.ts with an import cycle left home and the lock
 * face without JS, an assist.tsx override failed on its MIME type - all of it only in logcat, nobody told).
 *
 * The page's boot guard (shell/index.html, window.__powosBoot) hands each uncaught error, unhandled rejection and
 * module-load failure to [ShellHost]'s PowosBoot interface; the host's watchdog adds "never became ready". Each one:
 * - goes into a ring buffer, files/shell-errors.log (and the run dir's copy, /run/powos-app/shell-errors.log inside
 *   PowOS: `powos shell errors`);
 * - goes to the manager agent's comms inbox (`powos comms send manager ... --from shell --priority high`), with the
 *   page, the file:line, the APK's version, the override files present and the last push - once per error signature
 *   per [RATE_MS] (the same error on every page, or on every reload, is one message).
 *
 * And a page that fails to boot within [ROLLBACK_S] of a hot push (shell/push.sh's manifest, files/shell-push.json)
 * has that push rolled back: the files it pushed restored to what they were (files/shell-prev/) or removed (the APK's
 * own shell under them, the safe fallback), the pages reloaded, and the manager told what was rolled back and why.
 */
/** Called on the main thread only (the counters and the buffer aren't locked). */
object ShellErrors {
    private const val TAG = "ShellErrors"

    /** One message per error signature this often, at most. */
    private const val RATE_MS = 10 * 60_000L

    /** A boot failure this soon after a push is that push's. */
    private const val ROLLBACK_S = 120L

    private const val LOG_LINES = 300

    /** `powos comms` runs here: through the app's one root shell, never on the main thread. */
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "shell-errors").apply { isDaemon = true } }
    private val lastSent = HashMap<String, Long>()
    private val repeats = HashMap<String, Int>()
    private var lines: ArrayDeque<String>? = null
    private val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
    private val clock = SimpleDateFormat("HH:mm:ss", Locale.US)

    /** One error of a page ([mode]), as the boot guard reported it (its JSON: kind, message, file, line, ready). */
    fun report(
        context: Context,
        mode: String,
        json: String,
    ) {
        val e = runCatching { JSONObject(json) }.getOrNull() ?: JSONObject().put("kind", "error").put("message", json.take(500))
        val kind = e.optString("kind", "error")
        val message = e.optString("message").take(1000)
        val file = e.optString("file")
        val line = e.optInt("line")
        val where = if (file.isNotEmpty()) " ($file${if (line > 0) ":$line" else ""})" else ""
        val phase = if (e.optBoolean("ready")) "" else " [before ready]"
        record(context, "$kind$where: $message", signature = "${if (mode == GateTest.MODE) "test|" else ""}$kind|${normalize(message)}|$file:$line", mode = mode, detail = phase)
    }

    /** The page never became ready (no window.__powosAlive): [why], and the errors it reported meanwhile, if any. */
    fun notReady(
        context: Context,
        mode: String,
        why: String,
    ) = record(context, "not ready: $why", signature = "notready|$mode", mode = mode, detail = "")

    /**
     * A page failed to boot: the last push rolled back, if it's recent enough and not rolled back already. Answers the
     * files rolled back (empty: nothing to roll back), after telling the manager.
     */
    fun rollback(
        context: Context,
        mode: String,
        cause: String,
    ): List<String> {
        val files = context.filesDir
        val manifestFile = File(files, "shell-push.json")
        val manifest = runCatching { JSONObject(manifestFile.readText()) }.getOrNull() ?: return emptyList()
        if (manifest.optBoolean("rolledBack")) return emptyList()
        val age = System.currentTimeMillis() / 1000 - manifest.optLong("at")
        if (age !in 0..ROLLBACK_S) return emptyList()
        val pushed = manifest.optJSONArray("files") ?: return emptyList()
        val overrides = File(files, "shell")
        val prev = File(files, "shell-prev")
        val done = mutableListOf<String>()
        for (i in 0 until pushed.length()) {
            val path = pushed.optString(i)
            if (path.isEmpty() || ".." in path.split('/')) continue
            val target = File(overrides, path)
            val before = File(prev, path)
            runCatching {
                if (before.isFile) before.copyTo(target, overwrite = true) else target.delete()
                done += path
            }.onFailure { Log.w(TAG, "can't roll back $path", it) }
        }
        manifest.put("rolledBack", true).put("rolledBackAt", System.currentTimeMillis() / 1000).put("rollbackCause", cause.take(500))
        runCatching { manifestFile.writeText(manifest.toString()) }
        val text =
            "shell $mode: rolled back ${done.joinToString(", ")} (pushed ${age}s before${manifest.optString("note").takeIf { it.isNotEmpty() }?.let { " - \"$it\"" } ?: ""}) " +
                "because the page didn't boot: $cause. The phone is on ${if (done.any { File(prev, it).isFile }) "the previous overrides" else "the APK's own files"} for them now; " +
                "fix and push again (shell/push.sh runs the gate)."
        log(context, mode, "ROLLBACK", text)
        send(context, text, test = isTest(context, mode), force = true)
        return done
    }

    private fun record(
        context: Context,
        text: String,
        signature: String,
        mode: String,
        detail: String,
    ) {
        val now = System.currentTimeMillis()
        val last = lastSent[signature]
        val due = last == null || now - last >= RATE_MS
        val status: String
        if (due) {
            val n = repeats.remove(signature) ?: 0
            lastSent[signature] = now
            status = "sent"
            send(context, "shell $mode: $text$detail${if (n > 0) " (and $n more since the last report)" else ""}. ${situation(context)}", test = isTest(context, mode))
        } else {
            repeats[signature] = (repeats[signature] ?: 0) + 1
            status = "repeat"
        }
        log(context, mode, status, text + detail)
    }

    /** What the manager needs besides the error: the APK, the overrides and the last push. */
    private fun situation(context: Context): String {
        val overrides = File(context.filesDir, "shell")
        val files =
            overrides.walkTopDown().filter { it.isFile }.sortedByDescending { it.lastModified() }.toList()
        val listed = files.take(12).joinToString(", ") { "${it.relativeTo(overrides).path} (${clock.format(Date(it.lastModified()))})" }
        val more = if (files.size > 12) " +${files.size - 12} more" else ""
        val push =
            runCatching { JSONObject(File(context.filesDir, "shell-push.json").readText()) }.getOrNull()?.let { m ->
                val names = m.optJSONArray("files")?.let { a -> (0 until a.length()).joinToString(", ") { a.optString(it) } } ?: ""
                val at = clock.format(Date(m.optLong("at") * 1000))
                "last push $at from ${m.optString("from", "?")}: $names${if (m.optBoolean("rolledBack")) " (rolled back)" else ""}"
            } ?: "no push manifest"
        return "APK ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}); overrides: ${if (files.isEmpty()) "none" else listed + more}; $push. " +
            "Log: powos shell errors."
    }

    /**
     * A test's report, not a real one: the test-only page failed (test/gate-test.tsx, ?mode=gate-test), or the last push
     * was marked a test (shell/push.sh --test) and is still the one in the manifest.
     */
    private fun isTest(
        context: Context,
        mode: String,
    ) = mode == GateTest.MODE ||
        runCatching { JSONObject(File(context.filesDir, "shell-push.json").readText()).optBoolean("test") }.getOrDefault(false)

    /**
     * One message to the manager's inbox; not on a phone without the rooted PowOS session (the log has it). A [test]'s
     * never goes to the manager (real incidents only): to the test's own role instead - the push manifest's "testTo"
     * (shell/push.sh --test=ROLE), else [TEST_ROLE], a scratch inbox - marked "[test]", at low priority, and read again
     * after [TEST_READ_MS].
     */
    private fun send(
        context: Context,
        text: String,
        test: Boolean = false,
        force: Boolean = false,
    ) {
        Log.w(TAG, if (test) "[test] $text" else text)
        if (!RootedGuest.enabled) return
        val message = (if (test) "[test] $text" else text).take(3000)
        val priority = if (test) "low" else "high"
        val to = if (test) testRole(context) else "manager"
        worker.execute {
            val out = StringBuilder()
            val code =
                runCatching {
                    RootedGuest.run("powos comms send --from shell --priority $priority ${shellQuote(to)} ${shellQuote(message)}") { out.appendLine(it) }
                }.getOrElse { -1 }
            if (code != 0) Log.w(TAG, "powos comms send failed ($code${if (force) ", a rollback report" else ""}): ${out.toString().take(300)}")
            // "Sent to 'manager' (id <id>)": read again once the test is over.
            val id = Regex("\\(id ([0-9a-f]+)\\)").find(out)?.groupValues?.get(1)
            if (test && id != null) {
                cleanup.schedule({
                    runCatching { RootedGuest.run("powos comms read --agent ${shellQuote(to)} $id") }
                        .onFailure { Log.w(TAG, "can't mark test mail $id read", it) }
                }, TEST_READ_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
            }
        }
    }

    /** Where a test's reports go when its push names no role: a scratch inbox, never the manager's or the user's. */
    private const val TEST_ROLE = "shelltest"

    private fun testRole(context: Context) =
        runCatching { JSONObject(File(context.filesDir, "shell-push.json").readText()).optString("testTo") }.getOrNull()
            ?.takeIf { Regex("[a-z0-9_-]{1,32}").matches(it) && it != "manager" && it != "user" } ?: TEST_ROLE

    /** A test's mail stays this long - long enough to check it arrived - then it's marked read. */
    private const val TEST_READ_MS = 2 * 60_000L
    private val cleanup = Executors.newSingleThreadScheduledExecutor { Thread(it, "shell-errors-cleanup").apply { isDaemon = true } }

    /** The ring buffer: files/shell-errors.log, and its copy in the run dir (/run/powos-app inside PowOS). */
    private fun log(
        context: Context,
        mode: String,
        status: String,
        text: String,
    ) {
        val buf = buffer(context)
        buf.addLast("${stamp.format(Date())}  $mode  [$status]  ${text.replace('\n', ' ').take(1500)}")
        while (buf.size > LOG_LINES) buf.removeFirst()
        val body = buf.joinToString("\n", postfix = "\n")
        runCatching { File(context.filesDir, "shell-errors.log").writeText(body) }.onFailure { Log.w(TAG, "can't write the log", it) }
        runCatching { File(context.filesDir, "run").takeIf { it.isDirectory }?.let { File(it, "shell-errors.log").writeText(body) } }
    }

    private fun buffer(context: Context): ArrayDeque<String> =
        lines ?: ArrayDeque<String>().also { b ->
            runCatching { File(context.filesDir, "shell-errors.log").readLines().takeLast(LOG_LINES).forEach(b::addLast) }
            lines = b
        }

    /** The same error told apart from another, not from itself: blob URLs, numbers and query strings vary per load. */
    private fun normalize(message: String) =
        message.replace(Regex("blob:\\S+"), "blob:").replace(Regex("\\?[^'\"\\s)]*"), "").replace(Regex("\\d+"), "#").take(300)
}
