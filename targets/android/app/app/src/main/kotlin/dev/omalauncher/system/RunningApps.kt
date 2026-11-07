package dev.omalauncher.system

import android.app.ActivityManager
import android.content.Context
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.mutableStateOf
import dev.omalauncher.linux.LinuxApp
import dev.omalauncher.linux.matches
import org.json.JSONObject
import java.io.File

/**
 * Which apps run, for the dot under their icons (shell/ui/running.ts, "apps.running"): Android's are the apps with a
 * running task in any windowing mode (the task stack listener says when one opens or goes - [FreeformTasks.listen]); the PowOS session's
 * Linux apps, Steam and its games are what powos-sleep-gui writes to running/apps.json in the run dir whenever a
 * window comes or goes or an app freezes or thaws ({"classes": {windowClass: "running" | "frozen"}}). Nothing polls.
 */
object RunningApps {
    private const val TAG = "PowosRunning"
    private const val FILE = "apps.json"
    private const val LAUNCHES = "launches.json"
    private const val SETTLE_MS = 120L
    private const val MAX_TASKS = 64
    private const val TASKS_STAMP = "android-tasks"

    /** Packages with a running task, any windowing mode (PowOS's own aside: its tasks are Linux windows and its own screens). */
    val tasks = mutableStateOf<List<String>>(emptyList())

    /** powos-sleep-gui's running/apps.json, as it is ("{}" without a PowOS session). */
    val linux = mutableStateOf("{}")

    /**
     * SL1: powos-sleep-gui's running/launches.json, as it is - every game launch Steam runs, from PowOS's tap or Steam's
     * own UI, with its phase ({"launches": {appid: {state, phase, name, since, reason?}}}; SteamLaunches there): home's
     * page shows the launch's placeholder window from its first step ([launchesFor]).
     */
    val launches = mutableStateOf("{}")

    private val main = Handler(Looper.getMainLooper())
    private val readTasksNow =
        Runnable {
            readTasks()
            stampTasks()
        }
    private var app: Context? = null

    /** The run dir's android-tasks, bumped on every task change: powos-android-tasks re-reads the task list then. */
    private var stamp: File? = null
    private var observer: FileObserver? = null

    /** From the app's start (main process): the task listener, and the session's file under [runDir] where it runs. */
    fun start(
        context: Context,
        runDir: File?,
    ) {
        if (app != null) return
        app = context.applicationContext
        // Logged under its own tag: WindowFrames registers a listener of its own, and both log PowosFreeform's line.
        val listening =
            FreeformTasks.listen {
                main.removeCallbacks(readTasksNow)
                main.postDelayed(readTasksNow, SETTLE_MS)
            }
        Log.i(TAG, if (listening != null) "task listener on" else "task listener MISSING: the dots keep the start-up read")
        readTasks()
        runDir?.let {
            stamp = File(it, TASKS_STAMP)
            stampTasks()
            watch(File(it, "running"))
        }
    }

    /**
     * Tells the PowOS session's taskbar watcher (powos-android-tasks) that Android's tasks changed, instead of it running
     * `am stack list` every 2 s: a new file renamed into place (a directory event its QFileSystemWatcher sees).
     */
    private fun stampTasks() {
        val f = stamp ?: return
        runCatching {
            val tmp = File(f.parentFile, "$TASKS_STAMP.tmp")
            tmp.writeText(System.nanoTime().toString())
            tmp.setReadable(true, false)
            if (!tmp.renameTo(f)) tmp.delete()
        }.onFailure { Log.w(TAG, "can't write $f", it) }
    }

    private fun readTasks() {
        val c = app ?: return
        // Tasks with a live activity, whatever their windowing mode (fullscreen, freeform, split): a recents entry
        // whose activities are gone (force-stopped, swiped) is not running. The recents provider sees every user's.
        @Suppress("DEPRECATION")
        val running = runCatching { c.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        val next = running.filter { it.numActivities > 0 }.mapNotNull { (it.baseIntent.component ?: it.baseActivity ?: it.topActivity)?.packageName }.filter { it != c.packageName }.distinct()
        if (next == tasks.value) return
        Log.i(TAG, "tasks: ${next.joinToString()}")
        tasks.value = next
    }

    private fun watch(dir: File) {
        // The session writes here as its own user: the app makes the folder and lets it.
        dir.mkdirs()
        dir.setWritable(true, false)
        dir.setReadable(true, false)
        dir.setExecutable(true, false)
        val file = File(dir, FILE)
        val launchFile = File(dir, LAUNCHES)
        val o =
            object : FileObserver(dir, CLOSE_WRITE or MOVED_TO or DELETE) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path == FILE) main.post { readLinux(file) }
                    if (path == LAUNCHES) main.post { readLaunches(launchFile) }
                }
            }
        observer = o
        o.startWatching()
        readLinux(file)
        readLaunches(launchFile)
    }

    private fun readLaunches(file: File) {
        val text = runCatching { file.readText() }.getOrDefault("{}")
        if (text != launches.value) launches.value = text
    }

    /**
     * SL1: [launches] ([text]) for the page ("apps.launching"): one entry per launch, under the key its window will be
     * offered as ([linuxAppOf] of steam_app_<appid>: the entry that starts it, else "l:steam_app_<appid>") with its label
     * (that entry's name, else Steam's) - [{key, label, appid, state, phase, since, reason?}].
     */
    fun launchesFor(
        text: String,
        apps: List<LinuxApp>,
    ): org.json.JSONArray {
        val out = org.json.JSONArray()
        val all = runCatching { JSONObject(text).optJSONObject("launches") }.getOrNull() ?: return out
        for (appid in all.keys()) {
            val l = all.optJSONObject(appid) ?: continue
            val app = linuxAppOf(apps, "steam_app_$appid")
            val label = app?.name ?: l.optString("name").ifBlank { "Game" }
            val e = JSONObject().put("key", "l:${app?.id ?: "steam_app_$appid"}").put("label", label).put("appid", appid)
            for (k in listOf("state", "phase", "reason")) l.optString(k).takeIf { it.isNotEmpty() }?.let { e.put(k, it) }
            out.put(e.put("since", l.optLong("since")))
        }
        return out
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
     * The app a KWin window offered as [appId] belongs to (WebWindowSource's "open"): its desktop id, or - with no desktop
     * file (kwin 0052) - its X11 class: Steam's "steam", a Proton game's steam_app_<id> to the entry that starts it. Steam
     * opened as two windows (2026-11-02): offered as "", its window never took the launch's placeholder for "l:steam".
     */
    fun linuxAppOf(
        apps: List<LinuxApp>,
        appId: String,
    ): LinuxApp? = if (appId.isBlank()) null else apps.firstOrNull { isOf(it, appId) }

    /**
     * The other entries that start the same command as [app] (the Exec line, field codes aside): a window is any of
     * theirs too. KDE ships System Settings twice - systemsettings.desktop and kdesystemsettings.desktop, both
     * `Exec=systemsettings` - and outside a Plasma login the window names itself "kdesystemsettings": a launch from the
     * "System Settings" tile ("l:systemsettings") kept its placeholder, which then said "Couldn't open", while the
     * window opened beside it as "l:kdesystemsettings" (emulator, no root, 2026-11-04).
     */
    fun linuxSameCommand(
        apps: List<LinuxApp>,
        app: LinuxApp,
    ): List<LinuxApp> {
        val cmd = app.exec.trim()
        if (cmd.isEmpty()) return emptyList()
        return apps.filter { it.id != app.id && it.exec.trim() == cmd }
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
