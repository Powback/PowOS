package dev.omalauncher.system

import android.content.Context
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.mutableStateOf
import dev.omalauncher.linux.LinuxApp
import dev.omalauncher.linux.matches
import org.json.JSONObject
import java.io.File

/**
 * Which apps run, for the dot under their icons (shell/ui/running.ts, "apps.running"): Android's are the apps with a
 * task in recents (the task stack listener says when one opens or goes - [FreeformTasks.listen]); the PowOS session's
 * Linux apps, Steam and its games are what powos-sleep-gui writes to running/apps.json in the run dir whenever a
 * window comes or goes or an app freezes or thaws ({"classes": {windowClass: "running" | "frozen"}}). Nothing polls.
 */
object RunningApps {
    private const val FILE = "apps.json"
    private const val SETTLE_MS = 120L

    /** Packages with a task in recents (PowOS's own aside: its tasks are Linux windows and its own screens). */
    val tasks = mutableStateOf<List<String>>(emptyList())

    /** powos-sleep-gui's running/apps.json, as it is ("{}" without a PowOS session). */
    val linux = mutableStateOf("{}")

    private val main = Handler(Looper.getMainLooper())
    private val readTasksNow = Runnable { readTasks() }
    private var app: Context? = null
    private var observer: FileObserver? = null

    /** From the app's start (main process): the task listener, and the session's file under [runDir] where it runs. */
    fun start(
        context: Context,
        runDir: File?,
    ) {
        if (app != null) return
        app = context.applicationContext
        FreeformTasks.listen {
            main.removeCallbacks(readTasksNow)
            main.postDelayed(readTasksNow, SETTLE_MS)
        }
        readTasks()
        runDir?.let { watch(File(it, "running")) }
    }

    private fun readTasks() {
        val c = app ?: return
        val next = runCatching { Tasks.list(c) }.getOrDefault(emptyList()).mapNotNull { it.component?.packageName }.filter { it != c.packageName }.distinct()
        if (next != tasks.value) tasks.value = next
    }

    private fun watch(dir: File) {
        // The session writes here as its own user: the app makes the folder and lets it.
        dir.mkdirs()
        dir.setWritable(true, false)
        dir.setReadable(true, false)
        dir.setExecutable(true, false)
        val file = File(dir, FILE)
        val o =
            object : FileObserver(dir, CLOSE_WRITE or MOVED_TO or DELETE) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path == FILE) main.post { readLinux(file) }
                }
            }
        observer = o
        o.startWatching()
        readLinux(file)
    }

    private fun readLinux(file: File) {
        val text = runCatching { file.readText() }.getOrDefault("{}")
        if (text != linux.value) linux.value = text
    }

    private val STEAM_GAME = Regex("steam_app_(\\d+)")

    /** Whether a window of [cls] is [app]'s: its own (desktop id, StartupWMClass), or the Steam game its entry starts. */
    fun isOf(
        app: LinuxApp,
        cls: String,
    ): Boolean {
        if (app.matches(cls)) return true
        val appid = STEAM_GAME.matchEntire(cls.lowercase())?.groupValues?.get(1) ?: return false
        return app.exec.contains("rungameid/$appid")
    }

    /**
     * The page's map, app key -> "running" | "frozen": "a:<key>" for every installed app with a task, "l:<id>" for
     * each Linux app with a window (a running one wins over a frozen one of the same app).
     */
    fun shellMap(
        android: List<Pair<String, String>>,
        linuxApps: List<LinuxApp>,
    ): JSONObject {
        val out = JSONObject()
        val pkgs = tasks.value.toSet()
        android.filter { it.second in pkgs }.forEach { out.put("a:${it.first}", "running") }
        val classes = runCatching { JSONObject(linux.value).optJSONObject("classes") }.getOrNull() ?: return out
        for (cls in classes.keys()) {
            val app = linuxApps.firstOrNull { isOf(it, cls) } ?: continue
            val key = "l:${app.id}"
            if (out.optString(key) != "running") out.put(key, classes.optString(cls, "running"))
        }
        return out
    }
}
