package dev.omalauncher.system.gesture

import dev.omalauncher.system.gesture.CornerRoute.Target
import org.junit.Assert.assertEquals
import org.junit.Test

class CornerRouteTest {
    @Test fun overHomeOpensHomesOwnLauncher() {
        // Home shows: its page opens the launcher in place under its own dock, never the overlay (two docks).
        assertEquals(Target.PAGE, CornerRoute.of(appOver = false, homeMain = true, window = true))
        assertEquals(Target.PAGE, CornerRoute.of(appOver = false, homeMain = true, window = false))
    }

    @Test fun overAnAppKeepsTheOverlay() {
        assertEquals(Target.WINDOW, CornerRoute.of(appOver = true, homeMain = false, window = true))
        assertEquals(Target.WINDOW, CornerRoute.of(appOver = true, homeMain = true, window = true))
        assertEquals(Target.NONE, CornerRoute.of(appOver = true, homeMain = false, window = false))
    }

    @Test fun elseHomesPageHasTheTouch() {
        assertEquals(Target.NONE, CornerRoute.of(appOver = false, homeMain = false, window = true))
    }
}
