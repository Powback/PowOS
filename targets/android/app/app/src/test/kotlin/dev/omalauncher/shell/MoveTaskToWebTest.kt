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
    private fun move(
        web: Boolean = true,
        hasTask: Boolean = true,
        isWeb: Boolean = false,
        fullScreen: Boolean = false,
        taskFullScreen: Boolean = false,
        claimed: Boolean = false,
        wanted: Boolean = true,
    ) = WindowTasks.moveTaskToWeb(web, hasTask, isWeb, fullScreen, taskFullScreen, claimed, wanted)

    @Test fun aTaskShownAgainOnTheUnfoldedHomeBecomesAWebWindow() = assertTrue(move())

    /** Folded / the setting off / home's page not up: its task comes back, as before. */
    @Test fun webWindowsNotWantedKeepTheTask() = assertFalse(move(wanted = false))

    @Test fun aFallbackOpenNeverOffersAgain() = assertFalse(move(web = false))

    /** A game (full screen now, or its task made immersive) stays its full-screen task. */
    @Test fun fullScreenStaysATask() {
        assertFalse(move(fullScreen = true))
        assertFalse(move(taskFullScreen = true))
    }

    @Test fun aGamesLaunchWindowKeepsIt() = assertFalse(move(claimed = true))

    @Test fun noTaskOrAWebWindowAlreadyIsNotAMove() {
        assertFalse(move(hasTask = false))
        assertFalse(move(isWeb = true))
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
