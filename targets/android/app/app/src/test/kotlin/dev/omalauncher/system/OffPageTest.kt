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

    @Test
    fun aSlideOverAPageWithAnOffPageWindowDestroysNoSurface() {
        // perf-1793735444160: each land WM-hid Plasma (left on the other page), each swipe start showed it in WM to
        // slide it in - the app went invisible/visible, its SurfaceView surfaceDestroyed + surfaceChanged, and the
        // desktop reconnected on the main thread (450-560 ms) once per swipe. A window's surfaces go only when WM
        // makes it invisible: count those over 10 slides (land: it stays on the other page; start: it slides in).
        var wmVisible = true
        var surfaceDestroyed = 0
        repeat(10) {
            val atLand = !OffPage.WM_HIDDEN_AWAY // PageSlide.restore / FreeformTasks.away for a window left away
            if (wmVisible && !atLand) surfaceDestroyed++
            wmVisible = atLand
            wmVisible = true // the next slide's start: TaskLeash.setHidden(false) so it slides in
        }
        assertEquals(0, surfaceDestroyed)
    }

    @Test
    fun anAwayLeashIsTooSmallToTouchOrSee() {
        // Its leash stays a live surface; shrunk, even the widest window is under a pixel (decor re-shows aside).
        assertTrue(9999 * OffPage.AWAY_SCALE < 1f)
        assertTrue(OffPage.AWAY_SCALE > 0f) // invertible: a valid scale, 1 again on show
    }
}
