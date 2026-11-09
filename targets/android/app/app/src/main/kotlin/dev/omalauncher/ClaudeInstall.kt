package dev.omalauncher

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.omalauncher.linux.Guest
import org.json.JSONObject

/**
 * The AI page's Install Claude (`powos manager --auth` said "install": the manager's claude isn't in the image - the
 * user, 11-10 on the razr: "it shouldnt say sign in to claude if claude is not installed, it should show install
 * claude"). [start] runs `powos manager --install` (Claude Code's native installer, ~20 s), its output line by line
 * into [line] so the page always shows what it's doing, then asks the sign-in state again: the page moves on to Sign
 * in to Claude, or the chat. [running] stays true until that answer, so the button never flashes back in between.
 */
object ClaudeInstall {
    private const val TAG = "ClaudeInstall"

    var running by mutableStateOf(false)
        private set

    /** The installer's latest line ("" when idle). */
    var line by mutableStateOf("")
        private set

    /** Why the last install failed ("" when it didn't). */
    var error by mutableStateOf("")
        private set

    /** Installed: the next auth answer ends [running]. */
    private var awaitingAuth = false

    fun start() {
        if (running || !Guest.enabled) return
        running = true
        error = ""
        line = "Starting the installer…"
        Thread({
            val (code, last) = install()
            post { finished(code, last) }
        }, "powos-ai-install").start()
    }

    /** `powos manager --install`: its status and its last line; each line shown as it comes. Blocks. */
    private fun install(): Pair<Int, String> =
        runCatching {
            val p = Guest.process("exec powos manager --install", mergeErrors = true).start()
            p.outputStream.close()
            var last = ""
            p.inputStream.bufferedReader().forEachLine { raw ->
                progressLine(raw)?.let {
                    last = it
                    post { line = it }
                }
            }
            p.waitFor() to last
        }.getOrElse {
            Log.w(TAG, "install failed to start", it)
            -1 to (it.message ?: "")
        }

    private fun finished(
        code: Int,
        last: String,
    ) {
        if (code != 0) {
            running = false
            line = ""
            error = last.ifEmpty { "the installer stopped (exit $code)" }
            return
        }
        line = "Claude installed · checking sign-in…"
        awaitingAuth = true
        PowosAiChat.checkAuth()
    }

    /** PowosAiChat.checkAuth answered [word] ("" when the ask failed): an install waiting on it is done. */
    fun authAnswered(word: String) {
        if (!awaitingAuth) return
        awaitingAuth = false
        running = false
        line = ""
        if (word == "install") error = "Claude Code was installed but isn't found - try again"
    }

    fun json(): JSONObject = JSONObject().put("running", running).put("line", line).put("error", error)

    /**
     * An installer output line as the page shows it: colour codes and a carriage-return-redrawn bar's earlier frames
     * dropped; null for a blank one.
     */
    fun progressLine(raw: String): String? =
        raw.trimEnd('\r').substringAfterLast('\r').replace(ANSI, "").trim().takeIf { it.isNotEmpty() }

    private val ANSI = Regex("\u001B\\[[0-9;?]*[A-Za-z]")

    private val main by lazy { android.os.Handler(android.os.Looper.getMainLooper()) }

    private fun post(block: () -> Unit) {
        main.post(block)
    }
}
