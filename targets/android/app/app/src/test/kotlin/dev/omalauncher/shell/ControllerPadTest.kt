package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** ControllerPad.restore: the controller overlay comes back after an app restart only as the user left it. */
class ControllerPadTest {
    @Test
    fun leftOnComesBackAfterARestart() {
        // 11-06 Broforce: the overlay was on, the 13:59 update ended the process, nothing put it back.
        assertTrue(ControllerPad.restoreWanted(saved = true, shown = false, canDraw = true, sdk = 34))
    }

    @Test
    fun leftOffStaysOff() {
        assertFalse(ControllerPad.restoreWanted(saved = false, shown = false, canDraw = true, sdk = 34))
    }

    @Test
    fun alreadyUpIsNotAddedTwice() {
        assertFalse(ControllerPad.restoreWanted(saved = true, shown = true, canDraw = true, sdk = 34))
    }

    @Test
    fun noOverlayPermissionOrOldAndroidNeverTries() {
        assertFalse(ControllerPad.restoreWanted(saved = true, shown = false, canDraw = false, sdk = 34))
        assertFalse(ControllerPad.restoreWanted(saved = true, shown = false, canDraw = true, sdk = 32))
    }
}
