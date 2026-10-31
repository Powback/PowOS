package dev.omalauncher.shell

import dev.omalauncher.shell.RenderWatch.Act
import dev.omalauncher.shell.RenderWatch.Companion.PROBE_MS
import dev.omalauncher.shell.RenderWatch.Companion.REBIND_MS
import dev.omalauncher.shell.RenderWatch.Companion.RELOAD_MS
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The render watchdog (2026-10-31: three "windows render empty" P0s - live windows, no geometry applied): a quiet
 * probe first, a stall (rebind) only when the page didn't answer it, a reload once, then a back-off - never a loop.
 * 15:37 the old 2 s steps took ~9 s to recover; now probe 1 s, rebind 1.5 s, reload no sooner than 4 s.
 */
class RenderWatchTest {
    @Test
    fun anIdleWorkingPageIsOnlyProbed() {
        val w = RenderWatch()
        assertEquals(Act.NONE, w.step(1_000, live = 1, homeShown = true, lastFrame = 500))
        assertEquals(Act.PROBE, w.step(10_000, 1, true, 500))
        // The page answered the probe: no stall, a new watch.
        assertEquals(Act.NONE, w.step(10_000 + REBIND_MS, 1, true, 10_050))
        assertEquals(Act.PROBE, w.step(10_050 + PROBE_MS, 1, true, 10_050))
    }

    @Test
    fun theStepsLandAtOneSecondOneAndAHalfAndFour() {
        val w = RenderWatch()
        val last = 10_000L
        var probe = 0L
        var stall = 0L
        var reload = 0L
        // The host's watch ticks every WATCH_MS.
        var t = last
        while (t <= last + 10_000 && reload == 0L) {
            when (w.step(t, 1, true, last)) {
                Act.PROBE -> probe = t
                Act.STALL -> stall = t
                Act.RELOAD -> reload = t
                Act.NONE -> Unit
            }
            t += RenderWatch.WATCH_MS
        }
        assertEquals(last + 1_000, probe)
        assertEquals(last + 1_500, stall)
        assertEquals(last + 4_000, reload)
        assertTrue(PROBE_MS + REBIND_MS + RELOAD_MS >= 4_000)
    }

    @Test
    fun anUnansweredProbeIsAStallThenOneReloadThenABackOff() {
        val w = RenderWatch()
        assertEquals(Act.PROBE, w.step(10_000, 1, true, 0))
        assertEquals(Act.NONE, w.step(10_000 + REBIND_MS / 2, 1, true, 0))
        assertEquals(Act.STALL, w.step(10_000 + REBIND_MS, 1, true, 0))
        assertEquals(Act.NONE, w.step(10_000 + REBIND_MS + RELOAD_MS - 1, 1, true, 0))
        val at = 10_000 + REBIND_MS + RELOAD_MS
        assertEquals(Act.RELOAD, w.step(at, 1, true, 0))
        assertEquals(Act.NONE, w.step(at + RenderWatch.BACKOFF_MS - 1, 1, true, 0))
        assertEquals(Act.PROBE, w.step(at + RenderWatch.BACKOFF_MS, 1, true, 0))
    }

    @Test
    fun aStallAnsweredByTheRebindRecovers() {
        val w = RenderWatch()
        w.step(10_000, 1, true, 0)
        assertEquals(Act.STALL, w.step(10_000 + REBIND_MS, 1, true, 0))
        // Answered 30 ms after the rebind: no reload when it would have been due, a new watch from that frame.
        assertEquals(Act.NONE, w.step(10_000 + REBIND_MS + 250, 1, true, 10_000 + REBIND_MS + 30))
        assertEquals(Act.NONE, w.step(10_000 + REBIND_MS + 30 + PROBE_MS - 1, 1, true, 10_000 + REBIND_MS + 30))
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

    @Test
    fun aReclaimedLinuxWindowWithNoConsumerIsReboundAfterOneSecond() {
        assertEquals(1_000L, ConsumerCheck.CONSUMER_UP_MS)
        assertEquals(ConsumerCheck.Act.UP, ConsumerCheck.step(closed = false, handle = 42, starting = true))
        assertEquals(ConsumerCheck.Act.UP, ConsumerCheck.step(closed = true, handle = 0, starting = false))
        // 16:00 Dolphin: its start never taken (the consumers' thread wedged by a stop): re-bound.
        assertEquals(ConsumerCheck.Act.REBIND, ConsumerCheck.step(closed = false, handle = 0, starting = false))
        assertEquals(ConsumerCheck.Act.STARTING, ConsumerCheck.step(closed = false, handle = 0, starting = true))
    }
}
