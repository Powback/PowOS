package dev.omalauncher.devices

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/**
 * The no-root phone's lock (LockActions + WithLock, the way DeviceAgentHost wires it): lock/screen_off advertised
 * exactly while the person allows the lock admin, read live (a grant or a revoke is in the next answer), refused with
 * how to allow it otherwise, and screen_off is a lock. Nothing locks without the grant.
 */
class LockActionsTest {
    private var allowed = false
    private var locks = 0
    private val locker =
        object : Locker {
            override fun allowed() = allowed

            override fun lock() {
                check(allowed) { "locked without the grant" }
                locks++
            }
        }
    private val base =
        object : DeviceBackend {
            override fun caps() = listOf("status", "screen_on", "ring")

            override fun status() = JSONObject().put("online", true)

            override fun act(
                action: String,
                args: JSONObject,
                force: Boolean,
            ) = JSONObject().put("done", true).put("by", "base")
        }
    private var shown: String? = null
    private val core = DeviceAgentCore(Files.createTempDirectory("deviced").toFile(), { "Phone" }, WithLock(base, LockActions(locker)), { _, c -> shown = c })

    private fun call(
        m: String,
        p: String,
        body: JSONObject? = null,
        token: String? = null,
    ) = core.handle(m, p, token?.let { "Bearer $it" }, body?.toString() ?: "")

    private fun token(): String {
        val r = call("POST", "/v1/pair", JSONObject().put("id", "desk").put("name", "Desk"))
        return call("POST", "/v1/pair/confirm", JSONObject().put("request", r.body.getString("request")).put("code", shown)).body.getString("token")
    }

    private fun caps(): List<String> {
        val a = call("GET", "/v1/info").body.getJSONArray("caps")
        return (0 until a.length()).map(a::getString)
    }

    private fun act(
        t: String,
        action: String,
    ) = call("POST", "/v1/action", JSONObject().put("action", action), t)

    @Test
    fun notAdvertisedNorDoneUntilAllowed() {
        val t = token()
        assertEquals(listOf("status", "screen_on", "ring"), caps())
        for (a in listOf("lock", "screen_off")) {
            val r = act(t, a)
            assertEquals(404, r.status)
            assertEquals("unsupported", r.body.getString("code"))
            assertTrue("the refusal says how to allow it: ${r.body}", r.body.getString("error").contains("Allow lock"))
        }
        assertEquals(0, locks)
    }

    @Test
    fun grantAndRevokeReachTheNextAnswer() {
        val t = token()
        allowed = true
        assertEquals(listOf("status", "screen_on", "ring", "lock", "screen_off"), caps())
        val status = call("GET", "/v1/status", token = t).body.getJSONArray("caps")
        assertTrue((0 until status.length()).map(status::getString).contains("lock"))
        allowed = false
        assertFalse(caps().contains("lock"))
        assertFalse(caps().contains("screen_off"))
        assertEquals(404, act(t, "lock").status)
        assertEquals(0, locks)
    }

    @Test
    fun lockAndScreenOffLockWhileAllowed() {
        val t = token()
        allowed = true
        val lock = act(t, "lock")
        assertEquals(200, lock.status)
        assertTrue(lock.body.getJSONObject("result").getBoolean("locked"))
        val off = act(t, "screen_off")
        assertEquals(200, off.status)
        assertEquals("lock", off.body.getJSONObject("result").getString("as"))
        assertEquals(2, locks)
        // The rest is still the base backend's.
        assertEquals("base", act(t, "ring").body.getJSONObject("result").getString("by"))
        assertEquals(2, locks)
    }

    @Test
    fun revokedBetweenCheckAndActIsRefusedNotLocked() {
        // LockActions checks again itself: a revoke racing an action never locks.
        allowed = false
        val e = runCatching { LockActions(locker).act("lock") }.exceptionOrNull()
        assertTrue(e is DeviceActionError && e.code == "unsupported")
        assertEquals(0, locks)
    }

    @Test
    fun unpairedCantLockEvenWhenAllowed() {
        allowed = true
        assertEquals(401, call("POST", "/v1/action", JSONObject().put("action", "lock")).status)
        assertEquals(0, locks)
    }
}
