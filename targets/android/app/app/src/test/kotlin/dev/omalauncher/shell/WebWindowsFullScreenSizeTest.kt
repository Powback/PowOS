package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * FL5 / FL3 (the user, 10-30 22:19: "I try to full screen dolphin and this is how it looks" - Dolphin pillarboxed at
 * ~1116 px, its toolbar through the status bar; 22:20: "I can't open the switcher now either").
 */
class WebWindowsFullScreenSizeTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
    private val switcher = File("src/main/kotlin/dev/omalauncher/system/Switcher.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n    }\n")

    /** The app's area is the whole screen below the status bar: full width, never under the bar. */
    @Test
    fun fullScreenIsTheScreenBelowTheStatusBar() {
        assertEquals(126, WebWindows.fullScreenTop(2440, 126))
        assertEquals(0, WebWindows.fullScreenTop(2440, 0))
        assertEquals(610, WebWindows.fullScreenTop(2440, 5000))
        assertTrue("the area is not the full width from the bar down", src.contains("Rect(0, fullScreenTop(b.height(), maxOf(bar, cut)), b.width(), b.height())"))
    }

    /**
     * KWin's own full screen takes its OUTPUT's size (the desktop consumer's: the folded cover's 1116x2358 while
     * unfolded) and kwin 0040 keeps it while the task's size equals the one from before; the size must go to KWin after
     * its "fullscreen <id> 1" answer, not with the request.
     */
    @Test
    fun theSizeGoesAfterKWinsAnswer() {
        val ask = src.substringAfter("full screen asked\")").substringBefore("return\n")
        assertTrue("PowOS's request no longer waits for KWin's answer", ask.indexOf("win.fullAsked = true") in 0 until ask.indexOf("WebWindowSource.fullScreen(src.kwin, true)"))
        val fill = body("private fun fillScreen(")
        val asked = fill.indexOf("if (win.fullAsked) {")
        assertTrue("fillScreen sizes KWin's window before its answer", asked >= 0 && fill.indexOf("linuxResize(") > asked && fill.substring(asked).contains("} else {"))
        assertTrue("KWin's answer no longer sizes the window", src.contains("if (on && w.linuxFull) fullScreenConfirmed(w, \"KWin's answer\")"))
        assertTrue(body("private fun fullScreenConfirmed(").contains("linuxResize(win, src, area.width(), area.height())"))
    }

    /** The switcher hides a full-screen window too (it hangs on home's surface, not under the root). */
    @Test
    fun theSwitcherHidesAFullScreenWindow() {
        val shown = body("private fun rootShown(on: Boolean) {")
        assertTrue("rootShown hides only the root", shown.contains("if (!w.underRoot && w.container.isValid) t.setVisibility(w.container, on && w.shown)"))
    }

    /** Home from the switcher leaves full screen, as Home does. */
    @Test
    fun switcherHomeLeavesFullScreen() {
        assertTrue(switcher.substringAfter("fun end(to: String) {").substringBefore("\n    }\n").contains("WebWindows.switcherHome("))
        assertTrue(switcher.substringAfter("fun close() {").substringBefore("\n    }\n").contains("WebWindows.switcherHome("))
        assertTrue(switcher.substringAfter("fun closed(").substringBefore("\n    }\n").contains("WebWindows.switcherHome("))
    }
}
