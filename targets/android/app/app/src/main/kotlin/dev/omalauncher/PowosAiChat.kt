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

    fun load(context: Context) {
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

    private fun turn(prompt: String) {
        val errors = ArrayDeque<String>()
        var answered = false
        val exit =
            runCatching {
                val process = RootedGuest.process("cd ~ && exec powos manager --once-stdin --json-events", mergeErrors = false).start()
                Thread({
                    process.errorStream.bufferedReader().forEachLine {
                        synchronized(errors) {
                            errors.addLast(it)
                            if (errors.size > 20) errors.removeFirst()
                        }
                    }
                }, "powos-ai-stderr").start()
                process.outputStream.use { it.write(prompt.toByteArray()) }
                process.inputStream.bufferedReader().forEachLine { line ->
                    val ev = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
                    when (ev.optString("kind")) {
                        "assistant" -> {
                            answered = true
                            post { add(Item.Assistant(ev.optString("text"))) }
                        }
                        "tool_use" -> post { add(Item.Tool(ev.optString("name"), ev.optString("hint"))) }
                        "tool_result" -> post { finishTool(ev.optBoolean("ok", true)) }
                    }
                }
                process.waitFor()
            }.getOrElse {
                Log.w(TAG, "manager turn failed", it)
                -1
            }
        post {
            if (exit != 0 || !answered) {
                val why = synchronized(errors) { errors.lastOrNull { it.isNotBlank() } }
                add(Item.Note("PowOS AI didn't answer" + (why?.let { ": $it" } ?: " (exit $exit)"), error = true))
            }
            busy = false
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
