package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The readiness watchdog (ShellHost.checkBoot). 2026-11: a full-screen game (Broforce) covered home, every shell page
 * behind it reloaded and couldn't draw, and the 20 s check sent "not ready" for home, shade, status bar, assist, pull
 * and Quick Tools at once. A covered page is not hung; one that doesn't answer while on the screen is.
 */
class BootJudgeTest {
    @Test
    fun aPageBehindAFullScreenGameIsNotJudged() {
        assertEquals(BootJudge.Before.WAIT_HIDDEN, BootJudge.before(interactive = true, onScreen = false, waitedHidden = false))
        assertEquals(BootJudge.Before.WAIT_HIDDEN, BootJudge.before(interactive = true, onScreen = false, waitedHidden = true))
    }

    @Test
    fun backOnTheScreenItsBootClockStartsAgain() {
        assertEquals(BootJudge.Before.RESTART, BootJudge.before(interactive = true, onScreen = true, waitedHidden = true))
    }

    @Test
    fun aVisiblePageIsAskedAndTheScreenOffStillWaits() {
        assertEquals(BootJudge.Before.PROBE, BootJudge.before(interactive = true, onScreen = true, waitedHidden = false))
        assertEquals(BootJudge.Before.WAIT_SCREEN_OFF, BootJudge.before(interactive = false, onScreen = true, waitedHidden = false))
        assertEquals(BootJudge.Before.WAIT_SCREEN_OFF, BootJudge.before(interactive = false, onScreen = false, waitedHidden = true))
    }

    @Test
    fun aHiddenDocumentAt20sWaitsInsteadOfFailing() {
        assertEquals(BootJudge.After.WAIT_HIDDEN, BootJudge.after(alive = false, pageHidden = true, hadError = false, after = 20_000, slowMs = 20_000))
        assertEquals(BootJudge.After.WAIT_HIDDEN, BootJudge.after(alive = false, pageHidden = true, hadError = true, after = 3_000, slowMs = 20_000))
    }

    @Test
    fun aVisiblePageThatNeverRendersStillFails() {
        assertEquals(BootJudge.After.FAIL, BootJudge.after(alive = false, pageHidden = false, hadError = false, after = 20_000, slowMs = 20_000))
        assertEquals(BootJudge.After.FAIL, BootJudge.after(alive = false, pageHidden = false, hadError = true, after = 3_000, slowMs = 20_000))
        assertEquals(BootJudge.After.LATER, BootJudge.after(alive = false, pageHidden = false, hadError = false, after = 8_000, slowMs = 20_000))
        assertEquals(BootJudge.After.READY, BootJudge.after(alive = true, pageHidden = true, hadError = false, after = 8_000, slowMs = 20_000))
    }
}
