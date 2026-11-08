package dev.omalauncher

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The user 11-08: "When I try to open Steam or whatever, it just opens the version on the Plasma desktop instead of as
 * an app natively." powos-open-task said "desktop" for every launch (KWin off the session bus) and the launch brought
 * the Plasma desktop over home, so KWin kept the new window on it. With web windows on, a launch never shows the
 * desktop: KWin exports the window and home's page makes it a web window.
 */
class LaunchNotOnDesktopTest {
    @Test fun webWindowsNeverShowTheDesktop() = assertFalse(Runtime.desktopShowsLaunch(webWindows = true, desktopMode = false))

    @Test fun noWebWindowsShowTheDesktop() = assertTrue(Runtime.desktopShowsLaunch(webWindows = false, desktopMode = false))

    @Test fun desktopModeShowsTheDesktop() = assertTrue(Runtime.desktopShowsLaunch(webWindows = true, desktopMode = true))

    /** Every launch path's desktop fallback (app tap, terminal/command, Steam game) goes through showDesktopFor. */
    @Test fun launchPathsUseTheRule() {
        val src = File("src/main/kotlin/dev/omalauncher/Runtime.kt").readText()
        val rooted = src.substring(src.indexOf("private fun openRooted("), src.indexOf("/** Moves [window]'s Android task"))
        assertTrue(rooted.contains("showDesktopFor(app.id)"))
        assertFalse(rooted.contains("showDesktop()"))
        val command = src.substring(src.indexOf("    fun launch(\n        command: String,"), src.indexOf("private class LaunchOutcome"))
        assertFalse(command.contains("showDesktop()"))
        assertFalse(command.contains("::showDesktop"))
        assertTrue(command.contains("showDesktopFor(\"steam_app_\$game\")"))
    }
}
