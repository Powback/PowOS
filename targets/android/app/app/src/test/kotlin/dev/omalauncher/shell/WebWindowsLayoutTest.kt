package dev.omalauncher.shell

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * WINDOWS_FIX_PLAN 2.3: the page's opaque layout record per window and per home page ("webwindows.layout",
 * "webwindows.pageLayout") is stored as written, handed back in the host snapshot, kept through other changes, and
 * goes with its window. Writing one is not a state change (no generation).
 */
class WebWindowsLayoutTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n    }\n")

    private fun windows(vararg ids: Int) = JSONArray().also { a -> ids.forEach { a.put(JSONObject().put("id", it).put("key", "a:app$it")) } }

    private fun snap(
        l: WebWindows.LayoutRecords,
        vararg ids: Int,
    ) = WebWindows.withLayouts(WebWindows.snapshotJson(1, windows(*ids), emptyMap()) { _, _ -> false }, l)

    @Test
    fun recordStoredAndReturnedOpaque() {
        val l = WebWindows.LayoutRecords()
        val rec = """{"v":1,"page":2,"frame":{"x":10,"y":20,"w":300,"h":200},"scale":1.5,"tile":{"page":2,"slot":1}}"""
        l.window(3, rec)
        val s = snap(l, 3, 4)
        val w = s.getJSONArray("windows")
        assertEquals("returned exactly as written", rec, w.getJSONObject(0).getString("layout"))
        assertFalse("a window without a record has no layout", w.getJSONObject(1).has("layout"))
    }

    @Test
    fun recordSurvivesOtherUpdatesAndRewrites() {
        val l = WebWindows.LayoutRecords()
        l.window(3, """{"page":1}""")
        l.window(4, """{"page":2}""")
        l.page(2, """{"tiling":{"layout":"2h","ids":[4,null]}}""")
        // Another window's record, a page record, a list without the window this time: 3's is untouched.
        snap(l, 4)
        assertEquals("""{"page":1}""", snap(l, 3, 4).getJSONArray("windows").getJSONObject(0).getString("layout"))
        l.window(3, """{"page":5}""")
        assertEquals("""{"page":5}""", l.window(3))
        assertEquals("""{"tiling":{"layout":"2h","ids":[4,null]}}""", snap(l, 3).getJSONObject("pages").getString("2"))
        l.page(2, null)
        assertFalse("a null page record removes it", snap(l, 3).getJSONObject("pages").has("2"))
    }

    @Test
    fun recordDroppedWithTheWindow() {
        val l = WebWindows.LayoutRecords()
        l.window(3, """{"page":1}""")
        l.drop(3)
        assertNull(l.window(3))
        l.window(4, """{"page":1}""")
        l.window(4, "")
        assertNull("a blank record clears it", l.window(4))
    }

    /** The wiring: drop() forgets the record, writes never bump the generation, the bridge routes both calls. */
    @Test
    fun layoutIsWired() {
        assertTrue("drop no longer forgets the window's layout", body("private fun drop(").contains("layouts.drop(w.id)"))
        assertTrue("snapshot no longer carries the layouts", body("fun snapshot(").contains("withLayouts("))
        assertFalse("a layout write must not move the generation", body("fun layout(").contains("changed()"))
        assertFalse("a page layout write must not move the generation", body("fun pageLayout(").contains("changed()"))
        val bridge = File("src/main/kotlin/dev/omalauncher/shell/ShellBridge.kt").readText()
        assertTrue(bridge.contains("\"webwindows.layout\" -> webWindowsMade && webWindows.layout("))
        assertTrue(bridge.contains("\"webwindows.pageLayout\" -> webWindowsMade && webWindows.pageLayout("))
    }
}
