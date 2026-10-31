package dev.omalauncher.system

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A dock tap's full-screen launch stays full screen (10-31 15:16: "full screen and then they show desktop mode"). */
class FullScreenLaunchTest {
    @Test
    fun aFullScreenLaunchsTaskIsClaimedOnce() {
        FullScreenLaunch.mark("a.full", 1_000)
        assertTrue(FullScreenLaunch.claim("a.full", 1_300))
        assertFalse(FullScreenLaunch.claim("a.full", 1_400))
    }

    @Test
    fun anOldOrUnmarkedLaunchIsNotClaimed() {
        assertFalse(FullScreenLaunch.claim("a.none", 1_000))
        FullScreenLaunch.mark("a.old", 1_000)
        assertFalse(FullScreenLaunch.claim("a.old", 1_000 + FullScreenLaunch.CLAIM_MS + 1))
    }
}
