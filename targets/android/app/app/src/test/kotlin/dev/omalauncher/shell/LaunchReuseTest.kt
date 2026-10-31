package dev.omalauncher.shell

import dev.omalauncher.shell.LaunchReuse.Decision
import dev.omalauncher.shell.LaunchReuse.Task
import dev.omalauncher.shell.LaunchReuse.Window
import org.junit.Assert.assertEquals
import org.junit.Test

/** One window per app (10-31 "opening two instances of the app"): a launch reuses the app's window or task. */
class LaunchReuseTest {
    private val pkg = "com.example.app"

    @Test
    fun noTaskAnywhereIsANewWindow() {
        assertEquals(Decision.New, LaunchReuse.decide(pkg, emptyList(), listOf(Task(5, "other", "other", 0))))
    }

    @Test
    fun itsWindowIsReusedEvenWhileStillLaunching() {
        val ws = listOf(Window(3, pkg, -1, -1))
        assertEquals(Decision.Reuse(3, -1), LaunchReuse.decide(pkg, ws, emptyList()))
        assertEquals(Decision.Reuse(4, 9), LaunchReuse.decide(pkg, listOf(Window(4, pkg, 9, 12)), listOf(Task(9, pkg, pkg, 12))))
    }

    @Test
    fun aTaskOnTheMainDisplayOrInASplitIsAdoptedNotLaunchedAgain() {
        assertEquals(Decision.Adopt(7), LaunchReuse.decide(pkg, emptyList(), listOf(Task(7, pkg, pkg, 0))))
        // Its top activity only (a dialog over another app's base): still that task.
        assertEquals(Decision.Adopt(8), LaunchReuse.decide(pkg, emptyList(), listOf(Task(8, "launcher", pkg, 0))))
    }

    @Test
    fun anotherWindowsTaskIsNeverTaken() {
        val ws = listOf(Window(2, "other", 6, 11))
        val ts = listOf(Task(6, "other", pkg, 11), Task(6, "other", pkg, 0))
        assertEquals(Decision.New, LaunchReuse.decide(pkg, ws, ts))
    }

    @Test
    fun aTaskOnAnUnknownDisplayIsNotMoved() {
        assertEquals(Decision.New, LaunchReuse.decide(pkg, emptyList(), listOf(Task(7, pkg, pkg, -1))))
    }
}
