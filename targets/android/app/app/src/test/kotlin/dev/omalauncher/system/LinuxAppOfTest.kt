package dev.omalauncher.system

import dev.omalauncher.linux.LinuxApp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** KWin's "open" names a window by its desktop file, or (kwin 0052) its X11 class: which drawer app it is. */
class LinuxAppOfTest {
    private val steam = LinuxApp("Steam", "/usr/bin/steam %U", false, "steam", null)
    private val broforce = LinuxApp("Broforce", "steam steam://rungameid/274190", false, "Broforce", null)
    private val dolphin = LinuxApp("Dolphin", "dolphin", false, "org.kde.dolphin", null)
    private val apps = listOf(dolphin, broforce, steam)

    @Test fun steamsWindowIsSteamsSoItTakesItsLaunchPlaceholder() {
        // Steam opened as two windows (2026-11-02): offered as "", the "l:steam" placeholder never got its window.
        assertEquals(steam, RunningApps.linuxAppOf(apps, "steam"))
    }

    @Test fun aProtonGamesClassIsTheEntryThatStartsIt() {
        assertEquals(broforce, RunningApps.linuxAppOf(apps, "steam_app_274190"))
    }

    @Test fun aDesktopIdStillMatches() {
        assertEquals(dolphin, RunningApps.linuxAppOf(apps, "org.kde.dolphin"))
    }

    @Test fun noNameIsNoApp() {
        assertNull(RunningApps.linuxAppOf(apps, ""))
        assertNull(RunningApps.linuxAppOf(apps, "steam_app_1"))
    }

    /**
     * RL1 (the user 11-03: tapping Steam "launches a SECOND Steam instead of focusing the running one"): a launch's
     * running-window lookup (ShellBridge.linuxApp, which restoreLinux uses before it starts the app) maps a window to its
     * entry by the same rule as web windows, X11 class included - a desktop-id-only match missed Steam's window.
     */
    @Test fun aLaunchFindsTheRunningWindowByTheSameRule() {
        val src = File("src/main/kotlin/dev/omalauncher/shell/ShellBridge.kt").readText()
        val lookup = src.substringAfter("private fun linuxApp(").substringBefore("\n    }\n")
        assertTrue("ShellBridge.linuxApp no longer uses RunningApps.linuxAppOf", lookup.contains("RunningApps.linuxAppOf(runtime.linuxApps, appId)"))
        val restore = src.substringAfter("private fun restoreLinux(").substringBefore("\n    }\n")
        assertTrue("restoreLinux no longer looks the window up through linuxApp", restore.contains("linuxApp("))
        // The class Steam's window is offered by finds Steam's entry (the launch then restores, never starts again).
        assertEquals(steam, RunningApps.linuxAppOf(apps, "steam"))
    }
}
