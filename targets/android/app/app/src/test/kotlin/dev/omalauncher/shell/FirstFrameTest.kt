package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Test

class FirstFrameTest {
    @Test fun noFrameIsNeverLive() {
        // 11-06 16:46 Dolphin: consumer up, no frame - live 270 ms later made a blank window.
        assertEquals(FirstFrame.Act.WAIT, FirstFrame.step(270, 0, false))
        assertEquals(FirstFrame.Act.WAIT, FirstFrame.step(0, 0, false))
    }

    @Test fun theFirstPresentMakesItLive() {
        assertEquals(FirstFrame.Act.LIVE, FirstFrame.step(40, 1, false))
        assertEquals(FirstFrame.Act.LIVE, FirstFrame.step(30_000, 3, true))
    }

    @Test fun noFrameAfterTheNudgeTimeAsksKWinOnce() {
        assertEquals(FirstFrame.Act.NUDGE, FirstFrame.step(FirstFrame.NUDGE_MS, 0, false))
        assertEquals(FirstFrame.Act.WAIT, FirstFrame.step(FirstFrame.NUDGE_MS + 500, 0, true))
    }

    @Test fun theWaitEnds() {
        assertEquals(FirstFrame.Act.GIVE_UP, FirstFrame.step(FirstFrame.GIVE_UP_MS, 0, true))
        assertEquals(FirstFrame.Act.GIVE_UP, FirstFrame.step(FirstFrame.GIVE_UP_MS, 0, false))
    }
}
