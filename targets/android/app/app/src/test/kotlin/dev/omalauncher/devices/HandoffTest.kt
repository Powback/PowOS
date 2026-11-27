package dev.omalauncher.devices

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class HandoffTest {
    private val none: (String) -> Pair<String, String>? = { null }

    @Test
    fun webAppGoesAsItsPageNow() {
        val p = Handoff.payload(JSONObject().put("app", "w:notes.pow").put("title", "")) { host -> "https://$host/n/42" to "Shopping list" }!!
        assertEquals("https://notes.pow/n/42", p.getString("url"))
        assertEquals("Shopping list", p.getString("title"))
        assertFalse(p.has("app"))
    }

    @Test
    fun androidAppGoesAsItsPackageOnly() {
        val p = Handoff.payload(JSONObject().put("app", "a:com.spotify.music/.MainActivity@10").put("title", "Spotify"), none)!!
        assertEquals("a:com.spotify.music", p.getString("app"))
    }

    @Test
    fun powosAppKeepsItsRoute() {
        val route = JSONObject().put("note", "42")
        val p = Handoff.payload(JSONObject().put("app", "p:notes").put("title", "Notes").put("route", route), none)!!
        assertEquals("p:notes", p.getString("app"))
        assertEquals("42", p.getJSONObject("route").getString("note"))
        // a route only means something to a PowOS app
        assertFalse(Handoff.payload(JSONObject().put("app", "l:dolphin").put("route", route), none)!!.has("route"))
    }

    @Test
    fun nothingToHandOff() {
        assertNull(Handoff.payload(JSONObject().put("app", "w:gone.pow"), none)) // a web app with no page
        assertNull(Handoff.payload(JSONObject().put("url", "file:///etc/passwd"), none))
        assertNull(Handoff.payload(JSONObject().put("app", "x:what"), none))
        assertNull(Handoff.parse("not json".toByteArray()))
        assertNotNull(Handoff.parse("""{"v":1,"url":"https://a.pow/"}""".toByteArray()))
    }
}
