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

/**
 * An Android app launched from OUTSIDE PowOS (a notification, the share sheet, a deep link, another app, the assistant)
 * while the switcher is up - a floating window leaves home in sight, so no home stop hid it: the task stack listener's
 * newly-fronted visible task closes it (Switcher.watchLaunches).
 */
class OutsideLaunchClosesOverviewTest {
    private val home = Switcher.ownFronts
    private val since = 1_000L
    private fun t(id: Int, c: String, visible: Boolean, at: Long) = dev.omalauncher.system.Tasks.Front(id, c, visible, at)

    @Test
    fun aTaskFrontedAfterTheSwitcherOpenedIsALaunch() {
        val list = listOf(t(7, "com.whatsapp/.Main", true, 1_500), t(3, "com.android.chrome/org.chromium.Main", false, 900))
        org.junit.Assert.assertEquals(7, dev.omalauncher.system.Tasks.frontedSince(list, since, home))
    }

    @Test
    fun homeTheSwitcherAndOlderOrHiddenTasksAreNot() {
        val list =
            listOf(
                t(1, "com.powos.app/andro.marchy.HomeShell", true, 1_600),
                t(2, "com.powos.app/" + ShellActivity::class.java.name, true, 1_600),
                t(4, "com.powos.app/" + SwitcherActivity::class.java.name, true, 1_600),
                // The app it was opened over: in front before the switcher came up.
                t(5, "com.android.chrome/org.chromium.Main", true, 900),
                // Fronted but not showing (moved behind at once).
                t(6, "com.spotify/.Main", false, 1_700),
            )
        org.junit.Assert.assertNull(dev.omalauncher.system.Tasks.frontedSince(list, since, home))
    }

    @Test
    fun theWatchRunsWhileTheSwitcherIsUpAndCloses() {
        val src = File("src/main/kotlin/dev/omalauncher/system/Switcher.kt").readText()
        val watch = src.substringAfter("private fun watchLaunches(").substringBefore("\n    }\n")
        assertTrue(watch.contains("FreeformTasks.listen"))
        assertTrue(watch.contains("launched("))
        assertTrue("watched from the moment it's up", src.substringAfter("var open = false").substringBefore("\n        }\n").contains("watchLaunches(v)"))
    }

    /**
     * e2e-desktop 248 40-recents (11-07: "the switcher shows no card for Calculator"): the switcher closed itself 21 ms
     * after it came up - its watch's start was uptimeMillis, 78 min behind lastActiveTime's elapsedRealtime after deep
     * sleep, so the floating Calculator it was opened over (fronted by a dock tap a minute before) read as a launch.
     * The start is in lastActiveTime's clock; a window fronted before the switcher came up never closes it.
     */
    @Test
    fun theWatchStartsInLastActiveTimesClock() {
        val src = File("src/main/kotlin/dev/omalauncher/system/Switcher.kt").readText()
        val watch = src.substringAfter("private fun watchLaunches(").substringBefore("\n    }\n")
        assertTrue("since = elapsedRealtime (lastActiveTime's clock)", watch.contains("val since = SystemClock.elapsedRealtime()"))
        assertTrue("never uptimeMillis (stops in deep sleep)", !watch.contains("SystemClock.uptimeMillis()"))
        // The device's numbers: switcher up at elapsed 57_306_000 (uptime 52_636_000); Calculator fronted 60 s before.
        val calculator = t(2743, "com.oneplus.calculator/com.android.calculator2.Calculator", true, 57_246_000)
        org.junit.Assert.assertNull(dev.omalauncher.system.Tasks.frontedSince(listOf(calculator), 57_306_000, home))
    }
}
