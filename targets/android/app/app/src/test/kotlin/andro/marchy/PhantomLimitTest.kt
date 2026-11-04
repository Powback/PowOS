package andro.marchy

import andro.marchy.PhantomLimit.Fix
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 11-04 emulator: Android 12+'s child process limit killed KWin + the session bus once Plasma started (52 guest processes). */
class PhantomLimitTest {
    @Test
    fun theFixDependsOnTheAndroidVersionAndTheSwitch() {
        assertEquals(Fix.NONE, PhantomLimit.fix(30, null)) // Android 11: no limit
        assertEquals(Fix.ADB, PhantomLimit.fix(31, null))
        assertEquals(Fix.ADB, PhantomLimit.fix(33, "true"))
        assertEquals(Fix.DEVELOPER_OPTIONS, PhantomLimit.fix(34, null))
        assertEquals(Fix.DEVELOPER_OPTIONS, PhantomLimit.fix(36, "true"))
        assertEquals(Fix.NONE, PhantomLimit.fix(36, "false")) // "Disable child process restrictions" is on
        assertEquals(Fix.NONE, PhantomLimit.fix(33, "false"))
    }

    @Test
    fun adbCommandsAreTheDocumentedOnes() {
        assertEquals("adb shell device_config put activity_manager max_phantom_processes 2147483647",
            PhantomLimit.adbCommands(31))
        assertTrue(PhantomLimit.adbCommands(33).endsWith("adb shell settings put global settings_enable_monitor_phantom_procs false"))
    }

    @Test
    fun onlyAnUnexpectedSigkillCounts() {
        assertTrue(PhantomLimit.killedByAndroid(137, false))
        assertFalse(PhantomLimit.killedByAndroid(137, true)) // the app ended its own session
        assertFalse(PhantomLimit.killedByAndroid(1, false))
        assertTrue(PhantomLimit.atLimit(52))
        assertFalse(PhantomLimit.atLimit(20))
    }

    @Test
    fun theMessageNamesTheStep() {
        assertTrue(PhantomLimit.message(Fix.DEVELOPER_OPTIONS, 34, 40, true).contains("Disable child process restrictions"))
        assertTrue(PhantomLimit.message(Fix.ADB, 33, 40, false).contains("Android 13"))
    }
}
