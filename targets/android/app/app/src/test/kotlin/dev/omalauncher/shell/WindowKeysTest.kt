package dev.omalauncher.shell

import dev.omalauncher.shell.WindowKeys.Key
import dev.omalauncher.shell.WindowKeys.Win
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Back / Forward go to the web window the user is in (its display), home's page only when none is. */
class WindowKeysTest {
    private val chrome = Win(id = 7, displayId = 103, closed = false, shown = true)
    private val discord = Win(id = 8, displayId = 104, closed = false, shown = true)

    @Test
    fun theFocusedWindowGetsBackAndForwardOnItsDisplay() {
        // Chrome pressed last (its bar or a page), then the edge gesture on display 0: Chrome goes back a page.
        assertEquals(chrome, WindowKeys.target(listOf(chrome, discord), focused = 7))
        assertEquals("key 103 4", WindowKeys.line(103, Key.BACK))
        assertEquals("key 103 125", WindowKeys.line(103, Key.FORWARD))
        assertEquals(Key.FORWARD, WindowKeys.of(125))
        assertEquals(Key.BACK, WindowKeys.of(4))
        assertNull(WindowKeys.of(3))
    }

    @Test
    fun noFocusedWindowIsHomesPage() {
        assertNull(WindowKeys.target(emptyList(), focused = -1))
        // Home pressed last (focus -1), or the focused one closed / minimised / with no display yet.
        assertNull(WindowKeys.target(listOf(chrome), focused = -1))
        assertNull(WindowKeys.target(listOf(chrome.copy(closed = true)), focused = 7))
        assertNull(WindowKeys.target(listOf(chrome.copy(shown = false)), focused = 7))
        assertNull(WindowKeys.target(listOf(chrome.copy(displayId = -1)), focused = 7))
    }

    @Test
    fun aQuickPageCardOnScreenTakesItWhateverIsFocused() {
        // Its page goes back one screen; at its root it finishes and the card closes.
        val card = Win(id = 9, displayId = 101, closed = false, shown = true, quick = true)
        assertEquals(card, WindowKeys.target(listOf(chrome, card), focused = 7))
        assertEquals(chrome, WindowKeys.target(listOf(chrome, card.copy(closed = true)), focused = 7))
    }

    @Test
    fun aLinuxWindowStaysHomesUntilKWinHasAKeyPath() {
        assertNull(WindowKeys.target(listOf(Win(id = 5, displayId = -1, closed = false, shown = true, linux = true)), focused = 5))
    }
}
