package dev.omalauncher.shell

import dev.omalauncher.system.Switcher
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Board launch-closes-overview (agent abzu-fps 11-07 02:58 / 03:36 / 04:19): a launch while the switcher is up left the
 * switcher over home and the game's web window hidden under it; and a Linux window opening on home's page while an
 * empty PowosWindowActivity covered home ran unseen. Every launch closes the switcher; a Linux window opening brings
 * home forward over PowOS's own activities.
 */
class LaunchClosesOverviewTest {
    private val ww = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
    private val bridge = File("src/main/kotlin/dev/omalauncher/shell/ShellBridge.kt").readText()
    private val activity = File("src/main/kotlin/dev/omalauncher/shell/ShellActivity.kt").readText()

    @Test
    fun aLaunchClosesTheSwitcherUnlessASwipeOwnsIt() {
        assertTrue(Switcher.closesOnLaunch(open = true, gesture = false))
        assertFalse(Switcher.closesOnLaunch(open = true, gesture = true))
        assertFalse(Switcher.closesOnLaunch(open = false, gesture = false))
    }

    @Test
    fun everyLaunchPathTellsTheSwitcher() {
        // The page's and the overlay's launches (ShellBridge.launch) and every Linux window KWin opens or shows again.
        assertTrue(bridge.substringAfter("private fun launch(").substringBefore("\n    }\n").contains("Switcher.launched("))
        val opened = ww.substringAfter("fun linuxOpened(").substringBefore("\n    }\n")
        assertTrue("the 'again' path brings the window to the front", opened.substringBefore("emit(\"webwindows.show\"").contains("toFront("))
        assertTrue("a new offer brings the window to the front", opened.substringBefore("emit(\"webwindows.adopt\"").contains("if (offerShows(kwin, offer.appId)) toFront("))
        assertTrue(ww.substringAfter("private fun toFront(").substringBefore("\n    }\n").contains("Switcher.launched(why)"))
    }

    @Test
    fun homeComesForwardOnlyOverPowosOwnActivities() {
        val own = "com.powos.app"
        assertTrue(WebWindows.homeToFront(false, own, "andro.marchy.PowosWindowActivity", own))
        assertFalse("home in sight already", WebWindows.homeToFront(true, own, "andro.marchy.PowosWindowActivity", own))
        assertFalse("home itself", WebWindows.homeToFront(false, own, ShellActivity::class.java.name, own))
        assertFalse("home's alias", WebWindows.homeToFront(false, own, "andro.marchy.HomeShell", own))
        assertFalse("another app stays in front", WebWindows.homeToFront(false, "com.android.chrome", "org.chromium.Main", own))
        assertFalse("nothing known", WebWindows.homeToFront(false, null, null, own))
    }

    @Test
    fun homeBroughtForwardIsNotAHomePress() {
        // Read as Home (homePressed), it would open the switcher over home's main page - the very thing being closed.
        assertTrue(activity.contains("WebWindows.EXTRA_WINDOW_FRONT"))
        assertTrue(activity.substringAfter("override fun onNewIntent(").substringBefore("homePressed()").contains("!windowFront"))
    }
}
