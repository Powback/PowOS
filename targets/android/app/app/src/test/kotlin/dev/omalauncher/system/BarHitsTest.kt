package dev.omalauncher.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The status bar strip's hit routing (the user, "Maximised window's top bar takes taps": the merged bar's buttons,
 * title and drag dead after 2800d804; merged in "App menu (•••) opens in split screen"). Inner screen 1116 px wide,
 * bar 126 px: a maximised window's title [0,400) and controls [900,1116), the clock moved after the title.
 */
class BarHitsTest {
    private val title = BarRect(0, 0, 400, 126)
    private val buttons = BarRect(900, 0, 1116, 126)
    private val clock = BarRect(420, 29, 500, 96)
    private val icons = BarRect(780, 29, 880, 96)

    private fun at(
        x: Int,
        y: Int = 60,
        handles: List<BarRect> = emptyList(),
        windows: List<BarRect> = listOf(title, buttons),
    ) = BarHits.route(x, y, BarClaims(listOf(clock, icons), handles, windows))

    @Test
    fun theMergedBarsTitleAndButtonsAreTheWindows() {
        assertEquals(BarHit.WINDOW, at(200))
        assertEquals(BarHit.WINDOW, at(1000))
        assertEquals(BarHit.WINDOW, at(1115, 125))
        // Taken by the strip and handed to home: a hole there was SystemUI's StatusBar window's.
        assertTrue(BarHits.stripTakes(BarHit.WINDOW, monitored = true))
        assertTrue(BarHits.forwards(BarHit.WINDOW))
    }

    @Test
    fun theStatusBarsOwnControlsStayItsOwn() {
        assertEquals(BarHit.CONTROL, at(450))
        assertEquals(BarHit.CONTROL, at(800))
        assertTrue(BarHits.stripTakes(BarHit.CONTROL, monitored = true))
        assertFalse(BarHits.forwards(BarHit.CONTROL))
    }

    @Test
    fun betweenThemIsTheBarsPull() {
        assertEquals(BarHit.BAR, at(650))
        assertFalse("the monitor pulls the shade there: the strip stays out", BarHits.stripTakes(BarHit.BAR, monitored = true))
        assertTrue("without the monitor the strip takes the pull itself", BarHits.stripTakes(BarHit.BAR, monitored = false))
        assertFalse(BarHits.forwards(BarHit.BAR))
    }

    /** Split screen: each half's "•••" is SystemUI's own window - a hole, never the strip's, even over a window's bar. */
    @Test
    fun splitHandlesAreHoles() {
        val left = BarRect(461, 0, 655, 126)
        assertEquals(BarHit.HANDLE, at(558, handles = listOf(left), windows = emptyList()))
        assertEquals(BarHit.HANDLE, at(558, handles = listOf(left), windows = listOf(BarRect(0, 0, 1116, 126))))
        assertFalse(BarHits.stripTakes(BarHit.HANDLE, monitored = true))
        assertFalse(BarHits.stripTakes(BarHit.HANDLE, monitored = false))
    }

    @Test
    fun edgesAreHalfOpenAsRectsAre() {
        assertEquals(BarHit.WINDOW, at(399))
        assertEquals(BarHit.BAR, at(400)) // the title's right edge is outside it; the clock starts at 420
        assertEquals(BarHit.BAR, at(200, y = 126))
    }

    /** The strip wires the routing in: its region takes the windows' bars, its touches on them go to home's page. */
    @Test
    fun theStripForwardsAndHomeTakes() {
        val shade = File("src/main/kotlin/dev/omalauncher/system/ShadeHost.kt").readText()
        val region = shade.substringAfter("private fun edgeRegion(").substringBefore("\n    }\n")
        assertTrue("the strip's region no longer takes the windows' bars", region.contains("windowClaims()) region.op(r, android.graphics.Region.Op.UNION)"))
        assertTrue("the strip's region no longer leaves the handles holes", region.contains("handles) region.op(r, android.graphics.Region.Op.DIFFERENCE)"))
        val dispatch = shade.substringAfter("override fun dispatchTouchEvent(e: MotionEvent): Boolean {").substringBefore("\n        }\n")
        assertTrue("the strip no longer hands a window's bar gesture to home", dispatch.contains("BarHits.forwards(hitAt(") && dispatch.contains("barSink?.invoke(e)"))
        val windows = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        assertTrue("WebWindows no longer gives the strip its touch sink", windows.contains("windowBars(bars, merge, ::barTouch)"))
        val touch = windows.substringAfter("private fun barTouch(ev: MotionEvent) {").substringBefore("\n    }\n")
        assertTrue("barTouch no longer reaches home's page", touch.contains("web.dispatchTouchEvent(e)"))
    }
    /**
     * The folded cover (1116 px, camera hole centred at 558): the camera app's centred "•••" handle [459,657) sits
     * under the recording ring. rec-light 11-11 tapped the ring at 558,63 and the handle took it ("not pulling:
     * claimed ... Rect(459, 0 - 657, 126)") - the control center never opened. The ring outranks it; the handle keeps
     * its sides.
     */
    @Test
    fun theRecordingRingOutranksACentredHandle() {
        val handle = BarRect(459, 0, 657, 126)
        val ring = BarRect(487, 0, 630, 135)
        val claims = BarClaims(listOf(clock, icons, ring), listOf(handle), emptyList(), listOf(ring))
        assertEquals(BarHit.CONTROL, BarHits.route(558, 63, claims))
        assertTrue(BarHits.stripTakes(BarHits.route(558, 63, claims), monitored = true))
        assertEquals("the handle keeps what the ring doesn't cover", BarHit.HANDLE, BarHits.route(470, 63, claims))
        assertEquals(BarHit.HANDLE, BarHits.route(640, 63, claims))
        val shade = File("src/main/kotlin/dev/omalauncher/system/ShadeHost.kt").readText()
        val region = shade.substringAfter("private fun edgeRegion(").substringBefore("\n    }\n")
        assertTrue(
            "the strip's region no longer gives the ring back after the handles' holes",
            region.indexOf("statusChrome?.lights") > region.indexOf("handles) region.op(r, android.graphics.Region.Op.DIFFERENCE)"),
        )
        val claimed = shade.substringAfter("private fun claimedOnBar(").substringBefore("\n    }\n")
        assertTrue("a ring tap over a handle is judged a claim (no pull, no shade)", claimed.contains("hitAt(x, y) == BarHit.CONTROL"))
        val chrome = File("src/main/kotlin/dev/omalauncher/system/StatusChrome.kt").readText()
        assertTrue("StatusChrome no longer picks the ring's region out", chrome.contains("it.first == \"privacy\""))
    }
}
