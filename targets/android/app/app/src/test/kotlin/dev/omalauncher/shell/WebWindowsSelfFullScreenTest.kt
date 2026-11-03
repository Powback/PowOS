package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A Linux window that goes full screen BY ITSELF (KWin's "fullscreen <id> 1", not the bar's button) covers the screen
 * only when it is the user's window. 11-03 e2e round 213 (unfolded): Broforce, a Proton game floating in the
 * background, re-asserted its full screen the moment Kate opened in front - it covered everything, the dock tap that
 * should minimise Kate and the dock tap that should open Calculator both landed on the game.
 */
class WebWindowsSelfFullScreenTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()

    @Test
    fun aBackgroundGameNeverCoversTheWindowJustOpenedInFront() {
        // Broforce 7, Kate 15 just opened (the user's: focused 15).
        assertFalse(WebWindows.selfFullScreenNow(7, focused = 15, open = listOf(7, 11, 12, 15)))
        // The user on home (-1), a newer window open in front of it: still not.
        assertFalse(WebWindows.selfFullScreenNow(7, focused = -1, open = listOf(7, 11, 12, 15)))
        // A new window offered by KWin and not open yet: not either.
        assertFalse(WebWindows.selfFullScreenNow(7, focused = -1, open = listOf(7), coming = true))
        // Minimised (not in the open list): never.
        assertFalse(WebWindows.selfFullScreenNow(7, focused = 7, open = listOf(15)))
    }

    @Test
    fun theUsersOwnWindowStillGoesFullScreenByItself() {
        // The user is in it (pressed it): its F11 / a video's full screen.
        assertTrue(WebWindows.selfFullScreenNow(7, focused = 7, open = listOf(7, 15)))
        // A game just launched: the newest window, home pressed last.
        assertTrue(WebWindows.selfFullScreenNow(16, focused = -1, open = listOf(7, 15, 16)))
        // The window the user was in is gone: the newest open one is theirs.
        assertTrue(WebWindows.selfFullScreenNow(15, focused = 9, open = listOf(7, 15)))
    }

    @Test
    fun aHeldFullScreenWaitsForTheUserAndANewWindowIsTheirs() {
        val report = src.substringAfter("fun linuxFullScreen(\n        kwin: Int,").substringBefore("\n    }\n")
        assertTrue("KWin's own full screen goes through the rule", report.contains("heldFullScreen(w)") && src.contains("if (selfFullScreenNow(w.id, focused, open"))
        assertTrue("held, not applied", src.substringAfter("private fun heldFullScreen(").contains("w.fullHeld = true"))
        val focus = src.substringAfter("fun focus(id: Int): Boolean {").substringBefore("\n    }\n")
        assertTrue("the user coming to it applies it", focus.contains("fullHeld") && focus.contains("linuxFullScreen(w, true)"))
        val open = src.substringAfter("linuxFocused = kwin\n").substringBefore("return id")
        assertTrue("a Linux window opened in front is the user's", open.contains("focused = id"))
    }
}
