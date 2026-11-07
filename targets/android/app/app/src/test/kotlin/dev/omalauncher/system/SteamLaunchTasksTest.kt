package dev.omalauncher.system

import dev.omalauncher.linux.LinuxApp
import dev.omalauncher.system.SteamLaunchTasks.Act
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * SL1 folded: a game Steam launches where its window will be a task (folded) gets its full-screen launch window at
 * once, which follows Steam's phases, says why when the launch ends before its window, steps back while Steam asks,
 * and is never opened twice (also not over a game that shows a window already, nor for an old launch).
 */
class SteamLaunchTasksTest {
    private val broforce = LinuxApp("Broforce", "steam steam://rungameid/274190", false, "Broforce", null)
    private val now = 1_800_000_000_000L
    private val since = now / 1000 - 2

    private fun launch(
        state: String,
        phase: String? = "Syncing saves",
        at: Long = since,
    ) = SteamLaunchTasks.Launch("274190", at, state, phase, if (state == "ended") "It closed before it showed a window" else null, "Broforce", "Broforce", listOf("Broforce", "steam_app_274190"))

    private fun plan(
        l: SteamLaunchTasks.Launch,
        tasks: Boolean = true,
        held: Boolean = false,
        asking: Boolean = false,
        window: Boolean = false,
    ) = SteamLaunchTasks.plan(listOf(l), tasks, if (held) setOf(l.token) else emptySet(), if (asking) setOf(l.token) else emptySet(), now) { window }.map { it.first }

    @Test fun aFoldedLaunchOpensItsTaskAtTheFirstStep() {
        assertEquals(listOf(Act.OPEN), plan(launch("launching")))
        assertEquals(listOf(Act.OPEN), plan(launch("running", "Starting Proton")))
    }

    @Test fun unfoldedTheLaunchIsThePagesPlaceholder() {
        assertEquals(emptyList<Act>(), plan(launch("launching"), tasks = false))
    }

    @Test fun anUnfoldMidLaunchKeepsTheTaskFollowingSteam() {
        // Opened folded, then unfolded: it holds the launch whatever the screen, until the game's window becomes it.
        assertEquals(listOf(Act.PHASE), plan(launch("running", "Loading"), tasks = false, held = true))
    }

    @Test fun neverASecondTaskNorOneOverTheGamesWindowNorAnOldLaunch() {
        assertEquals(listOf(Act.PHASE), plan(launch("running"), held = true))
        assertEquals(emptyList<Act>(), plan(launch("running"), window = true))
        assertEquals(emptyList<Act>(), plan(launch("running", at = since - SteamLaunchTasks.START_MS / 1000 - 5)))
    }

    @Test fun endedBeforeItsWindowSaysWhy() {
        assertEquals(listOf(Act.FAIL), plan(launch("ended"), held = true))
        assertEquals(emptyList<Act>(), plan(launch("ended")))
    }

    @Test fun steamAskingStepsBackThenComesBack() {
        assertEquals(listOf(Act.ASK), plan(launch("asking", "Steam is asking something"), held = true))
        assertEquals(listOf(Act.PHASE), plan(launch("asking"), held = true, asking = true))
        assertEquals(listOf(Act.RESUME), plan(launch("launching"), held = true, asking = true))
        assertEquals(emptyList<Act>(), plan(launch("asking")))
    }

    @Test fun itsTaskCarriesTheIdsTheGamesWindowHas() {
        val text = """{"launches": {"274190": {"state": "launching", "phase": "Getting ready", "name": "Broforce", "since": 5},
            "9": {"state": "running", "name": "Other", "since": 6}}}"""
        val all = SteamLaunchTasks.parse(text, listOf(broforce)).associateBy { it.appid }
        assertEquals("Broforce", all["274190"]!!.appId)
        assertEquals(listOf("Broforce", "steam_app_274190"), all["274190"]!!.ids)
        assertEquals("steam_app_9", all["9"]!!.appId)
        assertEquals("Other", all["9"]!!.label)
        // The page's entry says the task holds it: no placeholder there (a fold mid-launch closes the page's).
        val page = RunningApps.launchesFor(text, listOf(broforce), setOf("274190@5"))
        val byId = (0 until page.length()).map { page.getJSONObject(it) }.associateBy { it.getString("appid") }
        assertEquals(true, byId["274190"]!!.optBoolean("task"))
        assertEquals(false, byId["9"]!!.optBoolean("task"))
    }
}
