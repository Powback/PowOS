package dev.omalauncher.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 11-03 Plasma loop: an off-page window raised on every swipe start, then hidden again; on its page, out of reach. */
class OffPageTest {
    @Test
    fun swipeStartsNeverRaiseAnOffPageWindowAboveHome() {
        // The loop: ~1 swipe start a second (the user trying to reach Plasma), Plasma's task on the page to the left.
        // Before: every start reordered it to the top (TO_FRONT), the land hid it again - 15 raises in 11 s.
        val raises = (1..15).count { OffPage.raiseAtSlideStart(rel = -1, underHome = false) }
        assertEquals(0, raises)
        // The page's own windows are never reordered by a slide either.
        assertFalse(OffPage.raiseAtSlideStart(rel = 0, underHome = true))
    }

    @Test
    fun aWindowThatLeftUnderHomeStillComesUpToSlideIn() {
        assertTrue(OffPage.raiseAtSlideStart(rel = 1, underHome = true))
        assertTrue(OffPage.raiseAtSlideStart(rel = -1, underHome = true))
    }

    @Test
    fun plasmaParkedOffTheGlassIsMovedOntoItsPage() {
        // Rect(2136,331-3496,2039) on the 2268-wide screen: 132 of 1360 px on screen.
        assertTrue(OffPage.mostlyOff(2136, 3496, 0, 2268))
        // A window on screen, or one the user pushed only partly past an edge, stays where it is.
        assertFalse(OffPage.mostlyOff(77, 1437, 0, 2268))
        assertFalse(OffPage.mostlyOff(1500, 2600, 0, 2268))
        assertTrue(OffPage.mostlyOff(-1300, 100, 0, 2268))
        assertFalse(OffPage.mostlyOff(0, 0, 0, 2268))
    }
}
