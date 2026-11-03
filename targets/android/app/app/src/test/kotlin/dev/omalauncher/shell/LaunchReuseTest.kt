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

    @Test
    fun aTaskOnAnotherToolsDisplayIsNeverTakenButLaunchedBeside() {
        // 11-01 ship 2a849163: the window-render check's Calculator (task 2256, its own display 98) - a launch of the app
        // must not move it (the check's display went flat black); a task of the app's own instead.
        assertEquals(Decision.Apart, LaunchReuse.decide(pkg, emptyList(), listOf(Task(2256, pkg, pkg, 98))))
        // The user's own task on the main display still wins over the foreign one.
        assertEquals(Decision.Adopt(7), LaunchReuse.decide(pkg, emptyList(), listOf(Task(2256, pkg, pkg, 98), Task(7, pkg, pkg, 0))))
        // Another web window's display is still never taken either.
        assertEquals(Decision.New, LaunchReuse.decide(pkg, listOf(Window(2, "other", 6, 11)), listOf(Task(6, "other", pkg, 11))))
    }

    @Test
    fun aNewWindowOfARunningAppIsASecondInstanceForEveryAppThatCanRunTwice() {
        val ws = listOf(Window(3, pkg, 9, 12))
        // Chrome (standard / singleTop launcher, the user 11-03): a second window, not the first one moved.
        assertEquals(Decision.Another, LaunchReuse.decideNew(pkg, LaunchReuse.multiInstance(0), ws, emptyList()))
        assertEquals(Decision.Another, LaunchReuse.decideNew(pkg, LaunchReuse.multiInstance(1), ws, emptyList()))
        // singleTask / singleInstance: Android puts it back in its one task - its window is reused (the page moves it).
        assertEquals(Decision.Reuse(3, 9), LaunchReuse.decideNew(pkg, LaunchReuse.multiInstance(LaunchReuse.LAUNCH_SINGLE_TASK), ws, emptyList()))
        assertEquals(Decision.Reuse(3, 9), LaunchReuse.decideNew(pkg, LaunchReuse.multiInstance(LaunchReuse.LAUNCH_SINGLE_INSTANCE), ws, emptyList()))
    }

    @Test
    fun aNewWindowOfAnAppWithNoWindowIsAnOrdinaryLaunch() {
        assertEquals(Decision.New, LaunchReuse.decideNew(pkg, true, emptyList(), emptyList()))
        assertEquals(Decision.Adopt(7), LaunchReuse.decideNew(pkg, true, emptyList(), listOf(Task(7, pkg, pkg, 0))))
    }
}
