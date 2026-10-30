package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A web window's frame never outlives its task (2026-10-30: OnePlus' Open Canvas re-parented Chrome off its display,
 * then removed it; the empty Chrome frame stayed, and every Chrome launch raised it).
 */
class WebWindowsReconcileTest {
    private fun orphaned(
        landed: Boolean = true,
        held: Boolean = false,
        closed: Boolean = false,
        tasks: Int?,
    ) = WebWindows.orphaned(closed, landed, held, tasks)

    @Test
    fun aWindowWhoseTaskLeftItsDisplayIsAnOrphan() {
        assertTrue(orphaned(tasks = 0))
    }

    @Test
    fun aRunningWindowIsKept() {
        assertFalse(orphaned(tasks = 1))
    }

    @Test
    fun launchesFullScreenAdoptsAndUnknownsAreKept() {
        assertFalse("still launching (checkLanded's case)", orphaned(landed = false, tasks = 0))
        assertFalse("a full-screen app out of the window, or adopting a task", orphaned(held = true, tasks = 0))
        assertFalse("unreadable: no close on a guess", orphaned(tasks = null))
        assertFalse("closed already", orphaned(closed = true, tasks = 0))
    }

    /** The rule is wired: a task stack listener drives reconcile, which drops (the bar's close path) an orphan. */
    @Test
    fun reconcileListensAndDrops() {
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        assertTrue("no task stack listener", src.contains("FreeformTasks.listen { main.post { scheduleReconcile() } }"))
        assertTrue("reconcile no longer checks each window", src.substringAfter("private fun reconcile() {").substringBefore("\n    }\n").contains("checkOrphan"))
        val confirm = src.substringAfter("private fun confirmOrphan(w: Win) {").substringBefore("\n    }\n")
        assertTrue("confirmOrphan no longer reads the display's tasks", confirm.contains("tasksOn(w.displayId)"))
        assertTrue("confirmOrphan no longer closes the orphan through drop", confirm.contains("drop(w)"))
        val launch = src.substringAfter("private fun launch(w: Win) {").substringBefore("\n    }\n")
        assertTrue("a relaunch must reset landed", launch.contains("w.landed = false"))
        val closeAll = src.substringAfter("fun closeAll() {").substringBefore("\n    }\n")
        assertTrue("closeAll must stop the task listener", closeAll.contains("stopTasks?.invoke()"))
    }
}
