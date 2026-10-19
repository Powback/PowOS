package dev.omalauncher.shell

import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import androidx.compose.runtime.snapshotFlow
import dev.omalauncher.Runtime
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.linux.shellQuote
import dev.omalauncher.widgets.runtime.WidgetInstance
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * The web shell's terminals (the bridge's term.* calls): a process on a pty of the app's own ([Pty]) whose raw bytes
 * go to the page's xterm.js as "term.data" ({ id, data: base64 }), batched per frame, and whose end is "term.exit"
 * ({ id, code }). The page writes keys back and sizes the pty to its view.
 *
 * The same shell as the Compose launcher's [dev.omalauncher.ui.PtyTerminal]: in PowOS's rooted mode `su -c
 * powos-run.sh <command>` (PowOS's tmux picker unless a widget names a command), else the app's own Linux (proot).
 *
 * A terminal is the page's by its id (a widget's Terminal node and its screen naming one session share it): it keeps
 * running while no view shows it, as a Compose tile's does, and ends when the page closes it, when the widget that
 * opened it ([owner]) is removed or saved again, or with the activity. Main thread, but for the reading threads.
 */
class ShellTerminals(
    private val runtime: Runtime,
    scope: CoroutineScope,
    private val emit: (String, Any?) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val sessions = HashMap<String, Session>()

    /** Numbers each start of a terminal: the page drops events of a run it no longer shows. */
    private var runs = 0

    init {
        // A widget removed, or saved again (a new instance): its terminals end, as the Compose tile's do.
        scope.launch {
            snapshotFlow { runtime.widgets.specs.map { it.program } }.collect {
                sessions.values.filter { it.owner != null && instance(it.owner) !== it.instance }.forEach { close(it.id) }
            }
        }
    }

    private fun instance(widget: String): WidgetInstance? = runtime.widgets.let { e -> e.specs.firstOrNull { it.file.name == widget }?.let(e::instance) }

    /**
     * The terminal [id], started if it isn't running (or [restart]ed if it ended), running [command] (null: PowOS's
     * tmux picker, or a login shell). Answers { running, code, history }: what it wrote lately (base64), for a new
     * view to start from - a page reloaded, or a second view of a shared session.
     */
    fun open(
        id: String,
        owner: String?,
        command: String?,
        cols: Int,
        rows: Int,
        restart: Boolean,
    ): JSONObject {
        sessions[id]?.let { s ->
            if (s.command == command && (s.code == null || !restart)) return s.state()
            close(id)
        }
        val s = Session(id, owner, owner?.let(::instance), command)
        sessions[id] = s
        s.start(cols.coerceAtLeast(1), rows.coerceAtLeast(1))
        return s.state()
    }

    fun write(
        id: String,
        base64: String,
    ) {
        sessions[id]?.write(Base64.decode(base64, Base64.DEFAULT))
    }

    fun resize(
        id: String,
        cols: Int,
        rows: Int,
    ) {
        sessions[id]?.resize(cols.coerceAtLeast(1), rows.coerceAtLeast(1))
    }

    fun close(id: String) {
        sessions.remove(id)?.finish()
    }

    fun closeAll() {
        sessions.values.forEach { it.finish() }
        sessions.clear()
    }

    /** What runs: argv and environment of PtyTerminal's shell (rooted mode), or the app's Linux's. */
    private fun process(command: String?): Pair<List<String>, Map<String, String>> {
        if (RootedGuest.enabled) {
            val argv = listOf("/system/bin/sh", "-c", "exec su -c " + shellQuote(RootedGuest.rootCommand(command ?: RootedGuest.TERMINAL_SHELL)))
            return argv to System.getenv() + TERMINAL_ENV
        }
        val pb = runtime.proot.process(command ?: "exec bash -l")
        return pb.command() to pb.environment() + TERMINAL_ENV
    }

    private inner class Session(
        val id: String,
        val owner: String?,
        val instance: WidgetInstance?,
        val command: String?,
    ) {
        val run = ++runs
        private var pid = -1
        private var fd: ParcelFileDescriptor? = null
        private var out: FileOutputStream? = null

        /** Writes to the pty in order, off the main thread: a shell that doesn't read would block it. */
        private val writer = Executors.newSingleThreadExecutor()

        /** The exit status once it ended. */
        var code: Int? = null
            private set
        @Volatile private var finished = false

        /** Output not yet sent, under [lock]; the reader waits ([drained]) while the page is far behind. */
        private val pending = ByteArrayOutputStream()
        private val lock = ReentrantLock()
        private val drained = lock.newCondition()
        private var flushQueued = false

        /** Bytes sent to the page so far: the offset after the last "term.data". */
        private var sent = 0L

        /** The last [HISTORY] bytes written, a ring (the [pending] ones included). */
        private val history = ByteArray(HISTORY)
        private var historyEnd = 0
        private var historyFull = false

        fun start(
            cols: Int,
            rows: Int,
        ) {
            val (argv, env) = process(command)
            val pids = IntArray(1)
            val master = Pty.spawn("/", argv.toTypedArray(), env.map { (k, v) -> "$k=$v" }.toTypedArray(), rows, cols, pids)
            if (master < 0) {
                Log.w(TAG, "$id: can't open a pty (${-master})")
                code = -1
                return
            }
            pid = pids[0]
            val pfd = ParcelFileDescriptor.adoptFd(master)
            fd = pfd
            out = FileOutputStream(pfd.fileDescriptor)
            val input = FileInputStream(pfd.fileDescriptor)
            val reader =
                Thread({
                    val buf = ByteArray(READ_BYTES)
                    try {
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            received(buf, n)
                        }
                    } catch (_: IOException) {
                        // EIO: the shell and everything holding its terminal ended (or the pty closed).
                    }
                }, "term-read[$pid]").apply { start() }
            Thread({
                val status = Pty.waitFor(pid)
                // What it wrote last arrives before its end.
                reader.join(EXIT_DRAIN_MS)
                main.post { exited(status) }
            }, "term-wait[$pid]").start()
        }

        private fun received(
            buf: ByteArray,
            n: Int,
        ) {
            lock.withLock {
                // The page is far behind (a flood of output): the shell waits, as on a slow terminal.
                while (pending.size() > MAX_PENDING && !finished) drained.await(100, TimeUnit.MILLISECONDS)
                pending.write(buf, 0, n)
                for (i in 0 until n) {
                    history[historyEnd] = buf[i]
                    historyEnd = (historyEnd + 1) % HISTORY
                    if (historyEnd == 0) historyFull = true
                }
                if (!flushQueued) {
                    flushQueued = true
                    main.postDelayed(::flush, FLUSH_MS)
                }
            }
        }

        /** One frame's output to the page, at most [BATCH] bytes of it; the rest next frame. */
        private fun flush() {
            val chunk: ByteArray
            val end: Long
            lock.withLock {
                val all = pending.toByteArray()
                chunk = if (all.size > BATCH) all.copyOf(BATCH) else all
                pending.reset()
                if (all.size > BATCH) pending.write(all, BATCH, all.size - BATCH)
                flushQueued = pending.size() > 0
                if (flushQueued) main.postDelayed(::flush, FLUSH_MS)
                drained.signalAll()
                sent += chunk.size
                end = sent
            }
            if (chunk.isNotEmpty() && sessions[id] === this) {
                emit("term.data", JSONObject().put("id", id).put("run", run).put("data", chunk.base64()).put("end", end))
            }
        }

        private fun exited(status: Int) {
            if (finished) return
            flush()
            code = status
            closeFd()
            Log.i(TAG, "$id exited $status")
            if (sessions[id] === this) emit("term.exit", JSONObject().put("id", id).put("run", run).put("code", status))
        }

        fun write(bytes: ByteArray) {
            val o = out ?: return
            writer.execute { runCatching { o.write(bytes) } }
        }

        fun resize(
            cols: Int,
            rows: Int,
        ) {
            fd?.let { Pty.resize(it.fd, rows, cols) }
        }

        /**
         * What a view starts from: the output up to [sent] - what's pending still comes as "term.data", and an event
         * already on its way is dropped by the page, which has it (its end isn't past this one's).
         */
        fun state(): JSONObject {
            lock.withLock {
                val all = if (historyFull) history.copyOfRange(historyEnd, HISTORY) + history.copyOfRange(0, historyEnd) else history.copyOf(historyEnd)
                val bytes = all.copyOf((all.size - pending.size()).coerceAtLeast(0))
                return JSONObject()
                    .put("running", code == null)
                    .put("code", code ?: JSONObject.NULL)
                    .put("run", run)
                    .put("history", bytes.base64())
                    .put("end", sent)
            }
        }

        /** Ends the shell (SIGKILL, as Termux's finishIfRunning) and hangs up its terminal. */
        fun finish() {
            if (finished) return
            finished = true
            if (code == null && pid > 0) runCatching { Os.kill(pid, OsConstants.SIGKILL) }
            closeFd()
            lock.withLock { drained.signalAll() }
        }

        private fun closeFd() {
            writer.shutdown()
            out = null
            runCatching { fd?.close() }
            fd = null
        }
    }

    private fun ByteArray.base64() = Base64.encodeToString(this, Base64.NO_WRAP)

    private companion object {
        const val TAG = "ShellTerminals"

        /** xterm.js speaks xterm, with 24-bit color. */
        val TERMINAL_ENV = mapOf("TERM" to "xterm-256color", "COLORTERM" to "truecolor")

        const val READ_BYTES = 16 * 1024

        /** A frame: output is sent at most this often, coalesced. */
        const val FLUSH_MS = 16L

        /** The most one frame sends; a flood is spread over frames. */
        const val BATCH = 64 * 1024

        /** How far the page may fall behind before the shell's writes wait. */
        const val MAX_PENDING = 1024 * 1024

        /** What a view opening a running terminal starts from. */
        const val HISTORY = 256 * 1024

        const val EXIT_DRAIN_MS = 500L
    }
}
