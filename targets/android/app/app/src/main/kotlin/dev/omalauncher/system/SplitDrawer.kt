package dev.omalauncher.system

import android.app.ActivityManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.util.Log

/**
 * The split screen's edge drawer: dragging WM Shell's split divider all the way to an edge tucks that side's app into
 * a drawer on that edge instead of sending it away (the user, 2026-10-29: "When I drag the split screen thing all the
 * way to the left, it's like closing the split screen instead of putting it inside of a drawer or something").
 *
 * WM Shell still dismisses the split (StageCoordinator, EXIT_REASON_DRAG_DIVIDER): the other app goes full width and
 * the dragged-over one goes to the background, alive. PowOS remembers it per edge (one per edge), [EdgeGestures] draws
 * a tab on that edge, and a swipe in from the tab brings it back: a short pull re-enters the split on its own side at
 * its previous ratio (ISplitScreen.startTasks, as [Tasks.split]); a long pull (past [FLOAT_PULL] of the screen) opens it
 * as a floating window.
 *
 * How the dismissal is seen: WM Shell's ISplitScreen.registerSplitScreenListener (this phone's SystemUI: transaction 2;
 * ISplitScreenListener.onStagePositionChanged(int stage, int position) = 1, onTaskStageChanged(int taskId, int stage,
 * boolean visible) = 2; read off SystemUI.apk with dexdump). The listener doesn't carry the exit reason, so it's told
 * apart by the outcome [SETTLE_MS] after both tasks leave their stages: one of them visible full screen and the other
 * not visible but still alive is a divider drag to the edge (going home hides both; closing an app removes its task).
 *
 * HACK: ISplitScreen / ISplitScreenListener are WM Shell's hidden AIDL, not in the SDK: the listener stub and the
 * register call are written by hand as the generated AIDL would. Real fix: none for an app (Quickstep compiles against
 * the platform's copy). HACK: the exit reason is inferred, not read; real fix: none (WM Shell keeps it to itself; its
 * only outlet is ProtoLog).
 */
object SplitDrawer {
    private const val TAG = "PowosSplitDrawer"
    private const val SPLIT_SCREEN = "com.android.wm.shell.splitscreen.ISplitScreen"
    private const val LISTENER = "com.android.wm.shell.splitscreen.ISplitScreenListener"
    private const val REGISTER_LISTENER = 2
    private const val ON_STAGE_POSITION_CHANGED = IBinder.FIRST_CALL_TRANSACTION
    private const val ON_TASK_STAGE_CHANGED = IBinder.FIRST_CALL_TRANSACTION + 1
    private const val STAGE_UNDEFINED = -1

    /** WM Shell's exit transition has finished by then: who is visible is the outcome. */
    private const val SETTLE_MS = 700L

    /** While split, the divider's ratio is read this often (the drag to the edge itself only lands at its end). */
    private const val SAMPLE_MS = 2500L

    /** A pull further in than this share of the screen width floats the app instead of splitting. */
    const val FLOAT_PULL = 0.4f

    /** A tucked app: [side] is Tasks.SPLIT_POSITION_*; [share] the screen share it had in the split. */
    data class Tuck(val task: Int, val pkg: String?, val side: Int, val share: Float, val kept: Int)

    private val main = Handler(Looper.getMainLooper())
    private var context: Context? = null
    private var registeredOn: IBinder? = null

    /** Called (main thread) when a tuck comes or goes: the edge handles redraw. */
    var onChange: (() -> Unit)? = null

    private val tucked = arrayOfNulls<Tuck>(2)

    // The split as WM Shell reports it: task -> stage, task -> visible, stage -> position.
    private val stageOf = HashMap<Int, Int>()
    private val positionOf = HashMap<Int, Int>()

    /** Tasks that just left the split, with the position they were on. */
    private val leaving = HashMap<Int, Int>()

    /** The last measured screen share of each split task. */
    private val share = HashMap<Int, Float>()

    fun tucked(side: Int): Tuck? = tucked.getOrNull(side)

    /** WM Shell's ISplitScreen arrived ([PowosRecentsService.onInitialize]): its listener is registered on it. */
    fun attach(
        context: Context,
        splitScreen: IBinder?,
    ) {
        this.context = context.applicationContext
        if (splitScreen == null || splitScreen === registeredOn) return
        runCatching {
            val data = Parcel.obtain()
            try {
                data.writeInterfaceToken(SPLIT_SCREEN)
                data.writeStrongBinder(listener)
                splitScreen.transact(REGISTER_LISTENER, data, null, IBinder.FLAG_ONEWAY)
            } finally {
                data.recycle()
            }
            registeredOn = splitScreen
        }.onSuccess { Log.i(TAG, "listening to WM Shell's split screen (ISplitScreen.registerSplitScreenListener)") }
            .onFailure { Log.w(TAG, "can't listen to WM Shell's split screen", it) }
    }

    private val listener =
        object : Binder() {
            init {
                attachInterface(null, LISTENER)
            }

            override fun onTransact(
                code: Int,
                data: Parcel,
                reply: Parcel?,
                flags: Int,
            ): Boolean {
                when (code) {
                    ON_STAGE_POSITION_CHANGED -> {
                        data.enforceInterface(LISTENER)
                        val stage = data.readInt()
                        val position = data.readInt()
                        main.post { stagePosition(stage, position) }
                    }
                    ON_TASK_STAGE_CHANGED -> {
                        data.enforceInterface(LISTENER)
                        val task = data.readInt()
                        val stage = data.readInt()
                        val visible = data.readInt() != 0
                        main.post { taskStage(task, stage, visible) }
                    }
                    else -> return super.onTransact(code, data, reply, flags)
                }
                return true
            }
        }

    private fun stagePosition(
        stage: Int,
        position: Int,
    ) {
        Log.i(TAG, "stage $stage at ${sideName(position)}")
        positionOf[stage] = position
    }

    private fun taskStage(
        task: Int,
        stage: Int,
        visible: Boolean,
    ) {
        Log.i(TAG, "task $task -> stage $stage visible $visible")
        if (stage != STAGE_UNDEFINED) {
            stageOf[task] = stage
            leaving.remove(task)
            // A tucked app back in a split (from the switcher, or pulled back) isn't tucked any more.
            drop(task, "back in a split")
            if (stageOf.size >= 2) sampleSoon()
            return
        }
        val was = stageOf.remove(task) ?: return
        position(was)?.let { leaving[task] = it }
        if (stageOf.isEmpty()) {
            main.removeCallbacks(settle)
            main.postDelayed(settle, SETTLE_MS)
        }
    }

    /** Stage [stage]'s position: as WM Shell said, else the other side of the other stage's. */
    private fun position(stage: Int): Int? = positionOf[stage] ?: positionOf.entries.firstOrNull { it.key != stage }?.let { 1 - it.value }

    /** The split ended: a divider dragged to an edge leaves exactly one of its apps visible and the other alive. */
    private val settle =
        Runnable {
            val gone = HashMap(leaving)
            leaving.clear()
            main.removeCallbacks(sample)
            if (gone.size != 2) {
                Log.i(TAG, "split ended with ${gone.keys}: nothing tucked")
                return@Runnable
            }
            val ctx = context ?: return@Runnable
            val recent = recents(ctx)
            val visible = gone.keys.filter { id -> recent.firstOrNull { it.taskId == id }?.isVisible == true }
            val alive = gone.keys.filter { id -> recent.any { it.taskId == id } }
            val folded = ctx.resources.configuration.smallestScreenWidthDp < 600
            val kept = visible.singleOrNull()
            val tuck = alive.singleOrNull { it != kept }
            when {
                folded -> Log.i(TAG, "split ended on the folded screen: nothing tucked")
                kept == null || tuck == null -> Log.i(TAG, "split ended (visible $visible, alive $alive): not an edge drag, nothing tucked")
                else -> {
                    val side = gone[tuck]!!
                    val pkg = recent.firstOrNull { it.taskId == tuck }?.baseActivity?.packageName
                    val t = Tuck(tuck, pkg, side, share[tuck] ?: 0.5f, kept)
                    tucked[side]?.let { Log.i(TAG, "${sideName(side)} drawer had ${it.task} (${it.pkg}): replaced") }
                    tucked[side] = t
                    Log.i(TAG, "split dismissed by edge drag: tucked $tuck ($pkg) at ${sideName(side)} (share ${"%.2f".format(t.share)}, kept $kept)")
                    onChange?.invoke()
                }
            }
            share.clear()
        }

    /** The split tasks' screen shares, read now and again while split (the ratio a pulled-back app returns at). */
    private fun sampleSoon() {
        main.removeCallbacks(sample)
        main.postDelayed(sample, 800)
    }

    private val sample: Runnable =
        Runnable {
            val ctx = context ?: return@Runnable
            if (stageOf.size < 2) return@Runnable
            val screen = runCatching { ctx.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds }.getOrNull() ?: return@Runnable
            @Suppress("DEPRECATION")
            val tasks = runCatching { ctx.getSystemService(ActivityManager::class.java).getRunningTasks(16) }.getOrDefault(emptyList())
            for (t in tasks) {
                if (t.taskId !in stageOf) continue
                val b = bounds(t) ?: continue
                // Left/right on the unfolded screen; top/bottom otherwise.
                val s = if (screen.width() >= screen.height()) b.width().toFloat() / screen.width() else b.height().toFloat() / screen.height()
                // A mid-drag reading near the edge isn't a ratio to come back at.
                if (s in 0.15f..0.85f) share[t.taskId] = s
            }
            main.postDelayed(sample, SAMPLE_MS)
        }

    /** HACK: TaskInfo.configuration / Configuration.windowConfiguration are hidden (as FreeformTasks); real fix: none. */
    private fun bounds(t: ActivityManager.RunningTaskInfo): Rect? =
        runCatching {
            val c = android.app.TaskInfo::class.java.getField("configuration").get(t) as Configuration
            val wc = Configuration::class.java.getField("windowConfiguration").get(c)!!
            Rect(wc.javaClass.getMethod("getBounds").invoke(wc) as Rect)
        }.getOrNull()

    @Suppress("DEPRECATION")
    private fun recents(ctx: Context): List<ActivityManager.RecentTaskInfo> =
        runCatching { ctx.getSystemService(ActivityManager::class.java).getRecentTasks(32, ActivityManager.RECENT_IGNORE_UNAVAILABLE) }.getOrDefault(emptyList())

    /**
     * The app tucked at [side] pulled back in: into the split on that side at its old ratio, or ([float]) as a floating
     * window. False when nothing is tucked there or it's gone (the drawer empties either way).
     */
    fun pull(
        ctx: Context,
        side: Int,
        float: Boolean,
    ): Boolean {
        val t = tucked.getOrNull(side) ?: return false
        tucked[side] = null
        onChange?.invoke()
        val recent = recents(ctx)
        if (recent.none { it.taskId == t.task }) {
            Log.i(TAG, "pulled ${sideName(side)}: ${t.task} (${t.pkg}) is gone, drawer emptied")
            return false
        }
        if (float) {
            Log.i(TAG, "pulled out: ${t.task} (${t.pkg}) from ${sideName(side)} as a floating window")
            return Tasks.float(ctx, t.task)
        }
        // The app full width now (the one kept, unless the user moved on): the split's other half.
        val other = recent.firstOrNull { it.isVisible && it.taskId != t.task }?.taskId ?: t.kept
        val left = if (side == Tasks.SPLIT_POSITION_TOP_OR_LEFT) t.share else 1f - t.share
        val snap =
            when {
                left < 0.42f -> Tasks.SNAP_TO_2_33_66
                left > 0.58f -> Tasks.SNAP_TO_2_66_33
                else -> Tasks.SNAP_TO_2_50_50
            }
        Log.i(TAG, "pulled back: ${t.task} into split ${sideName(side)} ratio ${"%.2f".format(t.share)} (snap $snap, beside $other)")
        return Tasks.split(t.task, other, side, snap)
    }

    /** Task [task] no longer belongs in a drawer. */
    private fun drop(
        task: Int,
        why: String,
    ) {
        for (i in tucked.indices) {
            if (tucked[i]?.task == task) {
                Log.i(TAG, "${sideName(i)} drawer: $task $why, emptied")
                tucked[i] = null
                onChange?.invoke()
            }
        }
    }

    /** The drawers empty of apps that came back some other way (opened from the switcher) or are gone. */
    fun prune(ctx: Context) {
        if (tucked.all { it == null }) return
        val recent = recents(ctx)
        for (t in tucked.filterNotNull()) {
            val r = recent.firstOrNull { it.taskId == t.task }
            when {
                r == null -> drop(t.task, "is gone")
                r.isVisible -> drop(t.task, "is on screen again")
            }
        }
    }

    private fun sideName(position: Int) = if (position == Tasks.SPLIT_POSITION_TOP_OR_LEFT) "left" else "right"
}
