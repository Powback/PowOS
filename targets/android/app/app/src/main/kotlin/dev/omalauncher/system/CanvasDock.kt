package dev.omalauncher.system

import android.app.ActivityManager
import android.app.TaskInfo
import android.content.Context
import android.content.Intent
import android.content.pm.LauncherApps
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.os.Bundle
import android.os.PersistableBundle
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * The switcher's dock (shell/ui/carddock.ts): a card dragged up and toward a side goes into OxygenOS's Open Canvas
 * (com.oplus.pscanvas, the native split view) on that side, the newest other app on the other. The user, 11-23: "drag
 * a window up and to the side it should be docked to that side ... the split view native thing that we're
 * decompiling". Not PowOS's desktop split, not WM Shell's split.
 *
 * Path A of docs/research/pscanvas.md ("Driving Open Canvas from PowOS"), the one that needs no Oplus permission:
 * PowOS, the default launcher (shortcut host), publishes one dynamic "app pair" shortcut - its intents in on-screen
 * order (intent 0 left, intent 1 right), extras isPsSplitScreenCombination=true, userIds, androidx.flexible.
 * layoutOrientation 2 (side by side) - and starts it with LauncherApps.startShortcut. system_server
 * (OplusPairTaskManager -> OplusSplitScreenManagerService.startPocketStudio) makes the privileged canvas start.
 *
 * HACK: started by INTENT (task ids -1): whether pscanvas reuses each app's running task (its state) or starts it
 * fresh is OxygenOS's, unread until the pscanvas APK is decompiled - [dock] logs it on every dock ("reused" / "new
 * task", `logcat -s PowosCanvasDock`). Real fix if they restart: path B, FlexibleWindowManager.startPocketStudio with
 * androidx.flexible.taskIdList (the dragged task itself), which needs com.oplus.permission.safe.WINDOW - a priv-app
 * allowlist in PowOS's Magisk module if that permission is privileged (user OK first).
 */
object CanvasDock {
    private const val TAG = "PowosCanvasDock"
    const val SHORTCUT_ID = "powos-canvas-pair"
    const val CANVAS_PACKAGE = "com.oplus.pscanvas"
    const val FEATURE = "oplus.software.pocketstudio.support"
    private const val FWM = "com.oplus.flexiblewindow.FlexibleWindowManager"

    /** OxygenOS's keys (oplus-framework / OplusPairTaskManager), read from the shortcut's extras. */
    const val KEY_COMBINATION = "isPsSplitScreenCombination"
    const val KEY_USER_IDS = "userIds"
    const val KEY_ORIENTATION = "androidx.flexible.layoutOrientation"

    /** CanvasCalculateLayoutRect.twoSplitLayout: 2 side by side, 1 one over the other. */
    const val SIDE_BY_SIDE = 2

    enum class Side { LEFT, RIGHT }

    /** A dock to start: the packages in canvas order (0 = left), and the shortcut's extras. */
    data class Plan(
        val packages: List<String>,
        val extras: Map<String, Any>,
    ) {
        /** The shortcut's label: the apps' names ([labels]: package -> name) in canvas order. */
        fun label(labels: Map<String, String>) = packages.joinToString(" | ") { labels[it] ?: it.substringAfterLast('.') }
    }

    /** The pair for [dragged] docked on [side] with [other] on the other side, for user [userId]. Pure: CanvasDockTest. */
    fun plan(
        dragged: String,
        other: String,
        side: Side,
        userId: Int,
    ): Plan {
        val order = if (side == Side.LEFT) listOf(dragged, other) else listOf(other, dragged)
        return Plan(
            order,
            mapOf(
                KEY_COMBINATION to true,
                KEY_USER_IDS to IntArray(order.size) { userId },
                KEY_ORIENTATION to SIDE_BY_SIDE,
            ),
        )
    }

    /** The answer to the page (types.ts CanvasDockResult). */
    data class Result(val ok: Boolean, val reason: String? = null)

    /** Open Canvas can take a dock now: unfolded inner screen, OxygenOS's canvas there, PowOS the shortcut host. */
    fun available(context: Context): Boolean = why(context) == null

    /** Why not ([available]), in words for the user; null: it can. */
    fun why(context: Context): String? {
        if (AppWindows.smallestDp(context) < 600) return "Split view docking works on the unfolded screen"
        if (!supported(context)) return "This phone has no Open Canvas"
        if (systemProperty("persist.sys.pair_split_feature_enable") == "false") return "App pairs are off on this phone"
        val la = context.getSystemService(LauncherApps::class.java) ?: return "No launcher service"
        if (!runCatching { la.hasShortcutHostPermission() }.getOrDefault(false)) return "PowOS needs to be the default home app"
        return null
    }

    /** OxygenOS's feature (also as FlexibleWindowManager reads it), and the canvas app installed. */
    private fun supported(context: Context): Boolean {
        val pm = context.packageManager
        val installed = runCatching { pm.getApplicationInfo(CANVAS_PACKAGE, 0) }.isSuccess
        if (!installed) return false
        if (pm.hasSystemFeature(FEATURE)) return true
        return fwm("isSupportPocketStudio", Context::class.java to context) as? Boolean ?: false
    }

    /**
     * Whether an app with this task can be a side of Open Canvas, or why not (in words for the user) - pure, CanvasDockTest.
     * [flags]: the task's TaskInfo split flags as read ([splitFlags]; a missing one is unknown, not a no). OxygenOS
     * puts its split blocklist (11-23 logcat: "com.android.settings unSupportsSplitScreen by blockList or
     * ForbidActivityList") into supportsSplitScreenMultiWindow / supportsPocketStudioMultiWindow, so either false = no.
     */
    fun sideVerdict(
        pkg: String?,
        label: String,
        own: String,
        flags: Map<String, Boolean?>,
    ): String? =
        when {
            pkg == null -> "That app isn't open anymore"
            pkg == own -> "PowOS itself can't be a side of split view"
            SPLIT_FLAGS.any { flags[it] == false } -> "$label can't be used in split view"
            else -> null
        }

    /** The TaskInfo fields [sideVerdict] reads (OxygenOS's own first). */
    val SPLIT_FLAGS = listOf("supportsPocketStudioMultiWindow", "supportsSplitScreenMultiWindow", "supportsMultiWindow")

    /** [t]'s split flags (hidden fields, HiddenApi exempts TaskInfo); a field this build doesn't have: absent. */
    private fun splitFlags(t: TaskInfo): Map<String, Boolean?> =
        liveFlags(SPLIT_FLAGS.associateWith { f -> runCatching { t.javaClass.getField(f).getBoolean(t) }.getOrNull() }, t.numActivities)

    /**
     * The split flags worth reading for a task with [activities] running activities: all of them for a live task, none
     * (unknown, never a no) for a task with none - a recent task whose process is gone reports false for
     * supportsMultiWindow and supportsSplitScreenMultiWindow whatever the app (11-23 20:20 logcat: Discord's cached task
     * 3936, numActivities=0, both false; the live tasks of the same apps true). That false read was the wrong "Discord
     * can't be used in split view" - Discord is on no inner-screen blocklist (sys_wms_split_app_ps.xml lists it 1:0:0:
     * bar phones and the cover screen only). OxygenOS still refuses a really blocked app at the start, and [dock]'s
     * check-back brings the dragged app back with a note then. Pure: CanvasDockTest.
     */
    fun liveFlags(
        flags: Map<String, Boolean?>,
        activities: Int,
    ): Map<String, Boolean?> = if (activities > 0) flags else emptyMap()

    /** A recent task as the dock reads it: package, label, split flags. */
    private data class Recent(val id: Int, val pkg: String?, val label: String, val flags: Map<String, Boolean?>)

    private fun recent(context: Context): List<Recent> {
        val am = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        val pm = context.packageManager
        @Suppress("DEPRECATION")
        val tasks = runCatching { am.getRecentTasks(40, ActivityManager.RECENT_IGNORE_UNAVAILABLE) }.getOrNull().orEmpty()
        return tasks.map { t ->
            val pkg = (t.baseIntent.component ?: t.baseActivity ?: t.topActivity)?.packageName
            val label = pkg?.let { p -> runCatching { pm.getApplicationLabel(pm.getApplicationInfo(p, 0)).toString() }.getOrNull() } ?: pkg ?: "That app"
            Recent(t.taskId, pkg, label, splitFlags(t))
        }
    }

    /** Why task [s] can't be a side ([sideVerdict]), plus: it needs a launch intent (the shortcut starts it by intent). */
    private fun whyNotSide(
        context: Context,
        s: Recent,
    ): String? =
        sideVerdict(s.pkg, s.label, context.packageName, s.flags)
            ?: if (context.packageManager.getLaunchIntentForPackage(s.pkg!!) == null) "${s.label} can't be opened in split view" else null

    /**
     * The recent task ids that can be a side of Open Canvas now (the switcher's partner pick and its "can't be used in
     * split view" note, tasks.canvasSides). Those left out are logged with why, once per answer.
     */
    fun sides(context: Context): List<Int> {
        val all = recent(context)
        val out = all.associateWith { whyNotSide(context, it) }
        val left = out.filterValues { it != null }.entries.joinToString(", ") { (s, why) -> "${s.id} ${s.pkg}: $why" }
        Log.i(TAG, "sides: ${out.filterValues { it == null }.keys.map { it.id }}; not: $left")
        return out.filterValues { it == null }.keys.map { it.id }
    }

    /**
     * Task [id]'s app docked on [side], task [other]'s app on the other side, in Open Canvas (path A, class doc). The
     * shortcut stays published (re-pushed each dock; PowosShortcuts.publish may replace it - it's only ever started here).
     * Every refusal is logged with its reason (`logcat -s PowosCanvasDock`) and goes to the page, which shows it.
     */
    fun dock(
        context: Context,
        id: Int,
        side: Side,
        other: Int,
    ): Result {
        Log.i(TAG, "dock task $id ($side) beside $other asked")
        return start(context, id, side, other).also { if (!it.ok) Log.w(TAG, "dock task $id ($side) beside $other refused: ${it.reason}") }
    }

    private fun start(
        context: Context,
        id: Int,
        side: Side,
        other: Int,
    ): Result {
        why(context)?.let { return Result(false, it) }
        if (id == other) return Result(false, "Pick two different apps")
        val tasks = recent(context)
        val pair = listOf(id, other).map { t -> tasks.firstOrNull { it.id == t } ?: return Result(false, "That app isn't open anymore") }
        pair.firstNotNullOfOrNull { whyNotSide(context, it) }?.let { return Result(false, it) }
        val pkgs = pair.map { it.pkg!! }
        val labels = pair.associate { it.pkg!! to it.label }
        val pm = context.packageManager
        val plan = plan(pkgs[0], pkgs[1], side, android.os.Process.myUserHandle().hashCode())
        val intents = plan.packages.map { p -> pm.getLaunchIntentForPackage(p)!!.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        val before = plan.packages.associateWith { p -> tasks.firstOrNull { it.pkg == p }?.id }
        val info =
            ShortcutInfo.Builder(context, SHORTCUT_ID)
                .setShortLabel(plan.label(labels))
                .setIntents(intents.toTypedArray())
                .setExtras(persistable(plan.extras))
                .build()
        val sm = context.getSystemService(ShortcutManager::class.java) ?: return Result(false, "No shortcut service")
        val la = context.getSystemService(LauncherApps::class.java) ?: return Result(false, "No launcher service")
        val ok =
            runCatching {
                sm.pushDynamicShortcut(info)
                // The same keys in the start's options too (OplusPairTaskManager merges the shortcut's extras into them).
                val opts = Bundle().apply { putInt(KEY_ORIENTATION, SIDE_BY_SIDE) }
                la.startShortcut(context.packageName, SHORTCUT_ID, null, opts, android.os.Process.myUserHandle())
            }.onFailure { Log.w(TAG, "dock ${plan.packages}: start failed", it) }.isSuccess
        if (!ok) return Result(false, "Split view didn't open")
        Switcher.launched("canvas dock ${plan.packages.joinToString(" | ")}")
        Log.i(TAG, "dock task $id ($side) beside $other: shortcut started, canvas ${plan.packages.joinToString(" | ")}, tasks before $before")
        measure(context.applicationContext, before, Dragged(pair[0].pkg!!, id, pair[0].label))
        return Result(true)
    }

    /** OxygenOS's FlexibleWindowManager is there (read once: the window code asks on every task event). */
    private val hasFwm by lazy { runCatching { Class.forName(FWM) }.isSuccess }

    /** Open Canvas's own container task (com.oplus.pscanvas): the split view itself, never a stray app to float. */
    fun isCanvas(pkg: String?): Boolean = pkg == CANVAS_PACKAGE

    /** The task ids Open Canvas holds now (its regions; empty when none or not readable). */
    fun canvasTasks(): Set<Int> = if (!hasFwm) emptySet() else runCatching { regions(fwm("getPocketStudioTaskRegion", Int::class.javaPrimitiveType!! to 0)).keys().asSequence().mapNotNull { it.toIntOrNull() }.toSet() }.getOrDefault(emptySet())

    /**
     * Task [id] (package [pkg]) belongs to Open Canvas - its container or a side of it: PowOS's window adopt and floating
     * hand-over leave it alone. Before this, adopt took the canvas container (a full-screen standard task on display 0)
     * as a stray app and moved it into a web window (window-log 11-23 17:58:36: "task 3940 (com.oplus.pscanvas) was full
     * screen: now a web window"); every later dock reused that container (20:20:21, task 3940 again), so the dragged app
     * went into a canvas off the screen - "when I activate it, it's like hiding the app".
     */
    fun owns(
        id: Int,
        pkg: String?,
    ): Boolean = isCanvas(pkg) || id in canvasTasks()

    /** The app a dock was dragged for: its package, its task before the dock, its name. */
    private data class Dragged(val pkg: String, val task: Int, val label: String)

    /** What the check-back after a dock does - pure, CanvasDockTest. */
    enum class Outcome { DOCKED, UNKNOWN, LOST }

    /**
     * The dock as read back: [inCanvas] (isInPocketStudio(0)), [canvasTasks] (its regions' task ids) and the dragged
     * app's task ids ([dragged]: before and now). DOCKED: a region holds it; LOST: no canvas, or a canvas without it;
     * UNKNOWN: a canvas whose regions can't be read (never pulled out of a canvas on a guess).
     */
    fun outcome(
        inCanvas: Boolean,
        canvasTasks: Set<Int>,
        dragged: Set<Int>,
    ): Outcome =
        when {
            dragged.any { it in canvasTasks } -> Outcome.DOCKED
            inCanvas && canvasTasks.isEmpty() -> Outcome.UNKNOWN
            else -> Outcome.LOST
        }

    /**
     * The dragged app is never lost (the user, 11-23: "When I activate it, it's like hiding the app"): read back 2.5 s
     * after the start (once more 1.5 s later while the canvas may still be settling); not in a canvas region then, it is
     * brought back as it was (its task from recents, else started again) and a note says split view didn't open.
     */
    private fun checkBack(
        context: Context,
        dragged: Dragged,
    ) {
        val (pkg, task, label) = dragged
        var o = Outcome.UNKNOWN
        for (wait in listOf(0L, 1500L)) {
            if (wait > 0) Thread.sleep(wait)
            val now = Tasks.list(context).filter { it.component?.packageName == pkg }.map { it.id }.toSet()
            val inCanvas = fwm("isInPocketStudio", Int::class.javaPrimitiveType!! to 0) as? Boolean ?: false
            o = outcome(inCanvas, canvasTasks(), now + task)
            if (o == Outcome.DOCKED) break
        }
        Log.i(TAG, "dock of $pkg (task $task): $o")
        if (o != Outcome.LOST) return
        val back = Tasks.list(context).firstOrNull { it.id == task } != null && Tasks.open(context, task)
        if (!back) runCatching { context.startActivity(context.packageManager.getLaunchIntentForPackage(pkg)!!.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        Log.w(TAG, "dock of $pkg (task $task): not in the canvas - brought back (${if (back) "its task" else "started again"})")
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            android.widget.Toast.makeText(context, "Split view didn't open - $label is back", android.widget.Toast.LENGTH_LONG).show()
        }
    }

    /** The last dock's task ids per package, before and in the canvas (null: none yet) - for the verify check. */
    @Volatile
    var lastDock: JSONObject? = null
        private set

    /**
     * 2.5 s after a dock: Open Canvas's regions read back, each app's task id before vs. in the canvas - "reused" (its
     * state kept) or "new task" (pscanvas started it fresh). The HACK in the class doc depends on this line.
     */
    private fun measure(
        context: Context,
        before: Map<String, Int?>,
        dragged: Dragged,
    ) {
        Thread {
            Thread.sleep(2500)
            checkBack(context, dragged)
            val s = state()
            val inCanvas = s?.optJSONObject("regions")?.keys()?.asSequence()?.mapNotNull { it.toIntOrNull() }?.toSet().orEmpty()
            val now = Tasks.list(context)
            val after = before.keys.associateWith { p -> now.firstOrNull { it.component?.packageName == p }?.id }
            val verdict =
                before.entries.joinToString(", ") { (p, was) ->
                    val note =
                        when {
                            was == null -> "had no task"
                            was in inCanvas -> "reused (task $was in the canvas)"
                            else -> "new task (was $was, canvas has $inCanvas, recents now ${after[p]})"
                        }
                    "$p $note"
                }
            Log.i(TAG, "dock result: inCanvas=${s?.optBoolean("inCanvas")} $verdict")
            lastDock =
                JSONObject()
                    .put("before", JSONObject(before.mapValues { it.value ?: JSONObject.NULL }))
                    .put("after", JSONObject(after.mapValues { it.value ?: JSONObject.NULL }))
                    .put("canvasTasks", JSONArray(inCanvas.toList()))
                    .put("verdict", verdict)
        }.apply { name = "canvas-dock-measure" }.start()
    }

    /**
     * Open Canvas as it stands, through FlexibleWindowManager's no-permission reads (display 0): inCanvas, minimized
     * (the "pick a second app" state) and each task's region (task id -> [l, t, r, b]); null where there's no
     * FlexibleWindowManager (not OxygenOS). types.ts CanvasState, plus the last dock's measurement.
     */
    fun state(): JSONObject? {
        if (runCatching { Class.forName(FWM) }.isFailure) return null
        val o = JSONObject()
        o.put("inCanvas", fwm("isInPocketStudio", Int::class.javaPrimitiveType!! to 0) as? Boolean ?: false)
        o.put("minimized", fwm("isMinimizedPocketStudio", Int::class.javaPrimitiveType!! to 0) as? Boolean ?: false)
        o.put("regions", regions(fwm("getPocketStudioTaskRegion", Int::class.javaPrimitiveType!! to 0)))
        lastDock?.let { o.put("lastDock", it) }
        return o
    }

    /** getPocketStudioTaskRegion's answer (a Map or a Bundle of task id -> Rect, by build) as JSON. */
    private fun regions(r: Any?): JSONObject {
        val out = JSONObject()
        fun put(
            k: Any?,
            v: Any?,
        ) {
            val rect = v as? android.graphics.Rect ?: return
            out.put(k.toString(), JSONArray(listOf(rect.left, rect.top, rect.right, rect.bottom)))
        }
        when (r) {
            is Map<*, *> -> r.forEach { (k, v) -> put(k, v) }
            is Bundle -> r.keySet().forEach { k -> @Suppress("DEPRECATION") put(k, r.get(k)) }
            null -> {}
            else -> Log.i(TAG, "region read: unknown type ${r.javaClass.name}: $r")
        }
        return out
    }

    /** FlexibleWindowManager's [name]([arg]): a static method, else on getInstance(); null when it's not there. */
    private fun fwm(
        name: String,
        arg: Pair<Class<*>, Any>,
    ): Any? =
        runCatching {
            val c = Class.forName(FWM)
            val m = c.getMethod(name, arg.first)
            val target = if (java.lang.reflect.Modifier.isStatic(m.modifiers)) null else c.getMethod("getInstance").invoke(null)
            m.invoke(target, arg.second)
        }.onFailure { Log.d(TAG, "FlexibleWindowManager.$name: $it") }.getOrNull()

    private fun systemProperty(key: String): String? =
        runCatching { Class.forName("android.os.SystemProperties").getMethod("get", String::class.java).invoke(null, key) as String }.getOrNull()

    private fun persistable(m: Map<String, Any>) =
        PersistableBundle().apply {
            m.forEach { (k, v) ->
                when (v) {
                    is Boolean -> putBoolean(k, v)
                    is Int -> putInt(k, v)
                    is IntArray -> putIntArray(k, v)
                    is String -> putString(k, v)
                }
            }
        }
}
