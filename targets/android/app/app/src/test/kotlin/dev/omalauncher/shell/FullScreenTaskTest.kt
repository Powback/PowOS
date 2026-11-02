package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * FS2 (the user, 11-02 21:45: "Chrome is in a bad state" - Chrome's full screen showed its old window's 1154x1538 at
 * (0,197), top-left, the rest black; its task's mLastNonFullscreenBounds=Rect(0, 197 - 1156, 1735) on the 2268x2440
 * screen): a web window's app moved to display 0 as a full-screen app is made to fill the screen.
 */
class FullScreenTaskTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n    }\n")

    /** The device's case: floating (freeform / OnePlus' zoom) at the old window's size is not full screen. */
    @Test
    fun chromesLandingIsShort() {
        assertTrue(FullScreenTask.short(5, FullScreenTask.Size(1156, 1538), FullScreenTask.Size(2268, 2440)))
        assertTrue(FullScreenTask.short(100, FullScreenTask.Size(1156, 1538), FullScreenTask.Size(2268, 2440)))
        // Full screen by mode but held at the old window's bounds.
        assertTrue(FullScreenTask.short(1, FullScreenTask.Size(1156, 1538), FullScreenTask.Size(2268, 2440)))
    }

    /** A real full-screen task (the whole screen, folded or unfolded) is left alone; so are PiP and a split. */
    @Test
    fun aFullScreenTaskIsLeftAlone() {
        assertFalse(FullScreenTask.short(1, FullScreenTask.Size(2268, 2440), FullScreenTask.Size(2268, 2440)))
        assertFalse(FullScreenTask.short(1, FullScreenTask.Size(1116, 2484), FullScreenTask.Size(1116, 2484)))
        assertFalse(FullScreenTask.short(0, FullScreenTask.Size(2268, 2440), FullScreenTask.Size(2268, 2440)))
        assertFalse(FullScreenTask.short(1, FullScreenTask.Size(1156, 1538), FullScreenTask.Size(0, 0)))
        assertFalse(FullScreenTask.short(2, FullScreenTask.Size(500, 300), FullScreenTask.Size(2268, 2440)))
        assertFalse(FullScreenTask.short(6, FullScreenTask.Size(1134, 2440), FullScreenTask.Size(2268, 2440)))
    }

    /** Both ways onto display 0 (the bar's full screen, the dock bringing it to the front) check it, at once and settled. */
    @Test
    fun everyMoveToDisplay0IsChecked() {
        assertTrue("fullScreenNow no longer checks the landing", body("private fun fullScreenNow(").contains("if (ok) fillsScreen(win, task)"))
        assertTrue("front no longer checks the landing", body("private fun front(").contains("fillsScreen(w, w.taskId)"))
        val fills = body("private fun fillsScreen(")
        assertTrue(fills.contains("FullScreenTask.ensure(context, task, win.id, \"at the move\")"))
        assertTrue(fills.contains("FullScreenTask.SETTLE_MS"))
    }
}
