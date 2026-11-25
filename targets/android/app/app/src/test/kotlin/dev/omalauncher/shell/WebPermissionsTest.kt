package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.text.SimpleDateFormat
import java.util.TimeZone

/** A `.pow` web app's permissions (the user 11-25): what a site's ask maps to, who may be granted, the asking plan. */
class WebPermissionsTest {
    private val mic = "android.permission.RECORD_AUDIO"
    private val cam = "android.permission.CAMERA"
    private val fine = "android.permission.ACCESS_FINE_LOCATION"
    private val coarse = "android.permission.ACCESS_COARSE_LOCATION"

    @Test
    fun resourcesMapToKindsAndAndroidPermissions() {
        assertEquals(WebPermissions.MIC, WebPermissions.kindOf(WebPermissions.RES_AUDIO))
        assertEquals(WebPermissions.CAMERA, WebPermissions.kindOf(WebPermissions.RES_VIDEO))
        assertEquals(WebPermissions.MIDI, WebPermissions.kindOf(WebPermissions.RES_MIDI))
        assertNull("DRM ids are never granted", WebPermissions.kindOf(WebPermissions.RES_PROTECTED_MEDIA))
        assertNull(WebPermissions.kindOf("android.webkit.resource.SOMETHING_NEW"))
        assertEquals(listOf(mic), WebPermissions.androidPermissions(WebPermissions.MIC))
        assertEquals(listOf(cam), WebPermissions.androidPermissions(WebPermissions.CAMERA))
        assertEquals(listOf(fine, coarse), WebPermissions.androidPermissions(WebPermissions.LOCATION))
        assertEquals(emptyList<String>(), WebPermissions.androidPermissions(WebPermissions.MIDI))
        for (k in listOf(WebPermissions.MIC, WebPermissions.CAMERA, WebPermissions.MIDI)) assertEquals(k, WebPermissions.kindOf(WebPermissions.resourceOf(k)!!))
        assertNull(WebPermissions.resourceOf(WebPermissions.LOCATION))
    }

    @Test
    fun onlyTheAppsOwnPowHostIsASite() {
        assertEquals("voiceagent.pow", WebPermissions.siteOf("http://voiceagent.pow", "voiceagent.pow"))
        assertEquals("voiceagent.pow", WebPermissions.siteOf("https://voiceagent.pow/", "voiceagent.pow"))
        assertEquals("voiceagent.pow", WebPermissions.siteOf("http://voiceagent.pow:8080/", "voiceagent.pow"))
        assertEquals("a subdomain grants under its app", "mao.pow", WebPermissions.siteOf("https://media.mao.pow/", "mao.pow"))
        assertNull("another .pow app's frame", WebPermissions.siteOf("http://powscan.pow/", "voiceagent.pow"))
        assertNull("a lookalike", WebPermissions.siteOf("http://evilvoiceagent.pow/", "voiceagent.pow"))
        assertNull("not .pow", WebPermissions.siteOf("https://voiceagent.powback.com/", "voiceagent.pow"))
        assertNull("not .pow", WebPermissions.siteOf("https://example.com/", "example.com"))
        assertNull(WebPermissions.siteOf("http://192.168.50.100/", "voiceagent.pow"))
        assertNull(WebPermissions.siteOf("file:///sdcard/x.html", "voiceagent.pow"))
        assertNull(WebPermissions.siteOf(null, "voiceagent.pow"))
    }

    @Test
    fun aNewKindIsAskedFirstThenAndroidsForWhatPowosLacks() {
        val none = { _: String -> false }
        var p = WebPermissions.plan(listOf(WebPermissions.MIC), emptySet(), none)
        assertEquals(listOf(WebPermissions.MIC), p.ask)
        assertEquals(emptyList<String>(), p.request)
        // Allowed for the site, PowOS lacks RECORD_AUDIO: Android's dialog for it.
        p = WebPermissions.plan(listOf(WebPermissions.MIC), setOf(WebPermissions.MIC), none)
        assertEquals(emptyList<String>(), p.ask)
        assertEquals(listOf(mic), p.request)
        assertEquals(emptyList<String>(), p.ready)
        // Allowed and held: granted at once, no dialog.
        p = WebPermissions.plan(listOf(WebPermissions.MIC, WebPermissions.CAMERA), setOf(WebPermissions.MIC, WebPermissions.CAMERA)) { it == mic || it == cam }
        assertEquals(emptyList<String>(), p.ask)
        assertEquals(emptyList<String>(), p.request)
        assertEquals(listOf(WebPermissions.MIC, WebPermissions.CAMERA), p.ready)
        // Location: coarse alone is enough; asking requests both.
        assertTrue(WebPermissions.holds(WebPermissions.LOCATION) { it == coarse })
        assertEquals(listOf(fine, coarse), WebPermissions.plan(listOf(WebPermissions.LOCATION), setOf(WebPermissions.LOCATION), none).request)
        // MIDI needs nothing from Android.
        assertEquals(listOf(WebPermissions.MIDI), WebPermissions.plan(listOf(WebPermissions.MIDI), setOf(WebPermissions.MIDI), none).ready)
    }

    @Test
    fun grantedIsOnlyWhatTheSiteIsAllowedAndPowosHolds() {
        val held = { p: String -> p == mic }
        assertEquals(listOf(WebPermissions.MIC), WebPermissions.granted(listOf(WebPermissions.MIC, WebPermissions.CAMERA), setOf(WebPermissions.MIC, WebPermissions.CAMERA), held))
        assertEquals("not allowed for the site: never, even if PowOS holds it", emptyList<String>(), WebPermissions.granted(listOf(WebPermissions.MIC), emptySet(), held))
    }

    @Test
    fun theStoreRoundTripsAndDropsJunk() {
        val m = mapOf("voiceagent.pow" to setOf(WebPermissions.CAMERA, WebPermissions.MIC), "powmap.pow" to setOf(WebPermissions.LOCATION))
        assertEquals(m, WebPermissions.parse(WebPermissions.format(m)))
        assertTrue("kinds in their order", WebPermissions.format(m).contains(""""voiceagent.pow":["microphone","camera"]"""))
        val junk = """{"example.com":["microphone"],"a.pow":["microphone","root"],"b.pow":"x","c.pow":[]}"""
        assertEquals(mapOf("a.pow" to setOf(WebPermissions.MIC)), WebPermissions.parse(junk))
        assertEquals(emptyMap<String, Set<String>>(), WebPermissions.parse("not json"))
        assertEquals(emptyMap<String, Set<String>>(), WebPermissions.parse(null))
    }

    @Test
    fun words() {
        assertEquals("microphone", WebPermissions.words(listOf("microphone")))
        assertEquals("microphone and camera", WebPermissions.words(listOf("microphone", "camera")))
        assertEquals("microphone, camera and location", WebPermissions.words(listOf("microphone", "camera", "location")))
    }

    // ---- PowCa: the PowStation CA trusted only for .pow server certs it signed ----

    private val ca = PowCa.parse(File("src/main/res/raw/pow_ca.pem").inputStream())
    private val leaf = PowCa.parse(javaClass.classLoader!!.getResourceAsStream("powmap.pow.crt")!!)
    private val inside = SimpleDateFormat("yyyy-MM-dd").apply { timeZone = TimeZone.getTimeZone("UTC") }.parse("2027-01-01")!!

    @Test
    fun thePowStationCaVouchesForItsOwnPowHostOnly() {
        assertTrue(PowCa.trusts(ca, "powmap.pow", leaf, inside))
        assertFalse("another host", PowCa.trusts(ca, "voiceagent.pow", leaf, inside))
        assertFalse("not .pow", PowCa.trusts(ca, "powmap.powback.com", leaf, inside))
        assertFalse("expired", PowCa.trusts(ca, "powmap.pow", leaf, SimpleDateFormat("yyyy-MM-dd").parse("2030-01-01")!!))
        assertFalse("the CA itself is no server cert", PowCa.trusts(ca, "powmap.pow", ca, inside))
        assertFalse("no cert", PowCa.trusts(ca, "powmap.pow", null, inside))
        // A cert the CA didn't sign (the CA as its own 'issuer' check against the leaf's key).
        assertFalse("not signed by the CA", PowCa.trusts(leaf, "powmap.pow", leaf, inside))
    }

    @Test
    fun httpsOnlyForPowAndAnswersThatMeanServed() {
        assertEquals("https://voiceagent.pow/?a=1", PowCa.httpsOf("http://voiceagent.pow/?a=1"))
        assertNull(PowCa.httpsOf("https://voiceagent.pow/"))
        assertNull(PowCa.httpsOf("http://example.com/"))
        assertTrue(PowCa.serves(200))
        assertTrue(PowCa.serves(302))
        assertTrue(PowCa.serves(401))
        assertFalse("Traefik's 404: a cert but no websecure router", PowCa.serves(404))
        assertFalse(PowCa.serves(502))
    }
}
