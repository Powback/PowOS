package dev.omalauncher.devices

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The universal clipboard on this phone (docs/DEVICES.md "Clipboard and Send to"). Android lets only the input method
 * (or the app in front) read the clipboard, so the swipe keyboard is the source here: it hands each copy to PowOS
 * (KeyboardAiProvider "clip.push"), which seals it ([Drops]) and offers it to the owner's other devices for 2 min. Their
 * copies come back the same way: the keyboard's clipboard panel asks "clip.offered" when it opens. Nothing is kept: the
 * realm forgets a clip after 2 min, this phone keeps the opened ones in memory only. One switch per device ([enabled]).
 */
object ClipShare {
    private const val PREFS = "clip_share"
    private const val KEY_ON = "on"
    private val opened = LinkedHashMap<String, Pair<Drops.Waiting, Drops.Item>>() // id -> clip, memory only

    fun enabled(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ON, true)

    fun setEnabled(
        c: Context,
        on: Boolean,
    ) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ON, on).apply()
        if (!on) synchronized(opened) { opened.clear() }
    }

    /** A copy made here: offered to the other devices (off, not joined, too big: nothing leaves). */
    fun push(
        c: Context,
        item: Drops.Item,
    ): JSONObject {
        if (!enabled(c)) return JSONObject().put("ok", false).put("why", "off")
        return when (val r = Drops.put(c, "clip", "*", item)) {
            is Drops.Sent.Ok -> JSONObject().put("ok", true).put("id", r.id)
            is Drops.Sent.No -> JSONObject().put("ok", false).put("why", r.why)
        }
    }

    /**
     * The other devices' clips of the last 2 min, newest first: {clips: [{id, from, type, text?, mime?, size, at,
     * expires}]}. An image's bytes stay here ([image] puts one on the clipboard for the keyboard to paste).
     */
    fun offered(c: Context): JSONObject {
        if (!enabled(c)) return JSONObject().put("ok", true).put("on", false).put("clips", JSONArray())
        val waiting = Drops.waiting(c, "clip") ?: return JSONObject().put("ok", true).put("on", true).put("offline", true).put("clips", JSONArray())
        val got =
            synchronized(opened) {
                opened.keys.retainAll(waiting.map { it.id }.toSet())
                waiting.mapNotNull { w -> opened[w.id] ?: Drops.take(c, w)?.let { (w to it).also { p -> opened[w.id] = p } } }
            }
        return JSONObject().put("ok", true).put("on", true).put("clips", offeredJson(got))
    }

    /** The keyboard's list (pure: DropsTest). */
    fun offeredJson(got: List<Pair<Drops.Waiting, Drops.Item>>): JSONArray =
        JSONArray().apply {
            got.sortedByDescending { it.first.at }.forEach { (w, i) ->
                val o =
                    JSONObject().put("id", w.id).put("from", w.fromName.ifBlank { w.from }).put("type", i.type)
                        .put("size", i.body.size).put("at", w.at).put("expires", w.expires)
                if (i.type == "text" || i.type == "link") o.put("text", i.text) else o.put("mime", i.mime).put("name", i.name)
                put(o)
            }
        }

    /** Puts an opened image clip on this phone's clipboard (a content URI the pasting app may read); false: gone. */
    fun image(
        c: Context,
        id: String,
    ): Boolean {
        val item = synchronized(opened) { opened[id]?.second } ?: return false
        val dir = File(c.cacheDir, "share/clips").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() } // one at a time: the last pasted image only
        val ext = item.mime.substringAfter('/', "png").take(8).filter { it.isLetterOrDigit() }.ifBlank { "png" }
        val f = File(dir, "clip.$ext").apply { writeBytes(item.body) }
        val uri = FileProvider.getUriForFile(c, c.packageName + ".files", f)
        val cm = c.getSystemService(ClipboardManager::class.java) ?: return false
        cm.setPrimaryClip(ClipData.newUri(c.contentResolver, "image", uri))
        // the input method pastes it: let the current one read the file
        currentImePackage(c)?.let { c.grantUriPermission(it, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        return true
    }

    private fun currentImePackage(c: Context): String? =
        android.provider.Settings.Secure.getString(c.contentResolver, android.provider.Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.substringBefore('/')
}
