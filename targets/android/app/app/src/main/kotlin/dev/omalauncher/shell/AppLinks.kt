package dev.omalauncher.shell

import android.content.Context
import android.content.res.Resources
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.ZipFile

/**
 * "apps.links" (App API's "+ add app", tools/app-api/appcap_add.py from_android): the deep links an installed Android
 * app opens - every exported activity's intent filter with action VIEW and category BROWSABLE, as URIs (scheme://host
 * + path; a path prefix or pattern ends in ".*"). READ-ONLY: the app's own base APK manifest is read; no intent is
 * fired, nothing is resolved against the app, no other app is asked.
 *
 * Why the manifest itself: Android has no public call that lists an app's intent filters (queryIntentActivities only
 * matches a given intent), and the app's AssetManager answers "AndroidManifest.xml" from its last split APK when it has
 * config splits. So base.apk's compiled manifest is parsed here (the binary XML chunk format, attributes matched by
 * their framework resource ids, so obfuscated attribute names don't matter); a value that is a resource reference
 * (@string/host) is read through the app's public Resources.
 */
object AppLinks {
    private const val MAX = 60
    private const val VIEW = "android.intent.action.VIEW"
    private const val BROWSABLE = "android.intent.category.BROWSABLE"

    fun read(
        context: Context,
        pkg: String,
    ): JSONObject {
        val pm = context.packageManager
        val info = pm.getApplicationInfo(pkg, 0)
        val res = runCatching { pm.getResourcesForApplication(info) }.getOrNull()
        val manifest = ZipFile(info.sourceDir).use { z -> z.getEntry("AndroidManifest.xml")?.let { e -> z.getInputStream(e).use { it.readBytes() } } }
        val links = JSONArray()
        if (manifest != null) {
            for (l in Manifest(manifest, res).links().distinct().take(MAX)) links.put(JSONObject().put("uri", l.first).put("activity", l.second))
        }
        return JSONObject().put("pkg", pkg).put("label", pm.getApplicationLabel(info).toString()).put("links", links)
    }

    /** One intent filter being read: what it says, and the activity it belongs to. */
    private class Filter(
        val activity: String,
    ) {
        val actions = HashSet<String>()
        val categories = HashSet<String>()
        val schemes = ArrayList<String>()
        val hosts = ArrayList<String>()
        val paths = ArrayList<String>()

        fun uris(): List<String> {
            if (VIEW !in actions || BROWSABLE !in categories) return emptyList()
            val hs = hosts.ifEmpty { listOf("") }
            val ps = paths.ifEmpty { listOf("") }
            return schemes.flatMap { s -> hs.flatMap { h -> ps.map { p -> if (h.isEmpty()) "$s:" else "$s://$h$p" } } }
        }
    }

    /** A compiled AndroidManifest.xml (AAPT binary XML): its string pool, resource-id map and element events. */
    private class Manifest(
        bytes: ByteArray,
        private val res: Resources?,
    ) {
        private val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        private var strings: List<String> = emptyList()
        private var ids: IntArray = IntArray(0)
        private val out = ArrayList<Pair<String, String>>()
        private var activity: String? = null
        private var filter: Filter? = null

        fun links(): List<Pair<String, String>> {
            var at = 8
            while (at + 8 <= b.limit()) {
                val type = b.getShort(at).toInt() and 0xffff
                val size = b.getInt(at + 4)
                if (size < 8) break
                chunk(type, at)
                at += size
            }
            return out
        }

        private fun chunk(
            type: Int,
            at: Int,
        ) {
            when (type) {
                0x0001 -> strings = pool(at)
                0x0180 -> ids = IntArray((b.getInt(at + 4) - 8) / 4) { b.getInt(at + 8 + it * 4) }
                0x0102 -> start(at)
                0x0103 -> end(str(b.getInt(at + 20)))
            }
        }

        private fun pool(at: Int): List<String> {
            val count = b.getInt(at + 8)
            val utf8 = b.getInt(at + 16) and 0x100 != 0
            val data = at + b.getInt(at + 20)
            return List(count) { i -> runCatching { decode(data + b.getInt(at + 28 + i * 4), utf8) }.getOrDefault("") }
        }

        private fun decode(
            p: Int,
            utf8: Boolean,
        ): String {
            if (!utf8) {
                var n = b.getShort(p).toInt() and 0xffff
                var q = p + 2
                if (n and 0x8000 != 0) n = ((n and 0x7fff) shl 16) or (b.getShort(p + 2).toInt() and 0xffff).also { q += 2 }
                return String(CharArray(n) { b.getChar(q + it * 2) })
            }
            var q = p + if (b.get(p).toInt() and 0x80 != 0) 2 else 1 // the length in UTF-16 units, unused
            var n = b.get(q).toInt() and 0xff
            q += 1
            if (n and 0x80 != 0) n = ((n and 0x7f) shl 8) or (b.get(q).toInt() and 0xff).also { q += 1 }
            return String(b.array(), q, n, Charsets.UTF_8)
        }

        private fun str(i: Int) = if (i in strings.indices) strings[i] else ""

        private fun start(at: Int) {
            val ext = at + 16
            val attrs = HashMap<Int, String>()
            val first = ext + (b.getShort(ext + 8).toInt() and 0xffff)
            val step = b.getShort(ext + 10).toInt() and 0xffff
            repeat(b.getShort(ext + 12).toInt() and 0xffff) { k -> attr(first + k * step)?.let { attrs[it.first] = it.second } }
            element(str(b.getInt(ext + 4)), attrs)
        }

        /** An android: attribute this reads, as (framework resource id, value); null for the others. */
        private fun attr(p: Int): Pair<Int, String>? {
            val name = b.getInt(p + 4)
            val id = if (name in ids.indices) ids[name] else NAMES[str(name)] ?: return null
            if (id !in NAMES.values) return null
            val raw = b.getInt(p + 8)
            val type = b.get(p + 15).toInt() and 0xff
            val data = b.getInt(p + 16)
            val v =
                when {
                    raw != -1 -> str(raw)
                    type == 0x12 -> (data != 0).toString()
                    type == 0x01 -> res?.let { r -> runCatching { r.getString(data) }.getOrNull() } ?: return null
                    else -> data.toString()
                }
            return id to v
        }

        private fun element(
            tag: String,
            a: Map<Int, String>,
        ) {
            when (tag) {
                "activity", "activity-alias" -> activity = a[NAME].takeIf { a[EXPORTED] != "false" && a[ENABLED] != "false" }
                "intent-filter" -> filter = activity?.let { Filter(it) }
                else -> filter?.let { inFilter(it, tag, a) }
            }
        }

        private fun inFilter(
            f: Filter,
            tag: String,
            a: Map<Int, String>,
        ) {
            when (tag) {
                "action" -> a[NAME]?.let { f.actions += it }
                "category" -> a[NAME]?.let { f.categories += it }
                "data" -> data(f, a)
            }
        }

        private fun data(
            f: Filter,
            a: Map<Int, String>,
        ) {
            a[SCHEME]?.let { f.schemes += it }
            a[HOST]?.let { h -> f.hosts += h + (a[PORT]?.let { ":$it" } ?: "") }
            a[PATH]?.let { f.paths += it }
            a[PREFIX]?.let { f.paths += "$it.*" }
            a[PATTERN]?.let { f.paths += it }
        }

        private fun end(tag: String) {
            when (tag) {
                "intent-filter" -> filter?.let { f -> f.uris().forEach { out += it to f.activity } }.also { filter = null }
                "activity", "activity-alias" -> activity = null
            }
        }
    }

    private const val NAME = 0x01010003
    private const val ENABLED = 0x0101000e
    private const val EXPORTED = 0x01010010
    private const val SCHEME = 0x01010027
    private const val HOST = 0x01010028
    private const val PORT = 0x01010029
    private const val PATH = 0x0101002a
    private const val PREFIX = 0x0101002b
    private const val PATTERN = 0x0101002c

    /** The android: attributes read, by name - for a manifest without a resource-id map. */
    private val NAMES =
        mapOf(
            "name" to NAME, "enabled" to ENABLED, "exported" to EXPORTED, "scheme" to SCHEME, "host" to HOST, "port" to PORT,
            "path" to PATH, "pathPrefix" to PREFIX, "pathPattern" to PATTERN,
        )
}
