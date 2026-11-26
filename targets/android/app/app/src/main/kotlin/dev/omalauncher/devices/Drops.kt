package dev.omalauncher.devices

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Drops between the owner's devices (docs/DEVICES.md "Clipboard and Send to"): the universal clipboard ("clip": offered
 * to every other device for 2 min) and Send to my device ("send": one device, kept until it is opened, at most 24 h).
 * The realm (PowStation enroll/powos-enroll.py /v1/account/drop*) only holds ciphertext: this device seals every drop
 * with the account's drop key (the account secret `powos.drop/key`, taken once and kept here) before it leaves, so
 * what it is (text, image, file name) never reaches the realm in the clear. Same envelope as lib/apps/powos-drop:
 *   ct = nonce(12) || AES-256-GCM(key, plaintext, aad "powos.drop/1/<kind>")
 *   plaintext = u32 BE header length || header JSON {v, type: text|link|image|file, name, mime, size, at} || body
 */
object Drops {
    const val KEY_APP = "powos.drop"
    const val KEY_NAME = "key"
    const val CLIP_MAX = 1024 * 1024 // a clip's body: text or a small image
    const val SEND_MAX = 16 * 1024 * 1024 - 64 * 1024 // the realm's 16 MB, less the envelope
    private const val NONCE = 12
    private val rnd = SecureRandom()

    data class Item(
        val type: String,
        val body: ByteArray,
        val name: String = "",
        val mime: String = "",
        val at: Long = System.currentTimeMillis(),
    ) {
        val text get() = String(body, Charsets.UTF_8)

        companion object {
            /** A link when the whole text is one http(s) URL, else text. */
            fun ofText(s: String) = Item(if (Regex("""https?://\S+""").matches(s.trim())) "link" else "text", s.toByteArray(), mime = "text/plain")
        }
    }

    /** A drop waiting for this device (GET /v1/account/drops). */
    data class Waiting(
        val id: String,
        val kind: String,
        val from: String,
        val fromName: String,
        val size: Long,
        val at: Long,
        val expires: Long,
    )

    // --- the envelope (pure: DropsTest)

    fun seal(
        key: ByteArray,
        kind: String,
        item: Item,
    ): ByteArray {
        val head =
            JSONObject().put("v", 1).put("type", item.type).put("name", item.name).put("mime", item.mime)
                .put("size", item.body.size).put("at", item.at).toString().toByteArray()
        val plain = ByteBuffer.allocate(4 + head.size + item.body.size).putInt(head.size).put(head).put(item.body).array()
        val nonce = ByteArray(NONCE).also { rnd.nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(aad(kind))
        return nonce + c.doFinal(plain)
    }

    /** The item, or null when it isn't one sealed with [key] for [kind] (another account's, damaged, moved). */
    fun open(
        key: ByteArray,
        kind: String,
        ct: ByteArray,
    ): Item? =
        runCatching {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, ct, 0, NONCE))
            c.updateAAD(aad(kind))
            val plain = ByteBuffer.wrap(c.doFinal(ct, NONCE, ct.size - NONCE))
            val n = plain.int
            require(n in 2..plain.remaining())
            val head = ByteArray(n).also { plain.get(it) }.let { JSONObject(String(it)) }
            val body = ByteArray(plain.remaining()).also { plain.get(it) }
            Item(head.optString("type", "file"), body, head.optString("name"), head.optString("mime"), head.optLong("at"))
        }.getOrNull()

    private fun aad(kind: String) = "powos.drop/1/$kind".toByteArray()

    /** Why [size] bytes can't go as a [kind] through the realm, or null when they can. */
    fun tooBig(
        kind: String,
        size: Long,
    ): String? {
        val cap = if (kind == "clip") CLIP_MAX else SEND_MAX
        if (size <= cap) return null
        val mb = (size + 1048575) / 1048576
        return if (kind == "clip") {
            "too big for the shared clipboard (${mb} MB, 1 MB max)"
        } else {
            "too big to send through PowStation (${mb} MB, 16 MB max): put it on the NAS (/mnt/nas/cdn) and send the link"
        }
    }

    fun parseWaiting(r: JSONObject): List<Waiting> {
        val a = r.optJSONArray("drops") ?: JSONArray()
        return (0 until a.length()).mapNotNull { a.optJSONObject(it) }.map {
            Waiting(it.optString("id"), it.optString("kind"), it.optString("from"), it.optString("from_name"), it.optLong("size"), it.optLong("at"), it.optLong("expires"))
        }
    }

    /** Where a send can go (GET /v1/devices): the account's other devices, not revoked - (id, name). */
    fun targets(r: JSONObject): List<Pair<String, String>> {
        val a = r.optJSONArray("devices") ?: JSONArray()
        return (0 until a.length()).mapNotNull { a.optJSONObject(it) }
            .filter { !it.optBoolean("self") && !it.optBoolean("revoked") && it.optString("id").isNotBlank() }
            .map { it.optString("id") to it.optString("name").ifBlank { it.optString("id") } }
    }

    // --- this device and the realm

    /** The account's drop key: kept here after the first time; made by the first device that needs one. */
    fun key(c: Context): ByteArray? {
        val f = java.io.File(c.filesDir, "devices/drop.key")
        runCatching { Base64.getDecoder().decode(f.readText().trim()) }.getOrNull()?.takeIf { it.size == 32 }?.let { return it }
        val (realm, token) = PowStation.credentials(c) ?: return null
        val mine = Base64.getEncoder().encodeToString(ByteArray(32).also { rnd.nextBytes(it) })
        val body = JSONObject().put("app", KEY_APP).put("name", KEY_NAME).put("value", mine).put("keep", true)
        val (st, r) = json("POST", "$realm/v1/account/secret", body.toString().toByteArray(), token) ?: return null
        if (st != 200) return null
        val value = r.optString("value").ifBlank { mine } // "value": the account had one already - that one
        val k = runCatching { Base64.getDecoder().decode(value) }.getOrNull()?.takeIf { it.size == 32 } ?: return null
        f.parentFile?.mkdirs()
        f.writeText(value)
        f.setReadable(false, false)
        f.setReadable(true, true)
        return k
    }

    /** The account dropped this device (401): what it kept from it goes. */
    fun forget(c: Context) {
        java.io.File(c.filesDir, "devices/drop.key").delete()
    }

    sealed interface Sent {
        data class Ok(val id: String) : Sent

        data class No(val why: String) : Sent
    }

    fun put(
        c: Context,
        kind: String,
        to: String,
        item: Item,
    ): Sent {
        tooBig(kind, item.body.size.toLong())?.let { return Sent.No(it) }
        val (realm, token) = PowStation.credentials(c) ?: return Sent.No("this device hasn't joined a PowStation (Settings > powstation)")
        val key = key(c) ?: return Sent.No("PowStation isn't reachable")
        val path = "/v1/account/drop?kind=$kind" + if (kind == "send") "&to=${java.net.URLEncoder.encode(to, "UTF-8")}" else ""
        val (st, r) = json("POST", realm + path, seal(key, kind, item), token, "application/octet-stream") ?: return Sent.No("PowStation isn't reachable")
        if (st == 401) forget(c)
        return if (st == 200) Sent.Ok(r.optString("id")) else Sent.No(r.optString("error_description").ifBlank { "PowStation answered $st" })
    }

    /** What waits for this device; null: not joined / not reachable. */
    fun waiting(
        c: Context,
        kind: String,
    ): List<Waiting>? {
        val (realm, token) = PowStation.credentials(c) ?: return null
        val (st, r) = json("GET", "$realm/v1/account/drops?kind=$kind", null, token) ?: return null
        if (st == 401) forget(c)
        return if (st == 200) parseWaiting(r) else null
    }

    fun take(
        c: Context,
        w: Waiting,
    ): Item? {
        val (realm, token) = PowStation.credentials(c) ?: return null
        val key = key(c) ?: return null
        val (st, bytes) = raw("GET", "$realm/v1/account/drop/${w.id}", null, token, null) ?: return null
        return if (st == 200) open(key, w.kind, bytes) else null
    }

    fun done(
        c: Context,
        id: String,
    ) {
        val (realm, token) = PowStation.credentials(c) ?: return
        json("POST", "$realm/v1/account/drop/$id/done", "{}".toByteArray(), token)
    }

    /** The account's other devices a send can go to; null when the realm can't be asked. */
    fun devices(c: Context): List<Pair<String, String>>? {
        val (realm, token) = PowStation.credentials(c) ?: return null
        val (st, r) = json("GET", "$realm/v1/devices", null, token) ?: return null
        return if (st == 200) targets(r) else null
    }

    private fun json(
        method: String,
        url: String,
        body: ByteArray?,
        token: String,
        ctype: String = "application/json",
    ): Pair<Int, JSONObject>? =
        raw(method, url, body, token, ctype)?.let { (st, b) -> st to (runCatching { JSONObject(String(b)) }.getOrNull() ?: JSONObject()) }

    // HACK: plain HTTP to the realm on the LAN/VPN like PowStation.kt (the realm serves only that); the drop itself is
    // sealed here, but the bearer crosses the LAN/VPN leg in the clear. Real fix: the realm CA / a .pow certificate.
    private fun raw(
        method: String,
        url: String,
        body: ByteArray?,
        token: String,
        ctype: String?,
    ): Pair<Int, ByteArray>? =
        runCatching {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.requestMethod = method
            conn.connectTimeout = 2500
            conn.readTimeout = 20000
            conn.setRequestProperty("Authorization", "Bearer $token")
            try {
                if (body != null) {
                    conn.doOutput = true
                    conn.setFixedLengthStreamingMode(body.size)
                    conn.setRequestProperty("Content-Type", ctype ?: "application/octet-stream")
                    conn.outputStream.use { it.write(body) }
                }
                val st = conn.responseCode
                val out = ByteArrayOutputStream()
                ((if (st < 400) conn.inputStream else conn.errorStream))?.use { it.copyTo(out) }
                st to out.toByteArray()
            } finally {
                conn.disconnect()
            }
        }.getOrNull()
}
