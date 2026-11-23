package dev.omalauncher.system

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/** The switcher's dock into Open Canvas: the app-pair shortcut's order and extras (CanvasDock.plan, pscanvas.md path A). */
class CanvasDockTest {
    private val settings = "com.android.settings"
    private val files = "com.coloros.filemanager"

    @Test
    fun droppedLeftTheDraggedAppIsIntentZero() {
        val p = CanvasDock.plan(settings, files, CanvasDock.Side.LEFT, 0)
        assertEquals(listOf(settings, files), p.packages)
    }

    @Test
    fun droppedRightTheDraggedAppIsIntentOne() {
        val p = CanvasDock.plan(settings, files, CanvasDock.Side.RIGHT, 0)
        assertEquals(listOf(files, settings), p.packages)
    }

    @Test
    fun extrasMarkAnAppPairSideBySideForTheUser() {
        val p = CanvasDock.plan(settings, files, CanvasDock.Side.LEFT, 10)
        assertEquals(true, p.extras["isPsSplitScreenCombination"])
        assertEquals(2, p.extras["androidx.flexible.layoutOrientation"])
        assertArrayEquals(intArrayOf(10, 10), p.extras["userIds"] as IntArray)
    }

    @Test
    fun labelReadsInCanvasOrder() {
        val labels = mapOf(settings to "Settings", files to "Files")
        assertEquals("Files | Settings", CanvasDock.plan(settings, files, CanvasDock.Side.RIGHT, 0).label(labels))
        assertEquals("Settings | filemanager", CanvasDock.plan(settings, files, CanvasDock.Side.LEFT, 0).label(mapOf(settings to "Settings")))
    }
}
