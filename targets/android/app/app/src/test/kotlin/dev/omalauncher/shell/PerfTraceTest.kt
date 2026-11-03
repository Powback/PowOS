package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PerfTraceTest {
    @Test
    fun aChecksRecordingIsNotMailed() {
        assertFalse(perfMailWanted("""{"summary":{"fps":{"p50":120}},"source":"verify"}"""))
    }

    @Test
    fun aUsersRecordingIsMailed() {
        assertTrue(perfMailWanted("""{"summary":{"fps":{"p50":120}},"source":"user"}"""))
        assertTrue(perfMailWanted("""{"summary":{}}"""))
        assertTrue(perfMailWanted("not json"))
    }
}
