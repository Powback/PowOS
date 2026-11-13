package dev.omalauncher.devices

import dev.omalauncher.ui.OwnerConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Join your PowStation" (PowStation.kt): the address field, what is kept of the realm's answer, the owner config. */
class PowStationTest {
    @Test fun theAddressFieldBecomesTheRealmUrl() {
        assertEquals("http://powstation.pow", PowStation.urlOf("powstation.pow"))
        assertEquals("http://powstation.pow", PowStation.urlOf(" powstation.pow/ "))
        assertEquals("http://192.168.50.100:8080", PowStation.urlOf("192.168.50.100:8080/v1/realm"))
        assertEquals("https://hub.example", PowStation.urlOf("https://hub.example"))
        assertEquals("", PowStation.urlOf(""))
        assertEquals("", PowStation.urlOf("my hub"))
        assertEquals("powstation.pow", PowStation.hostOf("http://powstation.pow"))
    }

    @Test fun keepsTheEnrollmentAndOnlyOwnerKeys() {
        val answer =
            JSONObject(
                """{"device": {"id": "a1", "name": "razr"}, "device_token": "tok", "owner": "Mats", "hub": "Your PowStation",
                   "ai": {"base_url": "http://claude-auth.pow", "token": "powdev-x", "tenant": "default"},
                   "endpoints": {"ai": "http://claude-auth.pow", "owner": {"POWOS_STT_URL": "http://stt.pow",
                     "POWOS_VOICE_URL": "ws://voiceagent.pow/ws", "bad key": "x", "POWOS_BAD": "two\nlines"}},
                   "something": "else"}""",
            )
        val e = PowStation.enrollmentOf("http://powstation.pow", answer)
        assertEquals("tok", e.getString("device_token"))
        assertEquals("default", e.getJSONObject("ai").getString("tenant"))
        assertEquals("Mats", e.getString("owner"))
        assertFalse(e.has("something"))
        val keys = PowStation.ownerBundle(e)
        assertEquals(listOf("POWOS_STT_URL", "POWOS_VOICE_URL"), keys.keys.toList())
        // The launcher reads what this writes, as it reads powos-deviced's.
        val text = PowStation.ownerConfText(keys)
        assertTrue(text.startsWith("#"))
        assertEquals(keys, OwnerConfig.parse(text))
    }

    @Test fun noOwnerBundleIsStandalone() {
        val e = PowStation.enrollmentOf("http://powstation.pow", JSONObject("""{"device_token": "t"}"""))
        assertTrue(PowStation.ownerBundle(e).isEmpty())
        assertTrue(e.isNull("ai"))
    }

    @Test fun approvingFromThePhoneSendsOnlyWhatTheRealmTakes() {
        assertEquals(Triple("GET", "/v1/devices/pending", null), PowStation.realmCall("pending", JSONObject()))
        assertEquals("/v1/devices", PowStation.realmCall("devices", JSONObject()).second)
        val (m, path, body) = PowStation.realmCall("approve", JSONObject("""{"code": " BCDF-GHJK ", "tenant": "default", "token": "x"}"""))
        assertEquals("POST" to "/v1/devices/approve", m to path)
        assertEquals(setOf("code", "decision", "approver", "tenant"), body!!.keys().asSequence().toSet())
        assertEquals(listOf("BCDF-GHJK", "approve", true, "default"), listOf("code", "decision", "approver", "tenant").map { body.get(it) })
        val deny = PowStation.realmCall("approve", JSONObject("""{"code": "MNPQ-RSTV", "decision": "deny"}""")).third!!
        assertEquals("deny", deny.getString("decision"))
        assertFalse(deny.has("tenant"))
        val revoke = PowStation.realmCall("revoke", JSONObject("""{"id": "phone9"}""")).third!!
        assertEquals("phone9" to 1, revoke.getString("id") to revoke.length())
        for ((op, b) in listOf("approve" to """{"code": "X", "decision": "maybe"}""", "approve" to "{}", "revoke" to "{}", "drop" to "{}")) {
            assertTrue("$op $b refused", runCatching { PowStation.realmCall(op, JSONObject(b)) }.isFailure)
        }
    }
}
