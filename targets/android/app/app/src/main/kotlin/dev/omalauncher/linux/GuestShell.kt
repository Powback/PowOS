package dev.omalauncher.linux

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.Writer

/** What a guest command printed, kept apart, and how it exited (124: timed out). */
data class ShellResult(
    val out: String,
    val err: String,
    val code: Int,
) {
    val timedOut get() = code == 124
}

/**
 * One long-lived bash inside the guest for running many short commands
 * (widget data). Starting proot per command costs far more than the command.
 * Commands run one at a time, each under `timeout`.
 */
class GuestShell(
    private val proot: Proot,
) {
    private val mutex = Mutex()
    private var process: Process? = null
    private var stdin: Writer? = null
    private var stdout: BufferedReader? = null
    private var counter = 0

    /**
     * Runs [command]. If the shell died, it restarts; with [retry] the command
     * then runs again, which is only safe for commands without side effects.
     */
    suspend fun run(
        command: String,
        timeoutSeconds: Int = 10,
        retry: Boolean = true,
    ): ShellResult =
        mutex.withLock {
            withContext(Dispatchers.IO) {
                runCatching { exec(command, timeoutSeconds) }.getOrElse {
                    stop()
                    if (!retry) throw it
                    exec(command, timeoutSeconds)
                }
            }
        }

    private fun exec(
        command: String,
        timeoutSeconds: Int,
    ): ShellResult {
        ensureStarted()
        val marker = "__omarchy_done_${counter++}__"
        val quoted = shellQuote(command)
        // stdin is this shell's command pipe, so commands get /dev/null instead of eating the next command.
        // stderr goes to a file and follows the exit code, so it never mixes into the output.
        stdin!!.apply {
            write(
                "timeout $timeoutSeconds bash -c $quoted </dev/null 2>\"\$__err\"; printf '\\n%s %d\\n' $marker \$?; " +
                    "head -c 8192 \"\$__err\"; printf '\\n%s\\n' $marker\n",
            )
            flush()
        }
        val out = StringBuilder()
        var code: Int
        while (true) {
            val line = readLine()
            if (line.startsWith("$marker ")) {
                code = line.substringAfter(' ').toIntOrNull() ?: -1
                break
            }
            out.appendLine(line)
        }
        val err = StringBuilder()
        while (true) {
            val line = readLine()
            if (line == marker) break
            err.appendLine(line)
        }
        return ShellResult(out.toString().trimEnd(), err.toString().trim(), code)
    }

    private fun readLine() = stdout!!.readLine() ?: error("guest shell exited")

    /** The PowOS session this shell runs in (rooted mode, RootedGuest.session). */
    private var session = 0L

    private fun ensureStarted() {
        // The PowOS session restarted (an app update restarts it): this shell is still in the old one.
        if (RootedGuest.enabled && process != null && session != RootedGuest.session()) stop()
        if (process?.isAlive == true) return
        if (RootedGuest.enabled) session = RootedGuest.session()
        // PowOS rooted mode: the shell runs in the PowOS session (as its terminals do), there is no proot system.
        val shell = "exec bash --noprofile --norc"
        val p = (if (RootedGuest.enabled) RootedGuest.process(shell, mergeErrors = false) else proot.process(shell)).start()
        process = p
        stdin = p.outputStream.bufferedWriter()
        stdout = p.inputStream.bufferedReader()
        // Whatever the way in printed (a login profile under su) ends before the marker, not in the first output.
        stdin!!.apply {
            write("__err=/tmp/.guest-shell-err-\$\$; printf '\\n%s\\n' __omarchy_ready__\n")
            flush()
        }
        while (readLine() != "__omarchy_ready__") Unit
    }

    private fun stop() {
        process?.destroy()
        process = null
    }
}

/**
 * A few [GuestShell]s, so one slow command (a curl timing out) doesn't hold
 * up every other widget. Shells start on first use.
 */
class ShellPool(
    proot: Proot,
    size: Int,
) {
    private val idle = Channel<GuestShell>(size).apply { repeat(size) { trySend(GuestShell(proot)) } }

    suspend fun run(
        command: String,
        timeoutSeconds: Int = 10,
        retry: Boolean = true,
    ): ShellResult {
        val shell = idle.receive()
        try {
            return shell.run(command, timeoutSeconds, retry)
        } finally {
            idle.trySend(shell)
        }
    }
}
