package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The device window check's display shares the default display group with every real window's display: an
 * OWN_DISPLAY_GROUP virtual display joins the ONE null-named group every such display shares (a phone-side scrcpy
 * --new-display's, asleep), and read flat from its first frame (11-01 03:04, window-render --hidden on bef59baf).
 */
class WebWindowsHostFlagsTest {
    private val ownDisplayGroup = 1 shl 11

    @Test fun selftestDisplayNeverHasItsOwnDisplayGroup() {
        assertEquals(0, WebWindowsHost.SELFTEST_FLAGS and ownDisplayGroup)
        assertEquals(0, WebWindowsHost.FLAGS and ownDisplayGroup)
    }

    @Test fun selftestDisplayIsAWindowDisplayPlusUnlockedAndOwnFocus() {
        assertEquals(WebWindowsHost.FLAGS or (1 shl 12) or (1 shl 14), WebWindowsHost.SELFTEST_FLAGS)
    }
}
