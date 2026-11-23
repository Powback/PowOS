package dev.omalauncher.system

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
        val label: String,
    )

    /**
     * The pair for [dragged] docked on [side] with [other] on the other side ([labels]: package -> app name), for user
     * [userId]. Pure: JVM-tested (CanvasDockTest).
     */
    fun plan(
        dragged: String,
        other: String,
        side: Side,
        userId: Int,
        labels: Map<String, String> = emptyMap(),
    ): Plan {
        val order = if (side == Side.LEFT) listOf(dragged, other) else listOf(other, dragged)
        return Plan(
            order,
            mapOf(
                KEY_COMBINATION to true,
                KEY_USER_IDS to IntArray(order.size) { userId },
                KEY_ORIENTATION to SIDE_BY_SIDE,
            ),
            order.joinToString(" | ") { labels[it] ?: it.substringAfterLast('.') },
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
     * Task [id]'s app docked on [side], task [other]'s app on the other side, in Open Canvas (path A, class doc). The
     * shortcut stays published (re-pushed each dock; PowosShortcuts.publish may replace it - it's only ever started here).
     */
    fun dock(
        context: Context,
        id: Int,
        side: Side,
        other: Int,
    ): Result {
        why(context)?.let { return Result(false, it) }
        if (id == other) return Result(false, "Pick two different apps")
        val tasks = Tasks.list(context)
        val pkgs = listOf(id, other).map { t -> tasks.firstOrNull { it.id == t }?.component?.packageName ?: return Result(false, "That app isn't open anymore") }
        if (pkgs.any { it == context.packageName }) return Result(false, "PowOS itself can't be a side of split view")
        val pm = context.packageManager
        val labels = pkgs.associateWith { p -> runCatching { pm.getApplicationLabel(pm.getApplicationInfo(p, 0)).toString() }.getOrDefault(p) }
        val plan = plan(pkgs[0], pkgs[1], side, android.os.Process.myUserHandle().hashCode(), labels)
        val intents =
            plan.packages.map { p ->
                (pm.getLaunchIntentForPackage(p) ?: return Result(false, "${labels[p]} can't be opened in split view"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        val before = plan.packages.associateWith { p -> tasks.firstOrNull { it.component?.packageName == p }?.id }
        val info =
            ShortcutInfo.Builder(context, SHORTCUT_ID)
                .setShortLabel(plan.label)
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
        measure(context.applicationContext, before)
        return Result(true)
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
    ) {
        Thread {
            Thread.sleep(2500)
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
