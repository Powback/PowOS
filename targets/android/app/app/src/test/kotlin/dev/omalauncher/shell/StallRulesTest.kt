package dev.omalauncher.shell

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The fps meter's native recording (MainStallWatch). Trace perf-1793551432355 (11-01 17:43): a frame lost 49.9 ms to the
 * UI thread being busy with no message logged (the old 50 ms threshold), and its gap read as the recorder's own
 * perf.native call - which had ended 4.5 s before.
 */
class StallRulesTest {
    @Test
    fun aMessageJustUnderFiftyMsIsKept() {
        assertTrue(StallRules.keepsMessage(49))
        assertTrue(StallRules.keepsMessage(25))
        assertFalse(StallRules.keepsMessage(StallRules.MSG_MS))
        assertFalse(StallRules.keepsMessage(8))
    }

    @Test
    fun aGapSaysHowLongAgoTheLastBridgeCallEnded() {
        val g = StallRules.gapEntry(1_793_551_424_514, 59, "perf.native", StallRules.callAgo(lastCallEnd = 10_000, at = 14_580))
        assertEquals("perf.native", g.getString("lastCall"))
        assertEquals(4_580L, g.getLong("lastCallAgoMs"))
        assertEquals(59L, g.getLong("ms"))
    }

    @Test
    fun aGapBeforeAnyBridgeCallHasNoAge() {
        val g = StallRules.gapEntry(1L, 60, null, StallRules.callAgo(lastCallEnd = 0, at = 500))
        assertTrue(g.isNull("lastCallAgoMs"))
        assertTrue(g.isNull("lastCall"))
        assertEquals(JSONObject.NULL, g.get("lastCall"))
    }
}
