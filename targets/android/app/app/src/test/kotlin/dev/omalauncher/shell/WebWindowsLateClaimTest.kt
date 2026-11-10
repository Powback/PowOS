package dev.omalauncher.shell

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 11-10 ww-popups: a quick tap on a Linux window (adb `input tap`, a fast finger) ended before the page's "down" reached
 * the host, so [WebWindows.linuxClaim] found no gesture and sent KWin nothing (15 gestures logged, 0 XI2 touches in
 * Xwayland). The ended gesture is kept for LATE_CLAIM_MS and replayed as down + up. Source checks pin it.
 */
class WebWindowsLateClaimTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()

    private fun fn(name: String) = src.substringAfter("private fun $name(").substringBefore("\n    }\n")

    @Test
    fun anUnclaimedEndedGestureIsKept() {
        val touch = fn("onTouch")
        val end = fn("endGesture")
        assertTrue("an UP ends the gesture", touch.contains("endGesture(ev, claimed != null)"))
        assertTrue("an UP with no claim keeps its DOWN and UP", end.contains("endedDown = g") && end.contains("endedUp = MotionEvent.obtain(ev)"))
        assertTrue("a new DOWN drops the kept one", touch.substringBefore("linuxTouch = null").contains("dropEnded()"))
    }

    @Test
    fun aLateClaimReplaysTheTap() {
        val claim = fn("linuxClaim")
        assertTrue("within LATE_CLAIM_MS", claim.contains("SystemClock.uptimeMillis() - endedAt <= LATE_CLAIM_MS"))
        assertTrue("a late claim replays", claim.contains("} else if (late) {\n            replayEnded(win)"))
        val replay = fn("replayEnded")
        assertTrue("down then up", replay.indexOf("endedDown?.let { linuxInput(win, it) }") in 0 until replay.indexOf("endedUp?.let { linuxInput(win, it) }"))
        assertTrue("used once", replay.contains("dropEnded()"))
        assertTrue("an empty claim says so", fn("claimNote").contains("nothing sent"))
    }
}
