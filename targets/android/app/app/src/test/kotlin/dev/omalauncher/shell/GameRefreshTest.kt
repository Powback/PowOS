package dev.omalauncher.shell

import andro.marchy.GameRefresh
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.function.Predicate

/**
 * A game's window task asks for its screen's fastest refresh rate while it is the top task (games-120, 11-05: ColorOS
 * held com.powos.app's cover screen at 60 Hz under Broforce). The cover's modes as SurfaceFlinger listed them:
 * 120 / 60 / 90 Hz at 1116x2484 (mode ids 4-6), plus one at another resolution that must never be picked.
 */
class GameRefreshTest {
    private val ids = intArrayOf(5, 4, 6, 9)
    private val ws = intArrayOf(1116, 1116, 1116, 720)
    private val hs = intArrayOf(2484, 2484, 2484, 1600)
    private val hz = floatArrayOf(60f, 120f, 90f, 144f)
    private val games = Predicate<String> { WebWindows.isGame(it, null) }

    private fun want(
        front: Boolean,
        app: String?,
        isGame: Predicate<String>? = games,
    ) = GameRefresh.wanted(front, app, isGame, ids, ws, hs, hz, 1116, 2484)

    @Test
    fun aProtonGameInFrontAsksForTheFastestModeAtTheScreensResolution() = assertEquals(4, want(true, "steam_app_274190"))

    @Test
    fun theSameGameBehindAnotherTaskAsksForNone() = assertEquals(0, want(false, "steam_app_274190"))

    @Test
    fun steamItselfAndOtherAppsAskForNone() {
        assertEquals(0, want(true, "steam"))
        assertEquals(0, want(true, "org.kde.dolphin"))
        assertEquals(0, want(true, null))
    }

    @Test
    fun beforeTheAppSaysWhatIsAGameNothingIsAsked() = assertEquals(0, want(true, "steam_app_274190", null))
}
