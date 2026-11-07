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
}
