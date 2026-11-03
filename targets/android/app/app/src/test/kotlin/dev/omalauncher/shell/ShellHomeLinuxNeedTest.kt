package dev.omalauncher.shell

import dev.omalauncher.linux.LinuxState
import dev.omalauncher.linux.Stage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A widget waiting for Linux tells the home why (11-03: on a phone without root it was an empty tile). */
class ShellHomeLinuxNeedTest {
    @Test
    fun widgetThatNeedsNoLinuxNeedsNothing() {
        assertNull(ShellHome.linuxNeed(false, LinuxState.NotInstalled))
        assertNull(ShellHome.linuxNeed(false, LinuxState.Installed))
    }

    @Test
    fun noImageOffersTheDownload() {
        assertEquals(ShellHome.IMAGE, ShellHome.linuxNeed(true, LinuxState.NotInstalled))
        assertEquals(ShellHome.IMAGE, ShellHome.linuxNeed(true, LinuxState.Failed(Stage.Download, "offline", emptyList())))
    }

    @Test
    fun installedOrCheckingIsStarting() {
        assertEquals("starting", ShellHome.linuxNeed(true, LinuxState.Installed))
        assertEquals("starting", ShellHome.linuxNeed(true, LinuxState.Checking))
        assertEquals("starting", ShellHome.linuxNeed(true, LinuxState.Installing(Stage.Download, "x", null, emptyList())))
    }
}
