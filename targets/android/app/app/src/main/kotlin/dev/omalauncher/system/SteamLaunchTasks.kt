package dev.omalauncher.system

import android.content.ComponentCallbacks
import android.content.Context
import android.content.res.Configuration
import android.util.Log
import androidx.compose.runtime.mutableStateOf
import dev.omalauncher.linux.LinuxApp
import org.json.JSONObject

/**
 * SL1 folded (the coordinator 11-07, the user's "full android linux HYBRID ... perfectly integrated"): a game Steam
 * launches (its own UI or PowOS's tap) where its window will be an Android task - folded (the cover screen), or web
 * windows off - shows the PowOS launch window AT ONCE: the game's own full-screen task (andro.marchy.LaunchWindows,
 * game mode) with its icon, name and Steam's phase, which the game's X window becomes when it maps (the same task, no
 * second one, no flash). Ended before its window: "couldn't start" with why and a close; Steam asking something: it
 * steps back so Steam's window shows. Unfolded (web windows) home's page shows the placeholder instead
 * (webwindows.tsx steamLaunches); a fold mid-launch opens the task ([refresh] on the configuration change) and the
 * page's placeholder goes ([held] -> "task" in apps.launching); an unfold mid-launch keeps the task, which the game's
 * window still takes (WindowTasks: a launch window claims it before a web window).
 */
object SteamLaunchTasks {
    private const val TAG = "SteamLaunchTasks"

    /** How old a launch may be to get a launch window (webwindows.tsx STEAM_START): not one from before a restart. */
    const val START_MS = 180_000L

    /** One launch from running/launches.json, under the app id its window will carry. */
    data class Launch(
        val appid: String,
        val since: Long,
        val state: String,
        val phase: String?,
        val reason: String?,
        /** The app id of its launch window: the drawer entry that starts it, else steam_app_<appid>. */
        val appId: String,
        val label: String,
        /** The ids its window may carry (LaunchWindows' EXTRA_IDS). */
        val ids: List<String>,
    ) {
        val token get() = "$appid@$since"
    }

    /** What to do for one launch ([plan]). */
    enum class Act { OPEN, PHASE, FAIL, ASK, RESUME }

    /** The launches ([Launch.token]) a launch window holds (opened by this, or the game's window got a task): home's page leaves them. */
    val held = mutableStateOf<Set<String>>(emptySet())

    private val asking = mutableSetOf<String>()
    private var last: List<Launch> = emptyList()
    private var app: Context? = null

    fun parse(
        text: String,
        apps: List<LinuxApp>,
    ): List<Launch> {
        val all = runCatching { JSONObject(text).optJSONObject("launches") }.getOrNull() ?: return emptyList()
        return all.keys().asSequence().mapNotNull { appid ->
            val l = all.optJSONObject(appid) ?: return@mapNotNull null
            val entry = RunningApps.linuxAppOf(apps, "steam_app_$appid")
            val ids = (listOfNotNull(entry?.id, entry?.wmClass) + entry?.aliases.orEmpty() + "steam_app_$appid").filter { it.isNotBlank() }.distinct()
            Launch(
                appid,
                l.optLong("since"),
                l.optString("state"),
                l.optString("phase").ifEmpty { null },
                l.optString("reason").ifEmpty { null },
                entry?.id ?: "steam_app_$appid",
                entry?.name ?: l.optString("name").ifBlank { "Game" },
                ids,
            )
        }.toList()
    }

    /**
     * What each launch needs ([launches]; [tasks]: its window becomes a task here - folded, web windows off; [hasWindow]:
     * the game shows a window already; [now] ms): a launch window for a new one going on, its phase, its failure, Steam's
     * question on and off. Pure: the JVM test's.
     */
    /** Where [plan] stands: [tasks] (a window becomes a task here), the launches [held] and [asking], [now] (ms). */
    data class Where(
        val tasks: Boolean,
        val held: Set<String>,
        val asking: Set<String>,
        val now: Long,
    )

    fun plan(
        launches: List<Launch>,
        where: Where,
        hasWindow: (Launch) -> Boolean,
    ): List<Pair<Act, Launch>> = launches.mapNotNull { l -> (if (l.token in where.held) heldAct(l, where) else newAct(l, where, hasWindow))?.let { it to l } }

    /** A launch its launch window holds: Steam's step, its question on / off, its end. */
    private fun heldAct(
        l: Launch,
        where: Where,
    ): Act? {
        val asked = l.token in where.asking
        return when {
            l.state == "ended" -> Act.FAIL
            l.state == "asking" && !asked -> Act.ASK
            l.state != "asking" && asked -> Act.RESUME
            l.state in GOING -> Act.PHASE
            else -> null
        }
    }

    private val GOING = setOf("launching", "running", "asking")

    /** A launch no launch window holds: one opens for it when its window will be a task and it goes on, fresh, windowless. */
    private fun newAct(
        l: Launch,
        where: Where,
        hasWindow: (Launch) -> Boolean,
    ): Act? {
        val fresh = where.now - l.since * 1000 <= START_MS
        return if (where.tasks && (l.state == "launching" || l.state == "running") && fresh && !hasWindow(l)) Act.OPEN else null
    }

    /** Home's bridge, on every launches.json change ([launches]) - also again on a fold / unfold ([refresh]). Main thread. */
    fun update(
        context: Context,
        launches: List<Launch>,
    ) {
        start(context)
        last = launches
        val tasks = !andro.marchy.WebWindowSource.wanted()
        val live = launches.map { it.token }.toSet()
        if (!live.containsAll(held.value)) held.value = held.value intersect live
        asking.retainAll(live)
        for ((act, l) in plan(launches, Where(tasks, held.value, asking.toSet(), System.currentTimeMillis())) { andro.marchy.WindowTasks.hasWindow(it.ids.toTypedArray()) }) {
            run(context, act, l)
        }
    }

    /** [act] for launch [l] on its launch window (andro.marchy.LaunchWindows). */
    private fun run(
        context: Context,
        act: Act,
        l: Launch,
    ) {
        when (act) {
            Act.OPEN ->
                if (andro.marchy.LaunchWindows.open(context, l.appId, l.ids.toTypedArray(), l.label, true, l.phase)) {
                    Log.i(TAG, "${l.label} (${l.appid}): its launch window at ${l.phase ?: l.state}")
                    held.value = held.value + l.token
                }
            Act.PHASE -> andro.marchy.LaunchWindows.phase(l.appId, l.phase)
            Act.FAIL -> andro.marchy.LaunchWindows.failed(l.appId, l.reason)
            Act.ASK -> asking.add(l.token).also { andro.marchy.LaunchWindows.asking(context, l.appId, true) }
            Act.RESUME -> asking.remove(l.token).also { andro.marchy.LaunchWindows.asking(context, l.appId, false) }
        }
    }

    /** A game's window opened as a task (WindowTasks.taskOpened, [appId]): its launch is the task's - home's page leaves it. */
    fun taskOpened(appId: String) {
        val l = last.firstOrNull { appId.isNotEmpty() && (appId in it.ids || appId == it.appId) } ?: return
        if (l.token !in held.value) held.value = held.value + l.token
    }

    /** The fold / unfold: where the next window goes changed - the launches again. */
    private fun refresh() {
        val c = app ?: return
        if (last.isNotEmpty()) update(c, last)
    }

    private fun start(context: Context) {
        if (app != null) return
        val a = context.applicationContext
        app = a
        andro.marchy.WindowTasks.taskOpened = java.util.function.Consumer { id -> android.os.Handler(android.os.Looper.getMainLooper()).post { taskOpened(id) } }
        a.registerComponentCallbacks(
            object : ComponentCallbacks {
                override fun onConfigurationChanged(newConfig: Configuration) {
                    android.os.Handler(android.os.Looper.getMainLooper()).post { refresh() }
                }

                @Deprecated("ComponentCallbacks")
                override fun onLowMemory() {}
            },
        )
    }
}
