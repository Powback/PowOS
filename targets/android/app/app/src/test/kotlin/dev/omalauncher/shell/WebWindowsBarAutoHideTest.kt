package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * TB1/TB2 (the owner, 11-14: "the titlebar isnt acting like the native one, with autohide on fullscreen apps etc, slide
 * to reveal"; docs/WEB_WINDOWS.md "Title bar: native parity"): the host's side of the title bar's auto-hide - an
 * Android app's immersive request read as AOSP's TaskInfo.requestingImmersive, home's status bar hidden for an
 * auto-hidden bar, and a full-screen Linux window's top pull revealing its bar (cropped layer, the page's touches)
 * instead of leaving full screen.
 */
class WebWindowsBarAutoHideTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n    }\n")

    /** AOSP windowdecor/extension/TaskInfo.kt: requesting immersive = the status bars type not requested visible. */
    @Test
    fun immersiveIsTheStatusBarAskedHidden() {
        val statusBars = 1
        val navigationBars = 2
        val defaultVisible = 0x1ff and (1 shl 3).inv() // every type but the IME
        assertFalse(WebWindows.requestingImmersive(defaultVisible))
        assertTrue(WebWindows.requestingImmersive(defaultVisible and statusBars.inv()))
        assertTrue(WebWindows.requestingImmersive(defaultVisible and (statusBars or navigationBars).inv()))
        // Only the navigation bar hidden (a lean-back app): not immersive, the header stays (AOSP the same).
        assertFalse(WebWindows.requestingImmersive(defaultVisible and navigationBars.inv()))
        assertFalse("an unreadable request reads as immersive", WebWindows.requestingImmersive(-1))
    }

    /** Only a maximised Android window on home with a task is watched (the poll is nothing otherwise). */
    @Test
    fun onlyMaximisedAndroidWindowsOnHomeAreWatched() {
        assertTrue(WebWindows.immersiveWatched(android = true, onHome = true, taskId = 7, maximised = true))
        assertFalse(WebWindows.immersiveWatched(android = true, onHome = true, taskId = 7, maximised = false))
        assertFalse(WebWindows.immersiveWatched(android = false, onHome = true, taskId = 7, maximised = true))
        assertFalse(WebWindows.immersiveWatched(android = true, onHome = false, taskId = 7, maximised = true))
        assertFalse(WebWindows.immersiveWatched(android = true, onHome = true, taskId = -1, maximised = true))
    }

    @Test
    fun statusBarHiddenOnlyForAnAutoHiddenBarOnScreen() {
        assertFalse(WebWindows.barsHiddenFor(emptyList()))
        assertFalse(WebWindows.barsHiddenFor(listOf(false, false)))
        assertTrue(WebWindows.barsHiddenFor(listOf(false, true)))
    }

    /** The page's maximised word 2 is parsed as maximised AND bar hidden; the frame's apply re-checks the status bar. */
    @Test
    fun theMaximisedWordCarriesTheAutoHiddenBar() {
        assertTrue(src.contains("maximised = m == \"1\" || m == \"2\"; barHidden = m == \"2\""))
        val apply = body("    private fun apply(\n")
        assertTrue("apply no longer re-checks the status bar for an auto-hidden bar", apply.contains("immersiveBars()"))
        assertTrue("apply no longer keeps the immersive poll going", apply.contains("immersiveSoon()"))
        assertTrue("a game's status bar comes back over an auto-hidden bar", body("    private fun statusBar(\n").contains("if (shown && barsHiddenForWindow) return"))
    }

    /** TB2: the top pull reveals, the bottom pull still leaves full screen (FL3: a way home kept). */
    @Test
    fun aTopPullRevealsTheBottomPullLeaves() {
        assertTrue(WebWindows.edgePullReveals(-1))
        assertFalse(WebWindows.edgePullReveals(1))
        val pull = body("    private fun edgePull(\n")
        assertTrue(pull.contains("revealFull(e.id, \"top edge pull\")"))
        assertTrue(pull.contains("toWindow(e.id)"))
    }

    /** TB2: the revealed bar's strip is cropped off the full-screen layer (non-immersive: the bar's height only). */
    @Test
    fun theRevealedBarCropsTheLayerNotTheApp() {
        assertEquals(126, WebWindows.revealCrop(barBottom = 126, areaTop = 0))
        assertEquals(84, WebWindows.revealCrop(barBottom = 210, areaTop = 126))
        assertEquals(0, WebWindows.revealCrop(barBottom = 100, areaTop = 126))
        val layer = body("    private fun fullLayer(\n")
        assertTrue(layer.contains("revealCrop(revealBottom(), area.top)"))
        assertTrue(layer.contains("Rect(0, top, area.width(), area.height())"))
    }

    /** TB2: the revealed bar's touches are the page's - checked before the full-screen window takes every touch. */
    @Test
    fun theRevealedBarsTouchesAreThePages() {
        val touch = body("    private fun onTouch(ev: MotionEvent): Boolean {\n")
        val reveal = touch.indexOf("if (edgeOrReveal(ev)) return false")
        val takes = touch.indexOf("fullLinux()?.let { return linuxInput(it, ev) }")
        assertTrue("onTouch no longer passes the revealed bar's touches to the page", reveal >= 0)
        assertTrue("the revealed bar's check comes after the full-screen window took the touch", reveal < takes)
        assertTrue(body("    private fun edgeOrReveal(ev: MotionEvent): Boolean {\n").contains("return revealTouch(ev)"))
        // The page runs while a bar is revealed (GQ1 would pause it under a game).
        assertTrue(src.contains("edge: Boolean = fullEdge != null || revealedFull >= 0,"))
    }
}
