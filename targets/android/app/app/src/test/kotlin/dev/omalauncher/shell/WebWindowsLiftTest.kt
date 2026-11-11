package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * LH1: a resize drag's top window is lifted over home's buffer (no page hole follows it, ui/webwindows.tsx liftStart).
 * The page says so in the "w.f" entry's <resizing> word; the lifted layer stays under the popups and full screen.
 */
class WebWindowsLiftTest {
    @Test
    fun theResizingWordCarriesTheLift() {
        assertEquals(false to false, WebWindows.resizeWord("0"))
        assertEquals("an older page's resizing never lifts", true to false, WebWindows.resizeWord("1"))
        assertEquals(true to true, WebWindows.resizeWord("2"))
        assertEquals("the drag's end: the app's final size, still lifted until the page's hole is back", false to true, WebWindows.resizeWord("3"))
    }

    @Test
    fun aLiftedWindowIsUnderItsPopups() {
        assertTrue(WebWindows.LIFT_LAYER < WebWindowPopups.LAYER)
        assertTrue("over home's buffer (its bounds layer's children at 0 and up)", WebWindows.LIFT_LAYER > 0)
    }
}
