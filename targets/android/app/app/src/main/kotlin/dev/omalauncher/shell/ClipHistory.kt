package dev.omalauncher.shell

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The clipboard's recent copies, newest first: what the terminals' paste key shows as cards (shell/ui/terminal.tsx
 * ClipPicker, the board's "paste UX: tapping paste shows a CARD picker of clipboard history"). Local only: one file in
 * the app's no-backup dir, never synced, never in Android's backup. A copy already there moves to the front; blank
 * copies are dropped; a long one is kept to [MAX_CHARS]; at most [max] are kept.
 *
 * Fed by every copy PowOS sees ([see]): the terminals' copy key and Termux's selection Copy and OSC 52
 * (ShellTermViews), the page's clipboard.write, and the system clipboard whenever it changes or the picker opens while
 * the home has the focus (Android 10+ lets only the focused app read it - so copies made in another app show once the
 * home is back in front). Clips the source marks sensitive (Android 13's EXTRA_IS_SENSITIVE: passwords) are not kept.
 */
class ClipHistory(
    private val file: File?,
    private val max: Int = MAX,
    private val now: () -> Long = System::currentTimeMillis,
    /** Where the file is written (off the main thread on the device; the caller's thread in tests). */
    private val io: (Runnable) -> Unit = Runnable::run,
) {
    data class Clip(
        val text: String,
        val at: Long,
    )

    private val clips = ArrayList<Clip>()

    init {
        file?.takeIf { it.isFile }?.let { f -> runCatching { clips += decode(f.readText()).take(max) } }
    }

    /** Adds [text] as the newest copy; false when it was blank or already the newest. */
    @Synchronized
    fun add(text: String?): Boolean {
        val t = text?.take(MAX_CHARS) ?: return false
        if (t.isBlank()) return false
        if (clips.firstOrNull()?.text == t) return false
        clips.removeAll { it.text == t }
        clips.add(0, Clip(t, now()))
        while (clips.size > max) clips.removeAt(clips.size - 1)
        save()
        return true
    }

    @Synchronized
    fun list(): List<Clip> = clips.toList()

    /** The page's shape (shell/types.ts Clip): [{text, at}], newest first. */
    @Synchronized
    fun toJson(): JSONArray = encode(clips)

    private fun save() {
        val f = file ?: return
        val json = encode(clips).toString()
        io(
            Runnable {
                runCatching {
                    f.parentFile?.mkdirs()
                    val tmp = File(f.path + ".tmp")
                    tmp.writeText(json)
                    tmp.renameTo(f)
                }
            },
        )
    }

    companion object {
        const val MAX = 30
        const val MAX_CHARS = 64 * 1024

        fun encode(clips: List<Clip>): JSONArray = JSONArray().apply { clips.forEach { put(JSONObject().put("text", it.text).put("at", it.at)) } }

        fun decode(json: String): List<Clip> {
            val a = JSONArray(json)
            return (0 until a.length()).mapNotNull { i ->
                val o = a.optJSONObject(i) ?: return@mapNotNull null
                val text = o.optString("text").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                Clip(text, o.optLong("at"))
            }
        }

        @Volatile private var device: ClipHistory? = null

        /** The device's one history (every ShellBridge - home, a dream, an overlay - shares it). */
        fun of(context: Context): ClipHistory =
            device ?: synchronized(this) {
                device ?: ClipHistory(
                    File(context.noBackupFilesDir, "clip-history.json"),
                    io = java.util.concurrent.Executors.newSingleThreadExecutor()::execute,
                ).also { device = it }
            }

        /** The system clipboard's text now, unless it's empty, unreadable (not focused) or marked sensitive. */
        fun primaryText(
            context: Context,
            cm: ClipboardManager,
        ): String? {
            val clip: ClipData = runCatching { cm.primaryClip }.getOrNull()?.takeIf { it.itemCount > 0 } ?: return null
            if (Build.VERSION.SDK_INT >= 33 && clip.description.extras?.getBoolean("android.content.extra.IS_SENSITIVE") == true) return null
            return clip.getItemAt(0).coerceToText(context)?.toString()
        }
    }
}
