package dev.omalauncher.shell

import dev.omalauncher.widgets.lang.Builtins
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The lock face's glance (LockGlance): the state the page gets, the event it picks, wttr's answer read as the widget does. */
class LockGlanceTest {
    private val now = 1_800_000_000_000L
    private val hour = 3_600_000L

    @Test fun everyPartWhenThere() {
        val s = LockGlance.state(now + 7 * hour, LockGlance.Event("Dentist", now + hour, false), LockGlance.Weather("7°", "", "Oslo", now))
        assertEquals(now + 7 * hour, s.getLong("alarm"))
        assertEquals("Dentist", s.getJSONObject("event").getString("title"))
        assertEquals(now + hour, s.getJSONObject("event").getLong("at"))
        assertEquals("7°", s.getJSONObject("weather").getString("temp"))
        assertEquals("", s.getJSONObject("weather").getString("icon"))
        assertEquals("Oslo", s.getJSONObject("weather").getString("place"))
    }

    @Test fun missingPartsAreNull() {
        val s = LockGlance.state(null, null, null)
        assertTrue(s.isNull("alarm"))
        assertTrue(s.isNull("event"))
        assertTrue(s.isNull("weather"))
        assertEquals(3, s.length())
    }

    @Test fun nextEventIsTheFirstTimedOneWithinTwelveHours() {
        val rows =
            listOf(
                LockGlance.Event("Holiday", now - hour, true),
                LockGlance.Event("Started already", now - 60_000, false),
                LockGlance.Event("Later", now + 3 * hour, false),
                LockGlance.Event("  Standup  ", now + hour, false),
                LockGlance.Event("", now + 30 * 60_000, false),
                LockGlance.Event("Tomorrow evening", now + 13 * hour, false),
            )
        assertEquals(LockGlance.Event("Standup", now + hour, false), LockGlance.nextEvent(rows, now))
        assertNull(LockGlance.nextEvent(listOf(LockGlance.Event("Far", now + 13 * hour, false)), now))
        assertNull(LockGlance.nextEvent(emptyList(), now))
    }

    private fun j1(country: String, code: String, night: Boolean) =
        JSONObject(
            """{"current_condition":[{"temp_C":"7","temp_F":"45","weatherCode":"$code",
               "weatherIconUrl":[{"value":"https://x/wsymbol_0001_${if (night) "night" else "sunny"}.png"}]}],
               "nearest_area":[{"areaName":[{"value":"Oslo"}],"country":[{"value":"$country"}]}]}""",
        )

    @Test fun weatherAsTheTodayWidgetShowsIt() {
        val w = LockGlance.weatherFrom(j1("Norway", "113", false), now)!!
        assertEquals(LockGlance.Weather("7°", Builtins.weatherGlyph(113, false), "Oslo", now), w)
        assertEquals("45°", LockGlance.weatherFrom(j1("United States of America", "113", false), now)!!.temp)
        assertEquals(Builtins.weatherGlyph(113, true), LockGlance.weatherFrom(j1("Norway", "113", true), now)!!.icon)
        assertNull(LockGlance.weatherFrom(JSONObject("{}"), now))
    }

    @Test fun theWidgetsCityOrByIp() {
        assertEquals("", LockGlance.cityQuery(null))
        assertEquals("", LockGlance.cityQuery("""{"v":1,"values":{"city":"  "}}"""))
        assertEquals("New+York%2FNY", LockGlance.cityQuery("""{"v":1,"values":{"city":"New York/NY"}}"""))
        assertEquals("", LockGlance.cityQuery("not json"))
    }
}
