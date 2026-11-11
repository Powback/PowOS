package dev.omalauncher.shell

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * WINDOWS_FIX_PLAN 2.2: the host snapshot ("webwindows.list" true; docs/WEB_WINDOWS.md "The host snapshot") carries
 * everything the page needs to rebuild after a reload: the windows, the KWin offers not opened yet, each Linux window's
 * failure, and the generation it was read at.
 */
class WebWindowsSnapshotTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n    }\n")

    @Test
    fun snapshotCarriesGenerationWindowsAndPendingOffers() {
        val windows = JSONArray().put(JSONObject().put("id", 3).put("key", "a:chrome"))
        val dolphin = WebWindows.LinuxOffer("org.kde.dolphin", "Home — Dolphin", "Dolphin", null, alts = listOf("l:org.kde.dolphin-2"))
        dolphin.key = "l:org.kde.dolphin"
        val game = WebWindows.LinuxOffer("steam_app_1", "Game", "Game", null, game = true)
        game.key = "l:steam_app_1"
        val s = WebWindows.snapshotJson(7, windows, linkedMapOf(12 to dolphin, 13 to game)) { _, g -> !g }
        assertEquals(7L, s.getLong("generation"))
        assertEquals(3, s.getJSONArray("windows").getJSONObject(0).getInt("id"))
        val p = s.getJSONArray("pendingLinux")
        assertEquals(2, p.length())
        val d = p.getJSONObject(0)
        assertEquals(12, d.getInt("kwin"))
        assertEquals("l:org.kde.dolphin", d.getString("key"))
        assertEquals("Dolphin", d.getString("label"))
        assertTrue(d.getBoolean("ownFrame"))
        assertEquals("l:org.kde.dolphin-2", d.getJSONArray("alts").getString(0))
        assertFalse("a game's offer: ownFrame from its game flag", p.getJSONObject(1).getBoolean("ownFrame"))
        assertEquals(0, p.getJSONObject(1).getJSONArray("alts").length())
    }

    @Test
    fun realTimeEventsNeverMoveTheGeneration() {
        assertFalse(WebWindows.bumps("webwindows.moveresize"))
        assertFalse(WebWindows.bumps("webwindows.resend"))
        assertFalse("not a web-window event", WebWindows.bumps("recents.drag"))
        listOf("adopt", "alive", "closed", "failed", "frame", "full", "live", "pip", "show", "state", "control").forEach {
            assertTrue("webwindows.$it is state", WebWindows.bumps("webwindows.$it"))
        }
    }

    /** The wiring: every emit goes through the generation, opens and drops and offers move it, failures are listed. */
    @Test
    fun generationAndFailedAreWired() {
        assertTrue("emit no longer bumps", src.contains("if (bumps(event)) changed()\n        sink(event, data)"))
        assertTrue("drop no longer bumps", body("private fun drop(").contains("if (wins.remove(w.id) == null) return\n        changed()"))
        assertEquals("both opens (Android, Linux) bump", 2, Regex("wins\\[id\\] = win\\n\\s+changed\\(\\)").findAll(src).count())
        assertTrue("an offer no longer bumps", src.contains("pendingLinux[kwin] = offer\n        changed()"))
        assertTrue("linuxFailed no longer records the reason", body("private fun linuxFailed(").contains("win.linux?.failed = LINUX_NOT_RESPONDING"))
        assertTrue("listed no longer carries failed", body("private fun listed(").contains("o.put(\"failed\", it)"))
        assertTrue("snapshot no longer reads pendingLinux", body("fun snapshot(").contains("pendingLinux"))
        val bridge = File("src/main/kotlin/dev/omalauncher/shell/ShellBridge.kt").readText()
        val list = bridge.substringAfter("\"webwindows.list\" -> {").substringBefore("\n            }\n")
        assertTrue("list(true) no longer answers the snapshot", list.contains("whole -> webWindows.snapshot(appOf)"))
        assertTrue("the bare list must stay the array (the page reads it until 2.4)", list.contains("else -> webWindows.list(appOf)"))
    }
}
