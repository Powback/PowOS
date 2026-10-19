package dev.omalauncher

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.omalauncher.linux.RootedGuest
import org.json.JSONObject
import java.io.File

/**
 * The phone's conversation with PowOS AI: PowOS's persistent manager (`powos manager`, lib/ai/manager), one turn at a
 * time over its normalized event stream (`--once-stdin --json-events`: assistant / tool_use / tool_result / turn_done),
 * the same stream the KDE desktop's manager widget draws. The manager keeps the conversation (it resumes its session
 * for the home directory, the one `powos manager` in a terminal there continues); this keeps what the phone showed,
 * so the chat reopens where it was.
 */
object PowosAiChat {
    private const val TAG = "PowosAiChat"
    private const val KEEP = 300

    sealed class Item {
        abstract fun json(): JSONObject

        data class User(val text: String) : Item() {
            override fun json() = JSONObject().put("kind", "user").put("text", text)
        }

        data class Assistant(val text: String) : Item() {
            override fun json() = JSONObject().put("kind", "assistant").put("text", text)
        }

        /** A tool the agent used; [ok] null while it runs. */
        data class Tool(val name: String, val hint: String, val ok: Boolean? = null) : Item() {
            override fun json() = JSONObject().put("kind", "tool").put("name", name).put("hint", hint).put("ok", ok ?: JSONObject.NULL)
        }

        data class Note(val text: String, val error: Boolean = false) : Item() {
            override fun json() = JSONObject().put("kind", "note").put("text", text).put("error", error)
        }

        companion object {
            fun from(o: JSONObject): Item? =
                when (o.optString("kind")) {
                    "user" -> User(o.optString("text"))
                    "assistant" -> Assistant(o.optString("text"))
                    "tool" -> Tool(o.optString("name"), o.optString("hint"), if (o.isNull("ok")) null else o.optBoolean("ok"))
                    "note" -> Note(o.optString("text"), o.optBoolean("error"))
                    else -> null
                }
        }
    }

    val items = mutableStateListOf<Item>()
    var busy by mutableStateOf(false)
        private set
    private var file: File? = null
    private var appContext: Context? = null

    /** Mail came for the manager while a turn was under way: its turn follows that one. */
    private var inboxWaiting = false

    fun load(context: Context) {
        if (appContext == null) appContext = context.applicationContext
        if (file != null) return
        val f = File(context.filesDir, "powos-ai/chat.jsonl")
        file = f
        runCatching {
            f.readLines().mapNotNull { runCatching { Item.from(JSONObject(it)) }.getOrNull() }
        }.getOrNull()?.let { items.addAll(it) }
    }

    /** Sends [text] to the manager: one turn, its events into [items] as they come. */
    fun send(
        context: Context,
        text: String,
    ) {
        load(context)
        val prompt = text.trim()
        if (prompt.isEmpty() || busy) return
        add(Item.User(prompt))
        if (!RootedGuest.enabled) {
            add(Item.Note("PowOS AI runs in the PowOS session (rooted mode), which isn't set up on this phone.", error = true))
            return
        }
        busy = true
        Thread({ turn(prompt) }, "powos-ai").start()
    }

    /**
     * Mail arrived in the manager's comms inbox (comms' agent-wake/manager-* marker, [Wake]): one turn made of it
     * (`--once-inbox`), now or once the one under way ends - this chat runs the manager a turn at a time, so between
     * turns nothing else would read the inbox and an agent's message waited for the user's next one.
     */
    fun inboxArrived(context: Context) {
        load(context)
        if (!RootedGuest.enabled) return
        if (busy) {
            inboxWaiting = true
            return
        }
        busy = true
        Thread({ turn(null) }, "powos-ai-inbox").start()
    }

    /** One turn: [prompt] the user's, or null for the inbox's (nothing waiting there: no turn, nothing said). */
    private fun turn(prompt: String?) {
        val errors = ArrayDeque<String>()
        var answered = false
        val exit =
            runCatching {
                val mode = if (prompt == null) "--once-inbox" else "--once-stdin"
                val process = RootedGuest.process("cd ~ && exec powos manager $mode --json-events", mergeErrors = false).start()
                Thread({
                    process.errorStream.bufferedReader().forEachLine {
                        synchronized(errors) {
                            errors.addLast(it)
                            if (errors.size > 20) errors.removeFirst()
                        }
                    }
                }, "powos-ai-stderr").start()
                process.outputStream.use { out -> prompt?.let { out.write(it.toByteArray()) } }
                process.inputStream.bufferedReader().forEachLine { line ->
                    val ev = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
                    when (ev.optString("kind")) {
                        "assistant" -> {
                            answered = true
                            post { add(Item.Assistant(ev.optString("text"))) }
                        }
                        "tool_use" -> post { add(Item.Tool(ev.optString("name"), ev.optString("hint"))) }
                        "tool_result" -> post { finishTool(ev.optBoolean("ok", true)) }
                        // The mail the turn answers: who it's from, as a line in the chat.
                        "inbox" -> post { add(Item.Note(inboxLine(ev.optString("text")))) }
                    }
                }
                process.waitFor()
            }.getOrElse {
                Log.w(TAG, "manager turn failed", it)
                -1
            }
        post {
            // The inbox's turn with nothing waiting (already read): nothing to say.
            val quiet = prompt == null && exit == 0 && !answered
            if (!quiet && (exit != 0 || !answered)) {
                val why = synchronized(errors) { errors.lastOrNull { it.isNotBlank() } }
                add(Item.Note("PowOS AI didn't answer" + (why?.let { ": $it" } ?: " (exit $exit)"), error = true))
            }
            busy = false
            if (inboxWaiting) {
                inboxWaiting = false
                appContext?.let(::inboxArrived)
            }
        }
    }

    /** "[inbox message from agent 'coder' (normal)]: …" as "mail from coder: …" (its first line, shortened). */
    private fun inboxLine(text: String): String {
        val m = Regex("""\[inbox message from agent '([^']+)'[^\]]*\]:\s*(.*)""", RegexOption.DOT_MATCHES_ALL).find(text)
        val from = m?.groupValues?.get(1) ?: "an agent"
        val body = (m?.groupValues?.get(2) ?: text).substringBefore("\n\nHandle this:").lineSequence().firstOrNull { it.isNotBlank() }.orEmpty()
        return "mail from $from: ${body.take(140)}"
    }

    /**
     * Watches [runDir]/agent-wake for comms' "the manager has mail" markers (lib/ai/comms: _phone_wake) and runs the
     * inbox's turn. Markers already there (mail that came while the app wasn't running) count too.
     */
    fun startWake(
        context: Context,
        runDir: File,
    ) {
        if (wake != null) return
        val dir = File(runDir, "agent-wake").apply { mkdirs() }
        // The PowOS session writes the markers (as its user): the app must be able to remove them again.
        dir.setWritable(true, false)
        dir.setExecutable(true, false)
        dir.setReadable(true, false)
        val app = context.applicationContext
        val w = Wake(dir) { android.os.Handler(android.os.Looper.getMainLooper()).post { inboxArrived(app) } }
        wake = w
        w.startWatching()
        if (dir.listFiles { f -> f.name.startsWith("manager-") }?.onEach { it.delete() }?.isNotEmpty() == true) w.ring()
    }

    private var wake: Wake? = null

    private class Wake(
        private val dir: File,
        private val ring: () -> Unit,
    ) : android.os.FileObserver(dir, MOVED_TO or CLOSE_WRITE) {
        fun ring() = ring.invoke()

        override fun onEvent(
            event: Int,
            path: String?,
        ) {
            if (path == null || !path.startsWith("manager-")) return
            File(dir, path).delete()
            ring()
        }
    }

    private fun finishTool(ok: Boolean) {
        val i = items.indexOfLast { it is Item.Tool && it.ok == null }
        if (i >= 0) {
            items[i] = (items[i] as Item.Tool).copy(ok = ok)
            save()
        }
    }

    private fun add(item: Item) {
        items.add(item)
        while (items.size > KEEP) items.removeAt(0)
        save()
    }

    private fun save() {
        val f = file ?: return
        val lines = items.joinToString("\n") { it.json().toString() }
        runCatching {
            f.parentFile?.mkdirs()
            val tmp = File(f.path + ".tmp")
            tmp.writeText(lines)
            tmp.renameTo(f)
        }
    }

    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    private fun post(block: () -> Unit) {
        main.post(block)
    }
}
