package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MN1 (11-01 15:45, "doesn't open PiP for YouTube"): a minimise of a PiP app is a home swipe - its task to display 0,
 * then home, but only once it is in front there and settled; home 54 ms after the move paused YouTube before it was the
 * foreground app a home swipe leaves, and it never entered PiP. Apps without PiP keep the plain hide.
 */
class WebWindowsMinimisePipTest {
    @Test
    fun onlyAnAndroidPipAppOnItsDisplayGoesPip() {
        assertTrue(WebWindows.minimiseGoesPip(linux = false, displayId = 68, left = false, supportsPip = true))
        assertFalse(WebWindows.minimiseGoesPip(linux = false, displayId = 68, left = false, supportsPip = false))
        assertFalse(WebWindows.minimiseGoesPip(linux = true, displayId = 68, left = false, supportsPip = true))
        assertFalse(WebWindows.minimiseGoesPip(linux = false, displayId = -1, left = false, supportsPip = true))
        assertFalse(WebWindows.minimiseGoesPip(linux = false, displayId = 68, left = true, supportsPip = true))
    }

    @Test
    fun homeWaitsForTheAppInFrontAndSettled() {
        // The 15:45 case: home right after the move, the app not in front yet.
        assertEquals(WebWindows.LeaveStep.WAIT, WebWindows.leaveStep(front = false, sinceMove = 54, frontFor = -1))
        assertEquals(WebWindows.LeaveStep.WAIT, WebWindows.leaveStep(front = true, sinceMove = 100, frontFor = 50))
        val settle = WebWindows.LEAVE_FRONT_SETTLE_MS
        assertEquals(WebWindows.LeaveStep.HOME, WebWindows.leaveStep(front = true, sinceMove = settle + 50, frontFor = settle))
    }

    @Test
    fun homeAnywayAtTheCap() {
        val max = WebWindows.LEAVE_FRONT_MAX_MS
        assertEquals(WebWindows.LeaveStep.WAIT, WebWindows.leaveStep(front = false, sinceMove = max - 1, frontFor = -1))
        assertEquals(WebWindows.LeaveStep.HOME, WebWindows.leaveStep(front = false, sinceMove = max, frontFor = -1))
        // Under checkLeft's settle, so a minimised app is never read "brought to the front" while it waits.
        assertTrue(max < 2000L)
    }
}
