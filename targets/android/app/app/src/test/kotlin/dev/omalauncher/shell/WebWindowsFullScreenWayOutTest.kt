package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A full-screen Linux web window always leaves the user a way home (10-30 20:20, Dolphin covered the status bar, no
 * bar, dock or chat: "I can't really access ... the main menu is getting overwritten"). Both ways in (KWin's request
 * and PowOS's own, under a KWin without fullscreen-request) end in linuxFullScreen(win, true), so these cover both.
 */
class WebWindowsFullScreenWayOutTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
    private val activity = File("src/main/kotlin/dev/omalauncher/shell/ShellActivity.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n    }\n")

    @Test
    fun edgeStripsAreHomes() {
        val h = 2440
        assertEquals(-1, WebWindows.fullScreenEdge(10f, h, 80, 60))
        assertEquals(1, WebWindows.fullScreenEdge(2400f, h, 80, 60))
        assertEquals(0, WebWindows.fullScreenEdge(1200f, h, 80, 60))
    }

    /** The edge strip is checked BEFORE the full-screen window takes the touch, and it is left to the page. */
    @Test
    fun theFullScreenLayerLeavesTheEdgeStripsToHome() {
        val touch = body("private fun onTouch(ev: MotionEvent): Boolean {")
        val edge = touch.indexOf("fullEdgeAt(ev)")
        assertTrue("onTouch no longer checks the edge strips", edge >= 0)
        assertTrue("the edge strip is checked after the Linux window takes the touch", edge < touch.indexOf("linuxDown(ev)"))
        assertTrue("an edge strip touch no longer goes to the page", Regex("""fullEdge = e\s*return false""").containsMatchIn(touch))
        assertTrue("an edge pull no longer leaves full screen", body("private fun edgePull(").contains("toWindow(e.id)"))
        assertTrue("no bar can be pressed under a full-screen window", body("private fun hit(").contains("it.linuxFull }) return null"))
    }

    @Test
    fun homeAndBackLeaveFullScreen() {
        assertTrue(activity.substringAfter("private fun homePressed() {").substringBefore("\n    }\n").contains("leaveFullScreen(\"home\")"))
        assertTrue(activity.substringAfter("override fun onBackPressed() {").substringBefore("\n    }\n").contains("leaveFullScreen(\"back\")"))
        assertTrue(body("fun leaveFullScreen(why: String): Boolean {").contains("toWindow(w.id)"))
    }

    /** Maximise (the bar's double tap, the page's toggleMaximise) fills the work area, never full screen. */
    @Test
    fun maximiseNeverCallsLinuxFullScreen() {
        val tapped = src.substringAfter("maximise (bar double tap)").substringBefore("\n    }\n")
        assertTrue(tapped.contains("\"action\" to \"maximise\""))
        assertFalse(tapped.contains("linuxFullScreen") || tapped.contains("fullScreen("))
    }
}
