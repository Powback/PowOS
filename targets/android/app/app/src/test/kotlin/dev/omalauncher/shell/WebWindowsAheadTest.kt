package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * N2 (docs/WEB_WINDOWS.md "Native-glued windows"): "w.f" geometry the page measured one frame ahead carries a third
 * stamp "1" after its two times; the host binds it to the visual-state callback of the commit that shows it
 * (FrameSync.ahead), never to the next draw (FrameSync.next, which would show it a frame EARLY). The page sends it only
 * once the host said "w.ahead 1", so an older host never sees one.
 */
class WebWindowsAheadTest {
    private val words = "12 2.5 0 1794000000000.00 1794000000003".split(' ')

    @Test
    fun theThirdStampMarksAheadFrames() {
        assertFalse(WebWindows.aheadFlag(words, 3))
        assertTrue(WebWindows.aheadFlag(words + "1", 3))
        assertFalse(WebWindows.aheadFlag(words + "0", 3))
    }

    @Test
    fun theThirdStampTwoMarksACorrection() {
        assertTrue(WebWindows.aheadKind(words, 3) == 0)
        assertTrue(WebWindows.aheadKind(words + "1", 3) == 1)
        assertTrue(WebWindows.aheadKind(words + "2", 3) == 2)
    }

    /**
     * 11-07 on the phone: 341 predictions sent, 4 applied - the page's own measure of each predicted frame came out a
     * little different (its frame late, a sub-pixel miss), went to FrameSync.next as a newer id and the prediction
     * waiting for its draw was dropped. A correction now takes the pending prediction's place (same draw); only one
     * whose prediction's draw already went falls back to next.
     */
    @Test
    fun aCorrectionTakesThePendingPredictionsPlace() {
        val sync = File("src/main/kotlin/dev/omalauncher/shell/FrameSync.kt").readText()
        val correct = sync.substringAfter("fun correct(").substringBefore("\n    }\n")
        assertTrue("correct no longer replaces the pending prediction's apply", correct.contains("p.apply = apply"))
        assertTrue("correct no longer falls back to next when the prediction already drew", correct.contains("next(id, cookie, pageEpochMs, apply)"))
    }

    @Test
    fun aheadFramesRideTheVisualStateCallback() {
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        val cmd = src.substringAfter("fun frameCommand(").substringBefore("\n    }\n")
        assertTrue("an ahead frame no longer goes to FrameSync.ahead", cmd.contains("1 -> sync.ahead("))
        assertTrue("a predicted frame's correction no longer goes to FrameSync.correct", cmd.contains("2 -> sync.correct("))
        val sync = File("src/main/kotlin/dev/omalauncher/shell/FrameSync.kt").readText()
        val ahead = sync.substringAfter("fun ahead(").substringBefore("\n    }\n")
        assertTrue("FrameSync.ahead no longer binds to postVisualStateCallback", ahead.contains("web.postVisualStateCallback("))
        val native = File("src/main/kotlin/dev/omalauncher/shell/ShellNative.kt").readText()
        assertTrue("the host no longer tells the page it takes ahead frames", native.contains("WebMessage(\"w.ahead 1\")"))
    }
    /**
     * Fix plan 1.3 (C5): the host no longer offers frame-ahead geometry by default - the prediction measured every
     * window twice a frame and almost none applied (phone 11-07: 341 sent, 4). Only debug.powos.ww_ahead=1 offers it,
     * for the A/B (ww-glue.sh WW_AHEAD); the host still binds an ahead frame whenever the page sends one.
     */
    @Test
    fun aheadIsOffByDefault() {
        val native = File("src/main/kotlin/dev/omalauncher/shell/ShellNative.kt").readText()
        val offer = native.lines().single { it.contains("WebMessage(\"w.ahead 1\")") }
        assertTrue("the offer is unconditional again: $offer", offer.trim().startsWith("if (WebWindows.debugOn(WebWindows.AHEAD_PROP))"))
        assertEquals("debug.powos.ww_ahead", WebWindows.AHEAD_PROP)
        assertFalse("unreadable property (no device) = off", WebWindows.debugOn(WebWindows.AHEAD_PROP))
    }
}
