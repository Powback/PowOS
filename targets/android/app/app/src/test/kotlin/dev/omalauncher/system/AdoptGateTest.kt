package dev.omalauncher.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Board inner-screen-stays-landscape-after-an-app-moves: which gate keeps a stray full-screen app from its web window. */
class AdoptGateTest {
    @Test
    fun unfoldedUnlockedDesktopAdopts() {
        assertNull(AdoptGate.held(floating = true, keyguard = false, switcherOpen = false))
        // The camera started by `am start` on the inner screen: a stray app of another package, never seen before.
        assertNull(AdoptGate.skip(own = false, adopted = false, windowed = false, buttonFull = false))
    }

    @Test
    fun eachGateSaysWhy() {
        assertNotNull(AdoptGate.held(floating = false, keyguard = false, switcherOpen = false))
        assertNotNull(AdoptGate.held(floating = true, keyguard = true, switcherOpen = false))
        assertNotNull(AdoptGate.held(floating = true, keyguard = false, switcherOpen = true))
        assertEquals("PowOS's own task", AdoptGate.skip(own = true, adopted = false, windowed = false, buttonFull = false))
        assertEquals("adopted once already", AdoptGate.skip(own = false, adopted = true, windowed = false, buttonFull = false))
        assertNotNull(AdoptGate.skip(own = false, adopted = false, windowed = true, buttonFull = false))
        assertNotNull(AdoptGate.skip(own = false, adopted = false, windowed = false, buttonFull = true))
    }
}
