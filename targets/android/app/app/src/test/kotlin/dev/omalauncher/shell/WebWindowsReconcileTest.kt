package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
        val listen = src.substringAfter("FreeformTasks.listen {").substringBefore("\n        }\n")
        assertTrue("no task stack listener", listen.contains("main.post { scheduleReconcile() }"))
        assertTrue("PP1: the listener no longer checks PiP on the change itself", listen.contains("pipSoon()"))
        assertTrue("reconcile no longer checks each window", src.substringAfter("private fun reconcileNow(").substringBefore("\n    }\n").contains("checkOrphan"))
        val confirm = src.substringAfter("private fun confirmOrphan(w: Win) {").substringBefore("\n    }\n")
        assertTrue("confirmOrphan no longer reads the display's tasks", confirm.contains("tasksOn(w.displayId)"))
        assertTrue("confirmOrphan no longer closes the orphan through drop", confirm.contains("drop(w)"))
        val launch = src.substringAfter("private fun launch(w: Win) {").substringBefore("\n    }\n")
        assertTrue("a relaunch must reset landed", launch.contains("w.landed = false"))
        val closeAll = src.substringAfter("fun closeAll() {").substringBefore("\n    }\n")
        assertTrue("closeAll must stop the task listener", closeAll.contains("stopTasks?.invoke()"))
    }

    /** WM1: a window's task moved by the system or the app is followed: floating back in, full screen / split, PiP. */
    @Test
    fun followsTheTaskWhereverItGoes() {
        val f = WebWindows.Companion
        assertEquals("OnePlus' Floating window (zoom) on display 0", WebWindows.Companion.Follow.BACK, f.followOf(own = false, main = true, mode = 100))
        assertEquals("freeform on display 0", WebWindows.Companion.Follow.BACK, f.followOf(own = false, main = true, mode = 5))
        assertEquals("zoom inside its own display", WebWindows.Companion.Follow.BACK, f.followOf(own = true, main = false, mode = 100))
        assertEquals("full screen on display 0", WebWindows.Companion.Follow.FULL, f.followOf(own = false, main = true, mode = 1))
        assertEquals("a split on display 0", WebWindows.Companion.Follow.FULL, f.followOf(own = false, main = true, mode = 6))
        assertEquals("PiP", WebWindows.Companion.Follow.PIP, f.followOf(own = false, main = true, mode = 2))
        assertNull("full screen in its own display: nothing", f.followOf(own = true, main = false, mode = 1))
        assertNull("another display (Open Canvas): the orphan rule decides", f.followOf(own = false, main = false, mode = 100))
        val bridge = File("src/main/kotlin/dev/omalauncher/shell/ShellBridge.kt").readText()
        assertTrue("SystemFloat's hand-over must give a window's own task back to it, never a second window",
            bridge.substringAfter("fun toWebWindow(id: Int): Boolean {").substringBefore("\n    }\n").contains("WebWindows.followTask(id)"))
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        assertTrue("reconcile no longer follows before the orphan check", src.substringAfter("private fun reconcileNow(").substringBefore("\n    }\n").contains("follow(it, running)"))
    }

    /**
     * PP1 (the user, 11-01 15:48: "when I press PiP in Calculator, the PowOS title bar still sticks around"): an app that
     * leaves its window by itself (PiP, its own floating window) drops the window's frame and is tracked as PiP; expanded
     * back, it returns to the window.
     */
    @Test
    fun anAppLeavingForPipIsTrackedAndComesBack() {
        val f = WebWindows.Companion
        val enter = WebWindows.Companion.Pip.ENTER
        val leave = WebWindows.Companion.Pip.LEAVE
        val own = WebWindows.Companion.At.OWN
        val main = WebWindows.Companion.At.MAIN
        val elsewhere = WebWindows.Companion.At.ELSEWHERE
        assertEquals("PiP on display 0", enter, f.pipStep(pip = false, at = main, mode = 2, float = false))
        assertEquals("PiP in its own display", enter, f.pipStep(pip = false, at = own, mode = 2, float = false))
        assertEquals("the user's own floating window on display 0", enter, f.pipStep(pip = false, at = main, mode = 100, float = true))
        assertNull("PowOS's own float (SystemFloat's hand-over): follow pulls it back, not PiP", f.pipStep(pip = false, at = main, mode = 5, float = false))
        assertNull("in PiP still", f.pipStep(pip = true, at = main, mode = 2, float = false))
        assertEquals("PiP expanded to full screen on display 0", leave, f.pipStep(pip = true, at = main, mode = 1, float = false))
        assertEquals("back on its own display", leave, f.pipStep(pip = true, at = own, mode = 1, float = false))
        assertNull("another display: the orphan rule decides", f.pipStep(pip = false, at = elsewhere, mode = 2, float = false))
        assertNull("full screen in its window: nothing", f.pipStep(pip = false, at = own, mode = 1, float = false))
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        val follow = src.substringAfter("    private fun follow(").substringBefore("\n    }\n")
        assertTrue("follow no longer checks PiP first", follow.contains("if (pipCheck(w, t)) return true"))
        val enterFn = src.substringAfter("private fun pipEnter(").substringBefore("\n    }\n")
        assertTrue("pipEnter must hide the frame", enterFn.contains("hideFrame(w)"))
        assertTrue("pipEnter must tell the page", enterFn.contains("\"webwindows.pip\""))
        assertTrue("pipEnter must track it for the switcher", enterFn.contains("WebWindowDisplays.pip(task, w.id, true)"))
        assertTrue("pipEnter must not go through the minimise path", !enterFn.contains("minimise"))
        val leaveFn = src.substringAfter("private fun pipLeave(").substringBefore("\n    }\n")
        assertTrue("pipLeave must move the task back into its window", leaveFn.contains("moveTask(task, w.displayId)"))
    }
}
