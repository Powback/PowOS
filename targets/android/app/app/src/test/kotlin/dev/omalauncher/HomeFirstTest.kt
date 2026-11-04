package dev.omalauncher

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A PowOS launch while the Plasma desktop covers home (emulator 11-04: System Settings from the dock opened maximized
 * in a bare task over the desktop, no PowOS frame, no tap keyboard): home comes to the front first, so the window
 * opens as home's web window.
 */
class HomeFirstTest {
    @Test fun desktopInFrontWithWebWindowsBringsHomeFirst() = assertTrue(Runtime.homeFirst(webWindows = true, desktopCoversHome = true))

    @Test fun homeInFrontLaunchesInPlace() = assertFalse(Runtime.homeFirst(webWindows = true, desktopCoversHome = false))

    /** Web windows off (the task path) or desktop mode (KWin's desktop holds every window): the desktop stays. */
    @Test fun noWebWindowsKeepsTheDesktop() = assertFalse(Runtime.homeFirst(webWindows = false, desktopCoversHome = true))
}
