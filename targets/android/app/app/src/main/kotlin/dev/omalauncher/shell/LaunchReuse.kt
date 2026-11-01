package dev.omalauncher.shell

/**
 * One window per app (the user, 10-31: "Sometimes it shows it as empty if it's opening two instances of the app"): a
 * launch of an app that already has a task - on any display, minimised, in a split, in a web window - brings THAT task,
 * never a second web window or virtual display. Pure, so the JVM tests drive it ([WebWindows.open] feeds it).
 *
 * The empty window was a fresh display launched with NEW_TASK while the app's task lived on another display: Android
 * brought that task forward where it was and the new display stayed empty (until the stray pull or the 3 s fallback,
 * which then opened Android's own window: two instances).
 */
internal object LaunchReuse {
    /** A live (not closed) Android web window: its id, its app's package, its task (-1: not known yet), its display. */
    data class Window(val id: Int, val pkg: String, val task: Int, val display: Int)

    /** A running task: its id, its base and top activity's packages, its display (-1: not known). */
    data class Task(val id: Int, val basePkg: String?, val topPkg: String?, val display: Int)

    sealed class Decision {
        /** The app's web window already (also one still launching): raised, no second display. */
        data class Reuse(val window: Int, val task: Int) : Decision()

        /** The app's task runs outside every web window: a new window that moves THAT task in, no launch. */
        data class Adopt(val task: Int) : Decision()

        /** No task of the app anywhere: a new window, launched. */
        object New : Decision()

        /**
         * The app's only task lives on a display that is neither the main one nor a web window's (another tool's virtual
         * display: the ship's window-render check, scrcpy --new-display, a cast): never PowOS's to take. A new window,
         * launched as a task of its own (MULTIPLE_TASK) - a plain NEW_TASK launch makes Android move THAT task over
         * (11-01 ship 2a849163: the check's Calculator task 2256 left its display 98 mid-hold, which went flat black).
         */
        object Apart : Decision()
    }

    fun decide(
        pkg: String,
        windows: List<Window>,
        tasks: List<Task>,
    ): Decision {
        windows.firstOrNull { it.pkg == pkg }?.let { return Decision.Reuse(it.id, it.task) }
        val windowDisplays = windows.map { it.display }.filter { it >= 0 }.toSet()
        val windowTasks = windows.map { it.task }.filter { it >= 0 }.toSet()
        val its = tasks.filter { it.display >= 0 && it.display !in windowDisplays && it.id !in windowTasks && (it.basePkg == pkg || it.topPkg == pkg) }
        // Only the main display's tasks (minimised, in a split, full screen) are the user's window to bring in.
        its.firstOrNull { it.display == MAIN_DISPLAY }?.let { return Decision.Adopt(it.id) }
        return if (its.isEmpty()) Decision.New else Decision.Apart
    }

    /** android.view.Display.DEFAULT_DISPLAY (pure: no android.jar in the JVM test). */
    private const val MAIN_DISPLAY = 0
}
