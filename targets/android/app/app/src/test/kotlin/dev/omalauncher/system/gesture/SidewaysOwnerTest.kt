package dev.omalauncher.system.gesture

import dev.omalauncher.system.gesture.SidewaysOwner.Owner
import org.junit.Assert.assertEquals
import org.junit.Test

/** QS1: over home, the quick switch is only the bottom gesture strip; above it a sideways swipe pages home. */
class SidewaysOwnerTest {
    // The unfolded phone of the report: 2440 px tall, ~2.625 px/dp, a 24 dp strip.
    private val density = 2.625f
    private val bottom = 2440f
    private val strip = 24 * density

    private fun owner(
        homeShown: Boolean,
        fullScreenApp: Boolean,
        dpUp: Float,
    ) = SidewaysOwner.decide(homeShown, fullScreenApp, bottom - dpUp * density, bottom, strip)

    @Test fun homeInStripIsQuickSwitch() = assertEquals(Owner.QUICK_SWITCH, owner(homeShown = true, fullScreenApp = false, dpUp = 8f))

    @Test fun home32dpUpIsPage() = assertEquals(Owner.HOME_PAGE, owner(homeShown = true, fullScreenApp = false, dpUp = 32f))

    @Test fun homeWithWebWindowTaskUnderFingerAboveStripIsPage() {
        // The report's swipe: down at 349,2353 with task 2688 (a web window, not full screen) "under" the finger.
        assertEquals(Owner.HOME_PAGE, SidewaysOwner.decide(homeShown = true, fullScreenApp = false, downY = 2353f, screenBottom = bottom, stripPx = strip))
    }

    @Test fun fullScreenAppAboveStripIsUnchanged() = assertEquals(Owner.QUICK_SWITCH, owner(homeShown = false, fullScreenApp = true, dpUp = 32f))

    @Test fun fullScreenAppOverShownHomeIsUnchanged() = assertEquals(Owner.QUICK_SWITCH, owner(homeShown = true, fullScreenApp = true, dpUp = 32f))
}
