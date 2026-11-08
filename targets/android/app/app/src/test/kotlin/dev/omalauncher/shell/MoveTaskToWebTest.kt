package dev.omalauncher.shell

import andro.marchy.WindowTasks
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A Linux window that got a task while web windows didn't take windows (folded, or home's page not up yet after an app
 * restart) and is shown again on the unfolded home moves into a web window (11-07 16:25: Steam's main window stayed a
 * task, raised behind home - a tap on Steam showed nothing for 161 s).
 */
class MoveTaskToWebTest {
    /** One KWin "open" of a window: what [WindowTasks.moveTaskToWeb] is asked. */
    private data class Case(
        val web: Boolean = true,
        val hasTask: Boolean = true,
        val isWeb: Boolean = false,
        val fullScreen: Boolean = false,
        val taskFullScreen: Boolean = false,
        val claimed: Boolean = false,
        val wanted: Boolean = true,
    )

    private fun move(c: Case = Case()) =
        WindowTasks.moveTaskToWeb(c.web, c.hasTask, c.isWeb, c.fullScreen, c.taskFullScreen, c.claimed, c.wanted)

    @Test fun aTaskShownAgainOnTheUnfoldedHomeBecomesAWebWindow() = assertTrue(move())

    /** Folded / the setting off / home's page not up: its task comes back, as before. */
    @Test fun webWindowsNotWantedKeepTheTask() = assertFalse(move(Case(wanted = false)))

    @Test fun aFallbackOpenNeverOffersAgain() = assertFalse(move(Case(web = false)))

    /** A game (full screen now, or its task made immersive) stays its full-screen task. */
    @Test fun fullScreenStaysATask() {
        assertFalse(move(Case(fullScreen = true)))
        assertFalse(move(Case(taskFullScreen = true)))
    }

    @Test fun aGamesLaunchWindowKeepsIt() = assertFalse(move(Case(claimed = true)))

    @Test fun noTaskOrAWebWindowAlreadyIsNotAMove() {
        assertFalse(move(Case(hasTask = false)))
        assertFalse(move(Case(isWeb = true)))
    }

    @Test fun openRetiresTheOldTaskOnceTheWebWindowTookIt() {
        val src = File("../engine/src/main/java/andro/marchy/WindowTasks.java").readText()
        val at = src.indexOf("else if (moveTaskToWeb(")
        assertTrue(at > 0)
        val branch = src.substring(at, src.indexOf("return;", at))
        // Offered first; only a taken window's task goes (replaced(): KWin is told nothing, the window lives on).
        assertTrue(branch.contains("&& WebWindowSource.offer(id, appId, title)"))
        assertTrue(branch.indexOf("WebWindowSource.offer") < branch.indexOf("had.replaced()"))
        assertTrue(branch.contains("tasks.remove(id, had)"))
    }

    /**
     * A launch (home's tap, apps.launch) of an app whose window is a task moves that task into a web window before any
     * raise: the raise sends KWin nothing, so [open]'s move never ran (11-08 00:58-01:39: Kate's task 2828 and Steam's
     * 2815/2816 floated over home; ww-glue/ww-popups timed out, close-button taps hit Kate).
     */
    @Test fun aLaunchMovesTheAppsTaskIntoAWebWindowBeforeARaise() {
        val bridge = File("src/main/kotlin/dev/omalauncher/shell/ShellBridge.kt").readText()
        val launch = bridge.substring(bridge.indexOf("private fun launchLinux("))
        assertTrue(launch.indexOf("moveLinuxToWeb(key)") in 0 until launch.indexOf("restoreLinux(key)"))
        assertTrue(launch.contains("if (moveLinuxToWeb(key)) {"))
        val move = bridge.substring(bridge.indexOf("private fun moveLinuxToWeb("))
        assertTrue(move.substring(0, move.indexOf("private fun restoreLinux(")).contains("WindowTasks.moveToWeb(it.id)"))
        val src = File("../engine/src/main/java/andro/marchy/WindowTasks.java").readText()
        val body = src.substring(src.indexOf("public static boolean moveToWeb(int taskId)"))
        val end = body.indexOf("return false;\n    }")
        val m = body.substring(0, end)
        // The same rule as KWin's show again, offered first; only a taken window's task goes, KWin told nothing.
        assertTrue(m.contains("moveTaskToWeb(true, true, WebWindowSource.isWeb(id), false, fullScreen(a)"))
        assertTrue(m.contains("WebWindowSource.wanted()"))
        assertTrue(m.indexOf("WebWindowSource.offer(") in 0 until m.indexOf("a.replaced()"))
        assertTrue(m.contains("tasks.remove(id, a)"))
    }
}
