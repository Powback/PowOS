package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A Linux game that goes full screen goes IMMERSIVE (the coordinator's rule, 11-02): the status bar hides for it, the
 * full-screen area is the whole 2268x2440 screen, and the game keeps the _POWOS_SCREEN_SIZE it launched at (before: a
 * full screen 2268x2314 at 0,126 - the game resized on entering full screen). Back / leaving full screen brings the bar
 * back; so does the game closing while immersive.
 */
class WebWindowsImmersiveTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
    private val bridge = File("src/main/kotlin/dev/omalauncher/shell/ShellBridge.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n    }\n")

    @Test
    fun anImmersiveFullScreenIsTheWholeScreen() {
        assertEquals(0, WebWindows.fullScreenTop(2440, 126, immersive = true))
        assertEquals(126, WebWindows.fullScreenTop(2440, 126, immersive = false))
        assertEquals(126, WebWindows.fullScreenTop(2440, 126))
    }

    @Test
    fun aGamesWindowOpensFullScreenNotFloating() {
        // game-resize.sh 11-07: Besiege / My Friend Pedro opened as 1135x1364 floating windows and Wine pinned that size.
        assertTrue(WebWindows.opensFullScreen(WebWindows.isGame("steam_app_346010", null)))
        assertFalse(WebWindows.opensFullScreen(WebWindows.isGame("org.kde.kate", "Qt;KDE;Utility;TextEditor;")))
        assertFalse("Steam itself floats", WebWindows.opensFullScreen(WebWindows.isGame("steam", "Game;")))
        assertTrue("openLinux asks it", body("    fun openLinux(").contains("gameFullScreenAtOpen(win, p)"))
        val at = body("    private fun gameFullScreenAtOpen(")
        assertTrue("a game's offer -> KWin's full screen", at.contains("opensFullScreen(p.game)") && at.contains("fullScreen(win)"))
        assertTrue("never over a window already full screen or asked", at.contains("win.linuxFull || win.fullAsked"))
    }

    @Test
    fun gamesAreProtonClassesOrGameDesktopFilesNotSteam() {
        assertTrue(WebWindows.isGame("steam_app_274190", null))
        assertTrue(WebWindows.isGame("STEAM_APP_1", null))
        assertTrue(WebWindows.isGame("supertuxkart", "Game;ArcadeGame;"))
        assertFalse("Steam is a launcher, its windows keep the bar", WebWindows.isGame("steam", "Network;FileTransfer;Game;"))
        assertFalse(WebWindows.isGame("com.valvesoftware.Steam", "Game;"))
        assertFalse(WebWindows.isGame("org.kde.dolphin", "Qt;KDE;System;FileTools;FileManager;"))
        assertFalse(WebWindows.isGame("org.kde.dolphin", null))
        assertFalse("a category that only contains the word", WebWindows.isGame("x", "GameTools;"))
    }

    @Test
    fun theOfferCarriesWhetherItIsAGame() {
        assertTrue(bridge.contains("WebWindows.LinuxOffer(appId, title, label, icon, WebWindows.isGame(appId, app?.categories), alts)"))
    }

    /** On: immersive from the offer, the bar hidden BEFORE the area is measured; off: the bar back. */
    @Test
    fun fullScreenHidesTheBarAndLeavingBringsItBack() {
        val full = body("private fun linuxFullScreen(\n        win: Win,")
        val set = full.indexOf("immersive(win, src, on)")
        assertTrue("the bar isn't set before fillScreen", set in 0 until full.indexOf("fillScreen(t, win, src)"))
        val imm = body("private fun immersive(")
        assertTrue("immersive isn't taken from the offer", imm.contains("if (on) win.immersive = src.offer.game"))
        assertTrue("the bar isn't hidden on / back off", imm.contains("statusBar(win, !on)") && imm.contains("if (!win.immersive) return"))
        assertTrue("fillScreen doesn't use the immersive area", body("private fun fillScreen(").contains("fullScreenArea(win.immersive)"))
        assertTrue("touches aren't mapped to the immersive area", body("private fun linuxInput(").contains("fullScreenArea(win.immersive)"))
        assertTrue("KWin's answer doesn't size to the immersive area", body("private fun fullScreenConfirmed(").contains("fullScreenArea(win.immersive)"))
        val bar = body("private fun statusBar(")
        assertTrue(bar.contains("BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE") && bar.contains("hide(android.view.WindowInsets.Type.statusBars())"))
        assertTrue(bar.contains("show(android.view.WindowInsets.Type.statusBars())"))
    }

    @Test
    fun aGameClosedWhileImmersiveBringsTheBarBack() {
        val drop = body("private fun dropLinux(")
        assertTrue(drop.contains("if (w.immersive) {") && drop.contains("statusBar(w, true)"))
    }
}
