package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * N3b (docs/WEB_WINDOWS.md "Native-glued windows", kwin 0063 mode 2 + 0064): a Linux web window's popup is a layer of
 * its own over home at its window's body + (x, y) x the body's scale, cut by the screen only (never the window), placed
 * in the same transaction as its window; its window's popup area goes to KWin only when it changed, throttled.
 */
class WebWindowPopupsTest {
    private val screen = 2268 to 2440

    @Test
    fun aMenuLongerThanItsWindowShowsWholeOnScreen() {
        // Steam's body at 400,300 x1.0; a 312x900 menu at 151,148 of a ~700 px tall window: past its bottom, all shown.
        val p = PopupPlace.of(WebWindowPopups.Origin(400f, 300f, 1f, true), PopupGeo(151, 148, 312, 900), screen)!!
        assertEquals(551f, p.x, 0f)
        assertEquals(448f, p.y, 0f)
        assertEquals(PopupBox(0, 0, 312, 900), p.crop)
        assertEquals(PopupBox(551, 448, 863, 1348), p.screen)
        assertTrue(p.screen.contains(600f, 1300f))
        assertFalse(p.screen.contains(600f, 1350f))
    }

    @Test
    fun theScreenCutsItTheWindowNever() {
        // Scaled 0.5 (a zoomed-out page), near the bottom right: cut at the screen's edges, in the layer's own px.
        val p = PopupPlace.of(WebWindowPopups.Origin(2000f, 2200f, 0.5f, true), PopupGeo(100, 200, 600, 800), screen)!!
        assertEquals(2050f, p.x, 0f)
        assertEquals(2300f, p.y, 0f)
        assertEquals(PopupBox(0, 0, 436, 280), p.crop)
        assertEquals(PopupBox(2050, 2300, 2268, 2440), p.screen)
        // Left of the screen: its left part cut.
        val q = PopupPlace.of(WebWindowPopups.Origin(-100f, 0f, 1f, true), PopupGeo(0, 0, 300, 300), screen)!!
        assertEquals(PopupBox(100, 0, 300, 300), q.crop)
        assertEquals(PopupBox(0, 0, 200, 300), q.screen)
    }

    @Test
    fun aHiddenWindowsPopupsHide() {
        assertNull(PopupPlace.of(WebWindowPopups.Origin(0f, 0f, 1f, false), PopupGeo(0, 0, 10, 10), screen))
        val off = PopupPlace.of(WebWindowPopups.Origin(5000f, 0f, 1f, true), PopupGeo(0, 0, 10, 10), screen)!!
        assertTrue(off.crop.isEmpty())
    }

    @Test
    fun thePopupAreaIsTheScreenInTaskPx() {
        assertEquals(PopupBox(-400, -300, 1868, 2140), PopupPlace.area(WebWindowPopups.Origin(400f, 300f, 1f, true), screen))
        assertEquals(PopupBox(-800, -600, 3736, 4280), PopupPlace.area(WebWindowPopups.Origin(400f, 300f, 0.5f, true), screen))
    }

    @Test
    fun popupAreasGoWhenChangedAtMostEveryGap() {
        val a = PopupAreas(null)
        val sent = ArrayList<PopupBox>()
        val send = { _: Int, b: PopupBox -> sent.add(b); Unit }
        a.offer(7, PopupBox(0, 0, 10, 10), 1_000, send)
        a.offer(7, PopupBox(0, 0, 10, 10), 1_010, send) // unchanged: nothing
        a.offer(7, PopupBox(1, 0, 11, 10), 1_020, send) // a slide's frame: held
        a.offer(7, PopupBox(2, 0, 12, 10), 1_030, send)
        assertEquals(1, sent.size)
        a.flush(7, 1_100, send) // the trailing one: the newest
        assertEquals(listOf(PopupBox(0, 0, 10, 10), PopupBox(2, 0, 12, 10)), sent)
        a.offer(7, PopupBox(3, 0, 13, 10), 1_250, send)
        assertEquals(3, sent.size)
    }

    @Test
    fun popupsRideTheirWindowsTransactionAndTouches() {
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        val place = src.substringAfter("private fun place(").substringBefore("\n    }\n")
        assertTrue("place() moves its popups in the window's own transaction", place.contains("popups.place(t, it.kwin"))
        assertTrue(src.contains("popups.reattach(re)"))
        val touch = src.substringAfter("private fun onTouch(").substringBefore("\n    }\n")
        assertTrue("a DOWN on a popup is its window's before anything else", touch.indexOf("popupGesture(ev)") in 0 until touch.indexOf("fullEdgeAt(ev)"))
        val layers = File("src/main/kotlin/dev/omalauncher/shell/WebWindowPopups.kt").readText()
        assertTrue("over home's buffer and a full-screen window", layers.contains("const val LAYER = (1 shl 20) + 1"))
        assertTrue(src.contains("const val FULL_LAYER = 1 shl 20"))
    }
}
