package dev.omalauncher.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The keyboard AI button's way in on a phone without root (KeyboardAccess): restricted-settings detection, the path. */
class KeyboardAccessTest {
    @Test fun noRestrictedSettingsBeforeAndroid13() {
        assertFalse(KeyboardAccess.restricted(32, KeyboardAccess.MODE_ERRORED, KeyboardAccess.SOURCE_LOCAL_FILE))
    }

    @Test fun theOpModeWinsWhenItSays() {
        assertTrue(KeyboardAccess.restricted(34, KeyboardAccess.MODE_ERRORED, 0))
        assertFalse(KeyboardAccess.restricted(34, KeyboardAccess.MODE_ALLOWED, KeyboardAccess.SOURCE_LOCAL_FILE))
    }

    @Test fun otherwiseAFileOrDownloadInstallIsRestricted() {
        assertTrue(KeyboardAccess.restricted(35, KeyboardAccess.MODE_DEFAULT, KeyboardAccess.SOURCE_LOCAL_FILE))
        assertTrue(KeyboardAccess.restricted(35, null, KeyboardAccess.SOURCE_DOWNLOADED_FILE))
        // A session install (store, PowOS's own updater, PowApps since 11-25) or adb: unspecified / other / store.
        assertFalse(KeyboardAccess.restricted(35, KeyboardAccess.MODE_DEFAULT, 0))
        assertFalse(KeyboardAccess.restricted(35, null, 2))
        assertFalse(KeyboardAccess.restricted(35, null, null))
    }

    @Test fun accessibilityOnIsUsed() {
        assertEquals("accessibility", KeyboardAccess.via(root = false, accessibility = true, share = true, live = true))
    }

    @Test fun rootBeatsEverything() {
        assertEquals("root", KeyboardAccess.via(root = true, accessibility = true, share = true, live = true))
    }

    @Test fun restrictedFallsBackToAGrantedShare() {
        assertEquals("share", KeyboardAccess.via(root = false, accessibility = false, share = true, live = true))
        assertEquals("live", KeyboardAccess.via(root = false, accessibility = false, share = false, live = true))
        assertEquals("none", KeyboardAccess.via(root = false, accessibility = false, share = false, live = false))
    }

    @Test fun whyTellsTheKeyboardWhichStepsToShow() {
        assertEquals("restricted", KeyboardAccess.why(true))
        assertEquals("off", KeyboardAccess.why(false))
    }

    @Test fun shareModes() {
        assertEquals(KeyboardAccess.ShareMode.SESSION, KeyboardAccess.mode("session"))
        assertEquals(KeyboardAccess.ShareMode.ONCE, KeyboardAccess.mode("once"))
        assertEquals(KeyboardAccess.ShareMode.ONCE, KeyboardAccess.mode(null))
        assertTrue(KeyboardAccess.stopAfterGrab(KeyboardAccess.ShareMode.ONCE))
        assertFalse(KeyboardAccess.stopAfterGrab(KeyboardAccess.ShareMode.SESSION))
    }
}
