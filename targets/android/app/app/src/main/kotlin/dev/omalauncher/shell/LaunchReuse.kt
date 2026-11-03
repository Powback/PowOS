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

        /**
         * A second window of an app that has one (the dock's drag-out, an icon's "new window"; the user 11-03: "if I want
         * to open up another chrome instance on this page"): a new window, the app launched there as a task of its own
         * (MULTIPLE_TASK | NEW_DOCUMENT) - every app [multiInstance] allows.
         */
        object Another : Decision()
    }

    /**
     * [decide] for a NEW window of [pkg] (the drag-out, "new window"): an app with a window already that can run twice
     * ([multi]: [multiInstance]) gets [Decision.Another]; any other gets [decide]'s (a single-instance app's window is
     * reused: the page moves it to the page asked for).
     */
    fun decideNew(
        pkg: String,
        multi: Boolean,
        windows: List<Window>,
        tasks: List<Task>,
    ): Decision = if (multi && windows.any { it.pkg == pkg }) Decision.Another else decide(pkg, windows, tasks)

    /**
     * Whether a second window of the app can be forced (the user 11-03: "we can just make the apps cooperate, we have full
     * control"): every app whose launcher activity's [launchMode] is standard, singleTop or singleInstancePerTask -
     * declared support or not: [WebWindows] launches it with NEW_TASK | MULTIPLE_TASK | NEW_DOCUMENT on the new window's
     * display, a task of its own.
     *
     * HACK: a singleTask / singleInstance launcher activity (Settings, some mail and banking apps) is always put into its
     * one existing task by ActivityStarter (getReusableTask ignores MULTIPLE_TASK for those modes), so a second window
     * would only steal the first one's task: those apps keep one window, which the page moves to the page asked for.
     * Real fix: a system_server hook (the PowOS framework module) that honours MULTIPLE_TASK from PowOS's launches for
     * those modes, then this returns true for every app.
     */
    fun multiInstance(launchMode: Int): Boolean = launchMode != LAUNCH_SINGLE_TASK && launchMode != LAUNCH_SINGLE_INSTANCE

    /** ActivityInfo.LAUNCH_SINGLE_TASK / LAUNCH_SINGLE_INSTANCE (pure: no android.jar in the JVM test). */
    const val LAUNCH_SINGLE_TASK = 2
    const val LAUNCH_SINGLE_INSTANCE = 3

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
