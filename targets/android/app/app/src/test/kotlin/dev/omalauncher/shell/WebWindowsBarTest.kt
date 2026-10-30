package dev.omalauncher.shell

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The web window title bar's full screen button is a real full-screen app (its task on display 0), never the work
 * area's maximise (that is the bar's double tap). Regressed 3 times. The bar is DOM now (docs/WEB_WINDOWS.md "Element
 * model"): the page's button -> "webwindows.fullScreen" -> [WebWindows.fullScreen] -> moveTask to display 0.
 */
class WebWindowsBarTest {
    @Test
    fun theHostMakesAFullScreenApp() {
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        val entry = src.substringAfter("fun fullScreen(id: Int): Boolean {").substringBefore("\n    }\n")
        assertTrue("webwindows.fullScreen no longer reaches fullScreen(w)", entry.contains("fullScreen(w)"))
        val full = src.substringAfter("private fun fullScreenNow(").substringBefore("\n    }\n")
        assertTrue("fullScreen no longer moves the task to display 0", full.contains("moveTask(task, android.view.Display.DEFAULT_DISPLAY)"))
    }

    /**
     * A Linux window under a KWin without "fullscreen-request" still goes full screen (10-30 20:17: Dolphin's button
     * logged "KWin takes no full-screen request: the work area's maximise" - the user's "still maximising").
     */
    @Test
    fun fullScreenNeverFallsBackToMaximise() {
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        val body = src.substringAfter("private fun fullScreen(win: Win) {").substringBefore("\n    }\n")
        assertTrue("fullScreen(win) sends the work area's maximise", !body.contains("\"maximise\""))
        val oldKwin = body.substringAfter("canFullScreen()) {").substringBefore("return")
        assertTrue("the old-KWin path no longer goes full screen", oldKwin.contains("linuxFullScreen(win, true)"))
    }

    /** The page's bar: its "Full screen" button calls fullScreen, which asks the host (not toggleMaximise) when it can. */
    @Test
    fun thePageButtonAsksTheHost() {
        val page = File("../../../shell/ui/webwindows.tsx").takeIf { it.exists() } ?: return
        val src = page.readText()
        assertTrue("the bar's Full screen button no longer calls fullScreen(win.id)", Regex("""aria-label="Full screen" \{\.\.\.press\(\(\) => fullScreen\(win\.id\)\)\}""").containsMatchIn(src))
        val fn = src.substringAfter("function fullScreen(id: number) {").substringBefore("\n}\n")
        assertTrue("fullScreen() no longer asks the host for a full-screen app", fn.contains("powos.webwindows.fullScreen(id)"))
    }
}
