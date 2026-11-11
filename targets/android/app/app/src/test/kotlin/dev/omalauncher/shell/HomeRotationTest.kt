package dev.omalauncher.shell

import android.content.pm.ActivityInfo
import android.view.Surface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Board inner-screen-stays-landscape-after-an-app-moves (11-11 21:45): the camera turned the inner screen landscape
 * (rot 0 -> 1) on display 0, moved into a web window, and display 0 kept rotation 1 (home asks UNSPECIFIED; a flat
 * phone's sensor proposes nothing, so WM keeps the last rotation). Home now asks its own rotation back for a moment.
 */
class HomeRotationTest {
    @Test
    fun cameraLandscapeTurnsBackToHomesRotation() {
        // The 21:45 case: inner screen (2268x2440 at rot 0 = natural portrait), home at 0, display left at 1.
        val natural = HomeRotation.naturalPortrait(2440, 2268, Surface.ROTATION_90)
        assertTrue(natural)
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_NOSENSOR, HomeRotation.orientationFor(Surface.ROTATION_0, Surface.ROTATION_90, natural))
        // Home itself landscape before, the app portrait: back to landscape.
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, HomeRotation.orientationFor(Surface.ROTATION_90, Surface.ROTATION_0, true))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE, HomeRotation.orientationFor(Surface.ROTATION_270, Surface.ROTATION_0, true))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, HomeRotation.orientationFor(Surface.ROTATION_90, Surface.ROTATION_0, false))
    }

    /** Control: the display never turned (or home's rotation is unknown) - home asks nothing. */
    @Test
    fun unchangedOrUnknownAsksNothing() {
        assertNull(HomeRotation.orientationFor(Surface.ROTATION_0, Surface.ROTATION_0, true))
        assertNull(HomeRotation.orientationFor(Surface.ROTATION_90, Surface.ROTATION_90, true))
        assertNull(HomeRotation.orientationFor(-1, Surface.ROTATION_90, true))
        assertFalse(HomeRotation.naturalPortrait(2484, 1116, Surface.ROTATION_0))
    }

    /** Wired: home records its rotation at pause, and every task moved off display 0 into a window asks it back. */
    @Test
    fun wiredIntoPauseAndTheMove() {
        val ww = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        val move = ww.substringAfter("private fun moveTask(").substringBefore("\n    }\n")
        assertTrue(move.contains("val from = taskDisplay(taskId)"))
        assertTrue(move.contains("from == android.view.Display.DEFAULT_DISPLAY") && move.contains("HomeRotation.back("))
        val act = File("src/main/kotlin/dev/omalauncher/shell/ShellActivity.kt").readText()
        assertTrue(act.substringAfter("override fun onPause()").substringBefore("\n    }\n").contains("HomeRotation.paused(this)"))
    }
}
