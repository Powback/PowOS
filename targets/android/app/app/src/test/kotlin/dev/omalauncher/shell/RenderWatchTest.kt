package dev.omalauncher.shell

import dev.omalauncher.shell.RenderWatch.Act
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The render watchdog (2026-10-31: three "windows render empty" P0s - live windows, no geometry applied): a quiet
 * probe first, a stall only when the page didn't answer it, a reload once, then a back-off - never a loop.
 */
class RenderWatchTest {
    private val s = RenderWatch.STALE_MS

    @Test
    fun anIdleWorkingPageIsOnlyProbed() {
        val w = RenderWatch()
        assertEquals(Act.NONE, w.step(1_000, live = 1, homeShown = true, lastFrame = 500))
        assertEquals(Act.PROBE, w.step(10_000, 1, true, 500))
        // The page answered the probe: no stall, a new watch.
        assertEquals(Act.NONE, w.step(10_000 + s, 1, true, 10_050))
        assertEquals(Act.PROBE, w.step(10_000 + 3 * s, 1, true, 10_050))
    }

    @Test
    fun anUnansweredProbeIsAStallThenOneReloadThenABackOff() {
        val w = RenderWatch()
        assertEquals(Act.PROBE, w.step(10_000, 1, true, 0))
        assertEquals(Act.NONE, w.step(10_000 + s / 2, 1, true, 0))
        assertEquals(Act.STALL, w.step(10_000 + s, 1, true, 0))
        assertEquals(Act.RELOAD, w.step(10_000 + 2 * s, 1, true, 0))
        assertEquals(Act.NONE, w.step(10_000 + 2 * s + RenderWatch.BACKOFF_MS - 1, 1, true, 0))
        assertEquals(Act.PROBE, w.step(10_000 + 2 * s + RenderWatch.BACKOFF_MS, 1, true, 0))
    }

    @Test
    fun aStallAnsweredByTheResendRecovers() {
        val w = RenderWatch()
        w.step(10_000, 1, true, 0)
        assertEquals(Act.STALL, w.step(10_000 + s, 1, true, 0))
        assertEquals(Act.NONE, w.step(10_000 + 2 * s, 1, true, 10_000 + s + 30))
    }

    @Test
    fun noLiveWindowOrHomeHiddenIsNeverAStall() {
        val w = RenderWatch()
        assertEquals(Act.NONE, w.step(10_000, 0, true, 0))
        assertEquals(Act.PROBE, w.step(12_000, 1, true, 0))
        // Home hidden (an app full screen, the screen off): its frames don't run - the watch starts over.
        assertEquals(Act.NONE, w.step(14_000, 1, false, 0))
        assertEquals(Act.PROBE, w.step(16_000, 1, true, 0))
    }
}
