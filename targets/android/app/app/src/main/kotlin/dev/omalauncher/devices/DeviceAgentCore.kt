package dev.omalauncher.devices

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The PowOS device agent's protocol (v1), as the PowOS app serves it on a phone WITHOUT root: the same protocol as
 * lib/devices/powos-deviced (docs/DEVICES.md, docs/research/device-ecosystem.md D4/D5), so Desk's Devices app and
 * `powos devices` see and control this phone exactly like any other PowOS device.
 *
 *   GET  /v1/info            no auth: {id, name, kind, v, caps}
 *   POST /v1/pair            no auth: {id, name, kind} -> {request, expires_s}; the code is shown ON THIS PHONE
 *   POST /v1/pair/confirm    no auth: {request, code} -> {token, device}; 5 tries, 2 min, 3 waiting at most
 *   GET  /v1/status          Bearer token
 *   POST /v1/action          Bearer token: {action, force?, args?}; only advertised caps
 *   GET  /v1/peers, DELETE /v1/peers/<id>   Bearer token
 *
 * Pure Kotlin (no Android types): the transport and the backend are DeviceAgentHost's. A peer is stored by the
 * SHA-256 of its token only; there is no unauthenticated action.
 */
class DeviceAgentCore(
    private val dir: File,
    private val name: () -> String,
    private val backend: DeviceBackend,
    private val showCode: (from: String, code: String) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val random = SecureRandom()
    private val pending = LinkedHashMap<String, Pending>()

    private class Pending(val code: String, val peer: JSONObject, val expires: Long, var tries: Int = 0)

    class Reply(val status: Int, val body: JSONObject)

    val id: String
        @Synchronized get() {
            val f = File(dir, "identity.json")
            runCatching { JSONObject(f.readText()).getString("id") }.getOrNull()?.let { return it }
            val id = hex(ByteArray(8).also(random::nextBytes))
            save(f, JSONObject().put("id", id).put("created", clock() / 1000))
            return id
        }

    fun info(): JSONObject =
        JSONObject()
            .put("id", id)
            .put("name", name())
            .put("kind", "phone")
            .put("v", 1)
            .put("caps", JSONArray(backend.caps()))

    fun handle(
        method: String,
        rawPath: String,
        authorization: String?,
        body: String,
    ): Reply =
        try {
            Reply(200, route(method, rawPath.substringBefore('?').trimEnd('/'), authorization, body))
        } catch (e: DeviceActionError) {
            Reply(HTTP[e.code] ?: 500, JSONObject().put("ok", false).put("error", e.message).put("code", e.code))
        } catch (e: Exception) {
            Reply(500, JSONObject().put("ok", false).put("error", "internal error").put("code", "failed"))
        }

    private fun route(
        method: String,
        path: String,
        authorization: String?,
        body: String,
    ): JSONObject {
        open(method, path, body)?.let { return it }
        val peer = peer(authorization) ?: throw DeviceActionError("this device doesn't know you - pair again", "auth")
        if (method == "DELETE" && path.startsWith("/v1/peers/")) return JSONObject().put("revoked", revoke(path.substringAfterLast('/')))
        return when ("$method $path") {
            "GET /v1/status" -> info().put("status", backend.status())
            "POST /v1/action" -> action(peer.first, json(body))
            "GET /v1/peers" -> peerList()
            else -> throw DeviceActionError("no such endpoint", "unsupported")
        }
    }

    /** What an unpaired device may call: the card and pairing. */
    private fun open(
        method: String,
        path: String,
        body: String,
    ): JSONObject? =
        when ("$method $path") {
            "GET /v1/info" -> info()
            "POST /v1/pair" -> pairStart(json(body))
            "POST /v1/pair/confirm" -> pairConfirm(json(body))
            else -> null
        }

    private fun action(
        by: String,
        b: JSONObject,
    ): JSONObject {
        val action = b.optString("action")
        if (action !in ACTIONS) throw DeviceActionError("no action '${action.take(24)}'", "bad-request")
        if (action !in backend.caps()) throw DeviceActionError("$action: this device can't", "unsupported")
        log("action $action by $by")
        val result = if (action == "status") backend.status() else backend.act(action, b.optJSONObject("args") ?: JSONObject(), b.optBoolean("force"))
        return JSONObject().put("ok", true).put("action", action).put("result", result)
    }

    private fun peerList(): JSONObject {
        val out = JSONArray()
        val all = peers()
        for (k in all.keys()) {
            val p = all.getJSONObject(k)
            out.put(JSONObject().put("id", k).put("name", p.optString("name")).put("kind", p.optString("kind")).put("paired", p.optLong("paired")))
        }
        return JSONObject().put("peers", out)
    }

    @Synchronized
    private fun pairStart(b: JSONObject): JSONObject {
        val pid = b.optString("id").take(64)
        val pname = b.optString("name").take(64)
        if (pid.isEmpty() || pname.isEmpty()) throw DeviceActionError("pairing needs the asking device's id and name", "bad-request")
        val now = clock()
        pending.entries.removeAll { it.value.expires < now }
        if (pending.size >= PENDING_MAX) throw DeviceActionError("too many pairing requests waiting here - try again in two minutes", "busy")
        val req = hex(ByteArray(8).also(random::nextBytes))
        val code = "%06d".format(random.nextInt(1_000_000))
        pending[req] = Pending(code, JSONObject().put("id", pid).put("name", pname).put("kind", b.optString("kind").take(24)), now + TTL_MS)
        showCode(pname, code)
        return JSONObject().put("request", req).put("expires_s", TTL_MS / 1000)
    }

    @Synchronized
    private fun pairConfirm(b: JSONObject): JSONObject {
        val req = b.optString("request")
        val p = pending[req]
        if (p == null || p.expires < clock()) {
            pending.remove(req)
            throw DeviceActionError("that pairing request has expired - start again", "expired")
        }
        p.tries++
        if (!MessageDigest.isEqual(p.code.toByteArray(), b.optString("code").toByteArray())) {
            if (p.tries >= TRIES) pending.remove(req)
            throw DeviceActionError("wrong code", "auth")
        }
        pending.remove(req)
        val token = b64(ByteArray(32).also(random::nextBytes))
        val all = peers()
        all.put(p.peer.getString("id"), JSONObject(p.peer.toString()).put("token_sha256", sha(token)).put("paired", clock() / 1000))
        save(File(dir, "peers.json"), all)
        return JSONObject().put("token", token).put("device", info())
    }

    @Synchronized
    fun revoke(pid: String): Boolean {
        val all = peers()
        if (!all.has(pid)) return false
        all.remove(pid)
        save(File(dir, "peers.json"), all)
        return true
    }

    @Synchronized
    private fun peer(authorization: String?): Pair<String, JSONObject>? {
        val token = authorization?.takeIf { it.startsWith("Bearer ") }?.substring(7)?.trim().orEmpty()
        if (token.isEmpty()) return null
        val h = sha(token).toByteArray()
        val all = peers()
        for (k in all.keys()) {
            val p = all.getJSONObject(k)
            if (MessageDigest.isEqual(p.optString("token_sha256").toByteArray(), h)) return k to p
        }
        return null
    }

    private fun peers(): JSONObject = runCatching { JSONObject(File(dir, "peers.json").readText()) }.getOrElse { JSONObject() }

    private fun save(
        f: File,
        o: JSONObject,
    ) {
        dir.mkdirs()
        val tmp = File(dir, "${f.name}.tmp")
        tmp.writeText(o.toString(1))
        tmp.setReadable(false, false)
        tmp.setReadable(true, true)
        tmp.renameTo(f)
    }

    private fun json(body: String): JSONObject =
        if (body.isBlank()) {
            JSONObject()
        } else {
            runCatching { JSONObject(body) }.getOrElse { throw DeviceActionError("not a JSON object", "bad-request") }
        }

    var log: (String) -> Unit = {}

    companion object {
        const val PORT = 3416
        const val TTL_MS = 120_000L
        const val TRIES = 5
        const val PENDING_MAX = 3
        val ACTIONS = setOf("status", "lock", "screen_off", "screen_on", "sleep", "wake", "ring")
        val HTTP = mapOf("bad-request" to 400, "auth" to 401, "unsupported" to 404, "expired" to 410, "busy" to 409, "failed" to 500)

        fun sha(s: String): String = hex(MessageDigest.getInstance("SHA-256").digest(s.toByteArray()))

        fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }

        private fun b64(b: ByteArray): String =
            java.util.Base64
                .getUrlEncoder()
                .withoutPadding()
                .encodeToString(b)
    }
}

/** What this device can do and how: Android's own APIs in the app (DeviceAgentHost), a fake in the tests. */
interface DeviceBackend {
    fun caps(): List<String>

    fun status(): JSONObject

    fun act(
        action: String,
        args: JSONObject,
        force: Boolean,
    ): JSONObject
}

class DeviceActionError(
    message: String,
    val code: String,
) : Exception(message)
