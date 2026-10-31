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
    }

    fun decide(
        pkg: String,
        windows: List<Window>,
        tasks: List<Task>,
    ): Decision {
        windows.firstOrNull { it.pkg == pkg }?.let { return Decision.Reuse(it.id, it.task) }
        val windowDisplays = windows.map { it.display }.filter { it >= 0 }.toSet()
        val windowTasks = windows.map { it.task }.filter { it >= 0 }.toSet()
        val t =
            tasks.firstOrNull {
                it.display >= 0 && it.display !in windowDisplays && it.id !in windowTasks && (it.basePkg == pkg || it.topPkg == pkg)
            } ?: return Decision.New
        return Decision.Adopt(t.id)
    }
}
