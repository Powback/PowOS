package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The web window title bar's middle button is full screen (a real full-screen app), never the work area's maximise. */
class WebWindowsBarTest {
    @Test
    fun theMiddleButtonIsFullScreen() {
        assertEquals(WebWindows.BarAction.FULL_SCREEN, WebWindows.buttonAction("maximise"))
    }

    @Test
    fun theOtherButtonsKeepTheirActions() {
        assertEquals(WebWindows.BarAction.CLOSE, WebWindows.buttonAction("close"))
        assertEquals(WebWindows.BarAction.MINIMISE, WebWindows.buttonAction("minimise"))
        assertEquals(WebWindows.BarAction.TILE_MENU, WebWindows.buttonAction("tile"))
    }

    /** control() must dispatch through buttonAction and send FULL_SCREEN to fullScreen(win), not to a maximise emit. */
    @Test
    fun controlCallsFullScreen() {
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        val body = src.substringAfter("private fun control(").substringBefore("\n    }\n")
        assertTrue("control() no longer dispatches through buttonAction", body.contains("when (buttonAction(control))"))
        assertTrue("the full screen button no longer calls fullScreen(win)", Regex("""BarAction\.FULL_SCREEN\s*->\s*fullScreen\(win\)""").containsMatchIn(body))
        // The Android path of fullScreen: its task moved to display 0.
        val full = src.substringAfter("private fun fullScreenNow(").substringBefore("\n    }\n")
        assertTrue("fullScreen no longer moves the task to display 0", full.contains("moveTask(task, android.view.Display.DEFAULT_DISPLAY)"))
    }
}
