package dev.omalauncher.system.gesture

import dev.omalauncher.system.gesture.NavGestureClassifier.Outcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** S9: the home gesture shuts PowOS's shade first, as Android's; it never stays open under home. */
class ShadeFirstTest {
    @Test fun homeAndSwitcherShutAnOpenShade() {
        for (down in listOf(true, false)) {
            assertTrue(ShadeFirst.closes(Outcome.Home, downOverShade = down, shownNow = true))
            assertTrue(ShadeFirst.closes(Outcome.Switcher, downOverShade = down, shownNow = true))
        }
    }

    @Test fun alongTheBarOverTheShadeShutsIt() {
        assertTrue(ShadeFirst.closes(Outcome.QuickSwitch(true), downOverShade = true, shownNow = true))
        // Begun with no shade down: the quick switch stays the quick switch.
        assertFalse(ShadeFirst.closes(Outcome.QuickSwitch(false), downOverShade = false, shownNow = true))
    }

    @Test fun aTapOrNoShadeLeavesItAlone() {
        assertFalse(ShadeFirst.closes(Outcome.None, downOverShade = true, shownNow = true))
        assertFalse(ShadeFirst.closes(Outcome.Home, downOverShade = true, shownNow = false))
        assertFalse(ShadeFirst.closes(Outcome.Home, downOverShade = false, shownNow = false))
    }

    @Test fun aCornerSwipeOverTheShadeIsNavigationsNotAPanel() {
        assertEquals(CornerRoute.Target.NONE, CornerRoute.of(appOver = true, homeMain = false, window = true, shadeOpen = true))
        assertEquals(CornerRoute.Target.NONE, CornerRoute.of(appOver = false, homeMain = true, window = false, shadeOpen = true))
    }
}
