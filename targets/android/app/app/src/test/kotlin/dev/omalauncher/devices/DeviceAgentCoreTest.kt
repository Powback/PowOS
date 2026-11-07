package dev.omalauncher.devices

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** The no-root phone's agent speaks powos-deviced's v1 protocol (test/tier1/test-deviced.py pins the same rules). */
class DeviceAgentCoreTest {
    private val ran = mutableListOf<String>()
    private val backend =
        object : DeviceBackend {
            override fun caps() = listOf("status", "screen_on", "ring")

            override fun status() = JSONObject().put("online", true).put("screen", "off").put("locked", true)

            override fun act(
                action: String,
                args: JSONObject,
                force: Boolean,
            ): JSONObject {
                ran += action
                return JSONObject().put("done", true)
            }
        }
    private var shown: String? = null
    private val dir = Files.createTempDirectory("deviced").toFile()
    private var t = 1_000_000L
    private val core = DeviceAgentCore(dir, { "Phone" }, backend, { _, code -> shown = code }, { t })

    private fun call(
        m: String,
        p: String,
        body: JSONObject? = null,
        token: String? = null,
    ) = core.handle(m, p, token?.let { "Bearer $it" }, body?.toString() ?: "")

    private fun pair(): String {
        val r = call("POST", "/v1/pair", JSONObject().put("id", "c46227ead3c53d80").put("name", "Desk").put("kind", "desktop"))
        assertEquals(200, r.status)
        assertFalse("the code is never in the answer", r.body.toString().contains(shown!!))
        val ok = call("POST", "/v1/pair/confirm", JSONObject().put("request", r.body.getString("request")).put("code", shown))
        assertEquals(200, ok.status)
        return ok.body.getString("token")
    }

    @Test
    fun infoOnlyUntilPaired() {
        val info = call("GET", "/v1/info")
        assertEquals(200, info.status)
        assertEquals("phone", info.body.getString("kind"))
        assertEquals(listOf("status", "screen_on", "ring"), (0 until 3).map { info.body.getJSONArray("caps").getString(it) })
        assertEquals(401, call("GET", "/v1/status").status)
        assertEquals(401, call("POST", "/v1/action", JSONObject().put("action", "ring")).status)
        assertEquals(401, call("GET", "/v1/status", token = "guess").status)
        assertTrue(ran.isEmpty())
    }

    @Test
    fun pairedTokenRunsOnlyAdvertisedActionsAndIsStoredHashed() {
        val token = pair()
        val st = call("GET", "/v1/status", token = token)
        assertEquals(200, st.status)
        assertEquals("off", st.body.getJSONObject("status").getString("screen"))
        assertEquals(200, call("POST", "/v1/action", JSONObject().put("action", "screen_on"), token).status)
        assertEquals(listOf("screen_on"), ran)
        assertEquals(404, call("POST", "/v1/action", JSONObject().put("action", "sleep"), token).status)
        assertEquals(400, call("POST", "/v1/action", JSONObject().put("action", "explode"), token).status)
        val peers = File(dir, "peers.json").readText()
        assertFalse(peers.contains(token))
        assertTrue(peers.contains(DeviceAgentCore.sha(token)))
        // Revoked from any paired device: the token stops at once.
        assertEquals(true, call("DELETE", "/v1/peers/c46227ead3c53d80", token = token).body.getBoolean("revoked"))
        assertEquals(401, call("GET", "/v1/status", token = token).status)
    }

    @Test
    fun wrongCodesExpiryAndPendingLimit() {
        val r = call("POST", "/v1/pair", JSONObject().put("id", "a").put("name", "A"))
        val req = r.body.getString("request")
        repeat(4) { assertEquals(401, call("POST", "/v1/pair/confirm", JSONObject().put("request", req).put("code", "x")).status) }
        assertEquals(401, call("POST", "/v1/pair/confirm", JSONObject().put("request", req).put("code", "y")).status)
        // The 5th wrong try ended the request: even the right code is too late.
        assertEquals(410, call("POST", "/v1/pair/confirm", JSONObject().put("request", req).put("code", shown)).status)
        repeat(3) { assertEquals(200, call("POST", "/v1/pair", JSONObject().put("id", "b$it").put("name", "B")).status) }
        assertEquals(409, call("POST", "/v1/pair", JSONObject().put("id", "c").put("name", "C")).status)
        t += DeviceAgentCore.TTL_MS + 1
        val late = call("POST", "/v1/pair", JSONObject().put("id", "d").put("name", "D"))
        assertEquals(200, late.status)
        t += DeviceAgentCore.TTL_MS + 1
        assertEquals(410, call("POST", "/v1/pair/confirm", JSONObject().put("request", late.body.getString("request")).put("code", shown)).status)
        assertEquals(400, call("POST", "/v1/pair", JSONObject()).status)
    }

    @Test
    fun identityIsStable() {
        val a = core.id
        assertEquals(16, a.length)
        assertEquals(a, DeviceAgentCore(dir, { "Phone" }, backend, { _, _ -> }).id)
    }

    private fun File(
        d: java.io.File,
        n: String,
    ) = java.io.File(d, n)
}
