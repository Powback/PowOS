package dev.omalauncher.system

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    private val own = "com.powos.app"
    private val yes = mapOf("supportsPocketStudioMultiWindow" to true, "supportsSplitScreenMultiWindow" to true, "supportsMultiWindow" to true)

    @Test
    fun anAppOxygenOsLetsIntoSplitViewIsASide() {
        assertNull(CanvasDock.sideVerdict("com.android.chrome", "Chrome", own, yes))
        // A build without OxygenOS's field: unknown is not a no.
        assertNull(CanvasDock.sideVerdict("com.android.chrome", "Chrome", own, mapOf("supportsMultiWindow" to true)))
    }

    @Test
    fun anAppOnOxygenOsSplitBlocklistIsNamedForTheUser() {
        // 11-23: "com.android.settings unSupportsSplitScreen by blockList or ForbidActivityList".
        val blocked = yes + ("supportsSplitScreenMultiWindow" to false)
        assertEquals("Settings can't be used in split view", CanvasDock.sideVerdict(settings, "Settings", own, blocked))
        assertEquals("Settings can't be used in split view", CanvasDock.sideVerdict(settings, "Settings", own, yes + ("supportsPocketStudioMultiWindow" to false)))
    }

    @Test
    fun powOsOwnTasksAreNeverASide() {
        // The lock face, home and the Linux windows are PowOS tasks (the old page rule let the lock face through).
        assertEquals("PowOS itself can't be a side of split view", CanvasDock.sideVerdict(own, "PowOS", own, yes))
        assertEquals("That app isn't open anymore", CanvasDock.sideVerdict(null, "That app", own, yes))
    }
}
