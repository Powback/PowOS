package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The verify pill's glass only over home's own page: any blur region makes SurfaceFlinger GPU-compose every layer
 * under it each frame (11-05 Broforce soak: every HWC layer CLIENT, the pill the only blur owner).
 */
class VerifyPillGlassTest {
    @Test
    fun glassOverHomeOnly() {
        assertTrue(VerifyRun.glassOver(homeInFront = true, webGame = null))
    }

    @Test
    fun noGlassOverAnAndroidWindowActivity() {
        // A Linux game full screen in PowosWindowActivity: home isn't in front.
        assertFalse(VerifyRun.glassOver(homeInFront = false, webGame = null))
    }

    @Test
    fun noGlassOverAWebWindowGame() {
        assertFalse(VerifyRun.glassOver(homeInFront = true, webGame = "broforce"))
    }
}
