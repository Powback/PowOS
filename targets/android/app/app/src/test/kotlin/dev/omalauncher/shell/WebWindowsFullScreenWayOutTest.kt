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

    /**
     * The edge strip is checked BEFORE the full-screen window takes the touch, and it is left to the page; every other
     * touch is the window's (nothing of the page - no bar, no menu - can be pressed under it).
     */
    @Test
    fun theFullScreenLayerLeavesTheEdgeStripsToHome() {
        val touch = body("private fun onTouch(ev: MotionEvent): Boolean {")
        val edge = touch.indexOf("fullEdgeAt(ev)")
        val takes = touch.indexOf("fullLinux()?.let { return linuxInput(it, ev) }")
        assertTrue("onTouch no longer checks the edge strips", edge >= 0)
        assertTrue("the full-screen window no longer takes the other touches", takes >= 0)
        assertTrue("the edge strip is checked after the Linux window takes the touch", edge < takes)
        assertTrue("an edge strip touch no longer goes to the page", Regex("""fullEdge = e\s*return false""").containsMatchIn(touch))
        assertTrue("an edge pull no longer leaves full screen", body("private fun edgePull(").contains("toWindow(e.id)"))
    }

    @Test
    fun homeAndBackLeaveFullScreen() {
        assertTrue(activity.substringAfter("private fun homePressed() {").substringBefore("\n    }\n").contains("leaveFullScreen(\"home\")"))
        assertTrue(activity.substringAfter("override fun onBackPressed() {").substringBefore("\n    }\n").contains("leaveFullScreen(\"back\")"))
        assertTrue(body("fun leaveFullScreen(why: String): Boolean {").contains("toWindow(w.id)"))
    }

    /** Maximise (the page's toggleMaximise; the bar's double tap is full screen since 10-30) fills the work area, never full screen. */
    @Test
    fun maximiseNeverCallsLinuxFullScreen() {
        val page = File("../../../../shell/ui/webwindows.tsx").takeIf { it.exists() } ?: return
        val max = page.readText().substringAfter("export function toggleMaximise(id: number) {").substringBefore("\n}\n")
        assertTrue("toggleMaximise no longer fills the work area", max.contains("workArea()"))
        assertFalse("toggleMaximise goes full screen", max.contains("fullScreen"))
    }
}
