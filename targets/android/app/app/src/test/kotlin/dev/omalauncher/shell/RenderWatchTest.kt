package dev.omalauncher.shell

import dev.omalauncher.shell.RenderWatch.Act
import dev.omalauncher.shell.RenderWatch.Companion.PROBE_MS
import dev.omalauncher.shell.RenderWatch.Companion.REBIND_MS
import dev.omalauncher.shell.RenderWatch.Companion.RELOAD_MS
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The render watchdog (2026-10-31: three "windows render empty" P0s - live windows, no geometry applied): a quiet
 * probe first, a stall (rebind) only when the page didn't answer it, a reload once, then a back-off - never a loop.
 * 15:37 the old 2 s steps took ~9 s to recover; now probe 1 s, rebind 1.5 s, reload no sooner than 4 s.
 */
class RenderWatchTest {
    /** Still windows: the page sends no "w.f" of its own (no frame tick while idle), only answers each probe. */
    @Test
    fun stillWindowsAnsweringProbesNeverStallForTwentySeconds() {
        val w = RenderWatch()
        var last = 1_000L
        var answerAt = 0L
        var t = last
        while (t <= last + 20_000) {
            if (answerAt != 0L && t >= answerAt) last = answerAt.also { answerAt = 0L }
            val act = w.step(t, 1, true, last)
            assertTrue("$act at $t", act == Act.NONE || act == Act.PROBE)
            if (act == Act.PROBE) answerAt = t + 30
            t += RenderWatch.WATCH_MS
        }
    }

    /** 11-06 23:46: a shell push reloaded home; the new page still booting 4 s later is not a stall. */
    @Test
    fun aReloadedPageHasItsBootBeforeItIsWatched() {
        val w = RenderWatch()
        w.pageStarted(10_000)
        var t = 10_000L
        while (t < 10_000 + RenderWatch.BOOT_MS) {
            assertEquals(Act.NONE, w.step(t, 1, true, 9_000))
            t += RenderWatch.WATCH_MS
        }
        // Silent past its boot: watched as before.
        assertEquals(Act.PROBE, w.step(10_000 + RenderWatch.BOOT_MS, 1, true, 9_000))
        // Its first frame ends the grace at once: a later silence is probed after PROBE_MS, not BOOT_MS.
        val v = RenderWatch()
        v.pageStarted(10_000)
        assertEquals(Act.NONE, v.step(11_000, 1, true, 10_800))
        assertEquals(Act.PROBE, v.step(10_800 + PROBE_MS, 1, true, 10_800))
    }

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
    fun aMinimisedOrPipWindowWithNoFramesIsNeverAStall() {
        // 11-03 22:50 (ship 9b16c2ce7's render-watch): one minimised Linux window, the page busy coming back to front,
        // no "w.f" for 1.6 s - a RENDER STALL + rebind for a window on display 0 the page never draws.
        val counted = { offHome: Boolean -> if (RenderWatch.owesGeometry(live = true, closed = false, offHome = offHome)) 1 else 0 }
        assertEquals(0, counted(true))
        assertEquals(1, counted(false))
        assertFalse(RenderWatch.owesGeometry(live = false, closed = false, offHome = false))
        assertFalse(RenderWatch.owesGeometry(live = true, closed = true, offHome = false))
        val w = RenderWatch()
        for (t in 0L..10_000L step RenderWatch.WATCH_MS) assertEquals(Act.NONE, w.step(26_000 + t, counted(true), true, 26_000))
        // Restored onto home: watched again (probe at 1 s with no frame).
        assertEquals(Act.PROBE, w.step(36_250, counted(false), true, 26_000))
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

    @Test
    fun underMemoryPressureAStallIsReboundNotReloaded() {
        // 11-02 05:07: the low-memory killer firing, the page slow; a reload would allocate a whole new page.
        val w = RenderWatch()
        w.trimmed(9_000)
        assertEquals(Act.PROBE, w.step(10_000, 1, true, 0))
        assertEquals(Act.STALL, w.step(10_000 + REBIND_MS, 1, true, 0))
        var t = 10_000 + REBIND_MS
        val end = 9_000 + RenderWatch.PRESSURE_MS
        var stalls = 0
        while (t + RenderWatch.WATCH_MS < end) {
            t += RenderWatch.WATCH_MS
            val a = w.step(t, 1, true, 0)
            assertTrue("no reload under pressure at $t", a != Act.RELOAD)
            if (a == Act.STALL) stalls++
        }
        // Rebound every RELOAD_MS meanwhile (the windows keep their geometry, the page asked again).
        assertTrue(stalls >= 10)
        // The page answers: a new watch, nothing to do.
        assertEquals(Act.NONE, w.step(t + 1, 1, true, t))
    }

    @Test
    fun aPageStillSilentAfterThePressurePassedIsReloadedOnce() {
        val w = RenderWatch()
        w.trimmed(1)
        var t = 1_000L
        var reloads = 0
        while (t < RenderWatch.PRESSURE_MS + 10_000) {
            if (w.step(t, 1, true, 0) == Act.RELOAD) {
                reloads++
                assertTrue(t >= 1 + RenderWatch.PRESSURE_MS)
            }
            t += RenderWatch.WATCH_MS
        }
        assertEquals(1, reloads)
    }

    @Test
    fun onlyRealPressureLevelsCount() {
        assertTrue(RenderWatch.isPressure(RenderWatch.TRIM_RUNNING_LOW))
        assertTrue(RenderWatch.isPressure(RenderWatch.TRIM_RUNNING_CRITICAL))
        assertTrue(RenderWatch.isPressure(RenderWatch.TRIM_BACKGROUND))
        assertTrue(RenderWatch.isPressure(80))
        assertTrue(!RenderWatch.isPressure(5))
        assertTrue(!RenderWatch.isPressure(RenderWatch.TRIM_UI_HIDDEN))
    }
}
