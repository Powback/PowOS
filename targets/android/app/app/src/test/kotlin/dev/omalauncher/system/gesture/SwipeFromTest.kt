package dev.omalauncher.system.gesture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** SF1: a tap on home's search bar (in the gesture strip) with a web window open never begins the switcher over it. */
class SwipeFromTest {
    @Test fun homeSearchTapWithWebWindowOpenIsHomes() {
        // e2e-appapi round 241: task 2569 = WireGuard's web window, visible on its display under home's page.
        assertNull(SwipeFrom.decide(switcherUpOverHome = false, homeShown = true, visible = 2569) { true })
    }

    @Test fun homeWithNothingOpenIsHomes() = assertNull(SwipeFrom.decide(false, true, null) { false })

    @Test fun switcherUpOverHomeIsHomes() = assertNull(SwipeFrom.decide(true, true, 7) { true })

    @Test fun realAppIsTheApps() {
        // Over a real app (home not shown): its window follows the finger, as before.
        assertEquals(42, SwipeFrom.decide(switcherUpOverHome = false, homeShown = false, visible = 42) { false })
        // A floating (freeform) app on display 0 over home's started page: unchanged, its window follows the finger.
        assertEquals(42, SwipeFrom.decide(switcherUpOverHome = false, homeShown = true, visible = 42) { false })
    }
}
