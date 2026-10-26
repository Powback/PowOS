package dev.omalauncher.system

import android.app.ActivityManager
import android.content.Context
import android.graphics.Point
import android.graphics.Rect
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.Parcelable
import android.os.SystemClock
import android.util.Log
import android.view.SurfaceControl

/**
 * Floating windows' content moved by PowOS itself, frame by frame, while a finger drags them: what WM Shell's desktop
 * mode does with the task's surface (its leash) on a caption drag, done from PowOS through a change transition PowOS
 * plays itself.
 *
 * Why: WM Shell organizes every task and owns its surface's position and crop; WM core never touches them for an
 * organized task, so bounds set with WindowOrganizer.applyTransaction moved the task in WM only - the app's content
 * (and its touches) stayed where it was until a transition put it there (e2e r3 2026-10-23). A transition PowOS plays
 * gets the leash: [Session.start] registers a remote with WM Shell (IShellTransitions.registerRemote, filtered to a
 * change of a floating task), starts a change transition (WindowOrganizer.startNewTransition(TRANSIT_CHANGE)) that
 * really changes the tasks' bounds and keeps it open; WM Shell hands the remote the tasks' leashes
 * (IRemoteTransition.startAnimation), [Session.frame] moves/crops them every frame (with the drag layer's own draw,
 * so bar and content move as one), and [Session.finish] closes it with the last bounds (WCT setBounds, applied by WM
 * as the transition finishes) and the leashes put there. Logcat PowosTaskLeash: start latency, frames, how it ended.
 *
 * Every path ends the transition: a release before the leash came finishes it the moment it comes; a start that
 * never comes in [START_MS] is given up (the caller falls back to [FreeformTasks.Live]); a session open for
 * [WATCHDOG_MS] is finished with what it has (an open transition holds every other one of WM Shell's back); a
 * transition that isn't ours is finished at once, untouched.
 *
 * HACK: IShellTransitions (WM Shell's, from SystemUI's onInitialize bundle), IRemoteTransition and
 * IRemoteTransitionFinishedCallback aren't in the SDK: their calls are written by hand (the phone's codes:
 * registerRemote 2, unregisterRemote 3; startAnimation 1, mergeAnimation 2, takeOverAnimation 3, onTransitionConsumed
 * 4, onTransitionAbort 5; onTransitionFinished 1); TransitionFilter, RemoteTransition, TransitionInfo and
 * WindowOrganizer.startNewTransition are hidden, reflected past the checks ([HiddenApi]). Real fix: none for an app -
 * WM Shell's own drag (DragPositioningCallback) lives in SystemUI's process.
 */
object TaskLeash {
    private const val TAG = "PowosTaskLeash"

    /** WM Shell's IShellTransitions (PowosRecentsService.onInitialize); null: no live content, the old way. */
    @Volatile var shell: IBinder? = null

    /** Off with `settings put global powos_live_leash 0` (the drag then works as before). */
    fun enabled(context: Context) = shell != null && android.provider.Settings.Global.getInt(context.contentResolver, "powos_live_leash", 1) == 1

    private val main = Handler(Looper.getMainLooper())

    /**
     * One open transition over [ids] (task ids): their content under PowOS's hand until [finish]. Main thread only,
     * except where noted.
     */
    class Session(
        private val context: Context,
        private val ids: List<Int>,
        private val what: String,
        /** The task change modes its remote takes (a page slide's: windows brought up from under home too). */
        private val modes: IntArray = intArrayOf(TRANSIT_CHANGE),
    ) {
        private enum class State { STARTING, LIVE, DONE, GAVE_UP }

        private var state = State.STARTING
        private var token: IBinder? = null
        private var finishCallback: IBinder? = null
        private val leashes = HashMap<Int, SurfaceControl>()
        private var offset = Point()
        private val startedAt = SystemClock.uptimeMillis()
        private var frames = 0

        /** The bounds each task should end at (the newest frame's, or [finish]'s). */
        private val last = HashMap<Int, Rect>()
        private var released = false
        private var committed = false
        /** Leashes hidden as it finishes (a page slide's windows left on another page: WM hides those tasks next). */
        var hidden: Set<Int> = emptySet()
        private var endChange: ((Any, (Int) -> Any?) -> Unit)? = null

        /** True once the leashes are PowOS's: [frame] moves the content. */
        val live get() = state == State.LIVE

        /** Still under way (the leashes coming or here): false = it gave up or ended, the caller does the old thing. */
        val pending get() = state == State.STARTING || state == State.LIVE

        /** Called on the main thread, once: the leashes came (true) or never will (false: give up, fall back). */
        var onReady: ((Boolean) -> Unit)? = null
        private var readySaid = false

        private fun ready(ok: Boolean) {
            if (readySaid) return
            readySaid = true
            onReady?.invoke(ok)
        }

        private val remote = RemoteTransition(this)
        private var remoteParcel: Any? = null

        /**
         * Registers the remote and starts the transition, its WCT filled by [change] (wct, task id -> its token): it
         * must really change the tasks (an empty transition is dropped). False: it couldn't start (fall back).
         */
        fun start(change: (Any, (Int) -> Any?) -> Unit): Boolean {
            val binder = shell ?: return false
            return runCatching {
                HiddenApi.allow()
                val rt = remoteTransition(remote)
                remoteParcel = rt
                shellCall(binder, REGISTER_REMOTE) {
                    it.writeTypedObject(filter(modes) as Parcelable, 0)
                    it.writeTypedObject(rt as Parcelable, 0)
                }
                val tokens = tokens()
                val (wct, wctClass) = newWct()
                change(wct) { tokens[it] }
                val organizer = Class.forName("android.window.WindowOrganizer")
                token = organizer.getMethod("startNewTransition", Int::class.javaPrimitiveType, wctClass).invoke(organizer.getConstructor().newInstance(), TRANSIT_CHANGE, wct) as IBinder?
                Log.i(TAG, "$what: change transition asked for (tasks $ids)")
                main.postDelayed(startTimeout, START_MS)
                main.postDelayed(watchdog, WATCHDOG_MS)
                true
            }.onFailure {
                Log.w(TAG, "$what: no live content (the transition didn't start)", it)
                unregister()
                state = State.GAVE_UP
            }.getOrDefault(false)
        }

        /**
         * Task [id]'s content to [bounds] (screen px) in [t] (applied by the caller with its own frame): false while the
         * leash isn't PowOS's (yet).
         */
        fun frame(
            t: SurfaceControl.Transaction,
            id: Int,
            bounds: Rect,
        ): Boolean {
            last[id] = Rect(bounds)
            val leash = leashes[id] ?: return false
            if (state != State.LIVE || !committed || !leash.isValid) return false
            place(t, leash, bounds)
            frames++
            return true
        }

        /**
         * The drag is over: the transition finishes with [change] (wct, id -> token; e.g. the last bounds) and the
         * leashes at [bounds] (task id -> screen px). Before the leashes came: done the moment they come.
         */
        fun finish(
            bounds: Map<Int, Rect>,
            change: (Any, (Int) -> Any?) -> Unit,
        ) {
            last.putAll(bounds.mapValues { Rect(it.value) })
            endChange = change
            released = true
            if (state == State.LIVE && committed) end("released")
        }

        private fun place(
            t: SurfaceControl.Transaction,
            leash: SurfaceControl,
            b: Rect,
        ) {
            t.setPosition(leash, (b.left - offset.x).toFloat(), (b.top - offset.y).toFloat())
            t.setCrop(leash, Rect(0, 0, b.width(), b.height()))
        }

        private val startTimeout =
            Runnable {
                if (state != State.STARTING) return@Runnable
                Log.w(TAG, "$what: no leash in $START_MS ms (WM Shell played it itself?) - the old way")
                state = State.GAVE_UP
                // WM Shell plays it its own way if it comes now.
                unregister()
                ready(false)
            }

        private val watchdog = Runnable { if (state == State.LIVE) end("watchdog ${WATCHDOG_MS / 1000} s") }

        /** WM Shell's startAnimation (main thread). */
        fun started(
            transition: IBinder?,
            info: Any?,
            t: SurfaceControl.Transaction?,
            callback: IBinder?,
        ) {
            if (transition == null || transition != token || state == State.DONE) {
                passThrough(t, callback)
                return
            }
            val start = take(info, t, callback)
            val gaveUp = state == State.GAVE_UP
            state = State.LIVE
            Log.i(TAG, "$what: leashes ${leashes.keys} after ${SystemClock.uptimeMillis() - startedAt} ms (root offset $offset)${if (gaveUp) ", late" else ""}")
            // A zero-frame resize may finish immediately. Wait until SF commits the start transaction before
            // giving the caller its leash: otherwise the finish reparent can overtake this process's start
            // reparent, leaving the app under a detached transition root (maximise, emulator 2026-10-26).
            start.addTransactionCommittedListener({ main.post(it) }) { startCommitted(gaveUp) }
            start.apply()
        }

        private fun startCommitted(gaveUp: Boolean) {
            if (state != State.LIVE) return
            committed = true
            when {
                leashes.isEmpty() -> end("no leash in it")
                released -> end("released before")
                gaveUp -> end("late")
                else -> ready(true)
            }
        }

        /** Not this session's: finished at once, as it is. */
        private fun passThrough(
            t: SurfaceControl.Transaction?,
            callback: IBinder?,
        ) {
            Log.w(TAG, "$what: a transition that isn't ours (${if (state == State.DONE) "after the end" else "another one"}): passed through")
            t?.apply()
            callback?.let { finished(it, null, null) }
        }

        /** The transition's leashes taken, its start transaction applied with them where the finger has them. */
        private fun take(
            info: Any?,
            t: SurfaceControl.Transaction?,
            callback: IBinder?,
        ): SurfaceControl.Transaction {
            finishCallback = callback
            if (info != null) {
                offset = runCatching { rootOffset(info) }.getOrDefault(Point())
                runCatching { leashesOf(info) }.onFailure { Log.w(TAG, "$what: can't read the transition's tasks", it) }.getOrNull()?.let { leashes.putAll(it) }
            }
            val st = t ?: SurfaceControl.Transaction()
            for ((id, leash) in leashes) last[id]?.let { place(st, leash, it) }
            return st
        }

        /** WM Shell called it off (consumed/aborted): nothing to finish. */
        fun gone(why: String) {
            if (state == State.DONE) return
            Log.w(TAG, "$what: transition $why")
            val wasLive = state == State.LIVE
            state = State.DONE
            unregister()
            if (!wasLive) ready(false)
        }

        private fun end(why: String) {
            if (state == State.DONE) return
            state = State.DONE
            main.removeCallbacks(watchdog)
            main.removeCallbacks(startTimeout)
            val cb = finishCallback
            val sct = SurfaceControl.Transaction()
            for ((id, leash) in leashes) if (leash.isValid) last[id]?.let { place(sct, leash, it) }
            for ((id, leash) in leashes) if (leash.isValid && id in hidden) sct.setVisibility(leash, false)
            val wct = runCatching { endTransaction() }.onFailure { Log.w(TAG, "$what: no end transaction", it) }.getOrNull()
            if (cb != null) runCatching { finished(cb, wct, sct) }.onFailure { Log.w(TAG, "$what: can't finish the transition", it) }
            unregister()
            Log.i(TAG, "$what: finished ($why) after ${SystemClock.uptimeMillis() - startedAt} ms, $frames live frames, ends ${last.entries.joinToString { "${it.key}@${it.value.toShortString()}" }}")
        }

        /** What WM applies as it finishes: [finish]'s change, else the last bounds. */
        private fun endTransaction(): Any {
            val tokens = tokens()
            val (w, _) = newWct()
            val change = endChange
            if (change != null) {
                change(w) { tokens[it] }
            } else {
                for ((id, b) in last) tokens[id]?.let { tok -> setBounds(w, tok, b) }
            }
            return w
        }

        private fun unregister() {
            val rt = remoteParcel ?: return
            remoteParcel = null
            val binder = shell ?: return
            runCatching { shellCall(binder, UNREGISTER_REMOTE) { it.writeTypedObject(rt as Parcelable, 0) } }
                .onFailure { Log.w(TAG, "$what: can't unregister the remote", it) }
        }

        /** The sessions' tasks' WindowContainerTokens (TaskInfo.token, hidden). */
        private fun tokens(): Map<Int, Any> {
            @Suppress("DEPRECATION")
            val tasks = context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS)
            val field = android.app.TaskInfo::class.java.getField("token")
            return tasks.filter { it.taskId in ids }.associate { it.taskId to field.get(it)!! }
        }
    }

    /** WCT.setBounds(token, bounds) (hidden). */
    fun setBounds(
        wct: Any,
        token: Any,
        bounds: Rect,
    ) {
        wct.javaClass.getMethod("setBounds", token.javaClass, Rect::class.java).invoke(wct, token, bounds)
    }

    /** WCT.reorder(token, onTop) (hidden): the task to the top (or bottom) in the same transition as its bounds. */
    fun reorder(
        wct: Any,
        token: Any,
        onTop: Boolean,
    ) {
        wct.javaClass.getMethod("reorder", token.javaClass, Boolean::class.javaPrimitiveType).invoke(wct, token, onTop)
    }

    /**
     * WCT.setFocusable(token, focusable) (hidden): a non-focusable task is shown and stacked but never takes input
     * focus. HACK: hidden API, reflected. Real fix: none for an app. Used by the page slide so the windows it brings
     * up don't pull focus from home (that cut home's touch stream and the swipe lost its finger moves).
     */
    fun setFocusable(
        wct: Any,
        token: Any,
        focusable: Boolean,
    ) {
        try {
            wct.javaClass.getMethod("setFocusable", token.javaClass, Boolean::class.javaPrimitiveType).invoke(wct, token, focusable)
        } catch (e: ReflectiveOperationException) {
            android.util.Log.w("TaskLeash", "setFocusable unavailable: $e")
        }
    }

    /** WCT.setDragResizing(token, on) (hidden). */
    fun setDragResizing(
        wct: Any,
        token: Any,
        on: Boolean,
    ) {
        wct.javaClass.getMethod("setDragResizing", token.javaClass, Boolean::class.javaPrimitiveType).invoke(wct, token, on)
    }

    private fun newWct(): Pair<Any, Class<*>> {
        val c = Class.forName("android.window.WindowContainerTransaction")
        return c.getConstructor().newInstance() to c
    }

    /** A change transition (type CHANGE) with a floating task changed in it. */
    private fun filter(modes: IntArray): Any {
        val fc = Class.forName("android.window.TransitionFilter")
        val rc = Class.forName("android.window.TransitionFilter\$Requirement")
        val r = rc.getConstructor().newInstance()
        rc.getField("mModes").set(r, modes)
        rc.getField("mMustBeTask").setBoolean(r, true)
        rc.getField("mWindowingMode").setInt(r, FREEFORM)
        val reqs = java.lang.reflect.Array.newInstance(rc, 1)
        java.lang.reflect.Array.set(reqs, 0, r)
        val f = fc.getConstructor().newInstance()
        fc.getField("mTypeSet").set(f, intArrayOf(TRANSIT_CHANGE))
        fc.getField("mRequirements").set(f, reqs)
        return f
    }

    /** android.window.RemoteTransition(IRemoteTransition.Stub.asInterface(binder), "PowOS window drag"). */
    private fun remoteTransition(binder: IBinder): Any {
        val iface = Class.forName("android.window.IRemoteTransition")
        val stub = Class.forName("android.window.IRemoteTransition\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, binder)
        return Class.forName("android.window.RemoteTransition").getConstructor(iface, String::class.java).newInstance(stub, "PowOS window drag")
    }

    private fun rootOffset(info: Any): Point {
        val n = info.javaClass.getMethod("getRootCount").invoke(info) as Int
        if (n <= 0) return Point()
        val root = info.javaClass.getMethod("getRoot", Int::class.javaPrimitiveType).invoke(info, 0)!!
        return root.javaClass.getMethod("getOffset").invoke(root) as Point
    }

    private fun leashesOf(info: Any): Map<Int, SurfaceControl> {
        val changes = info.javaClass.getMethod("getChanges").invoke(info) as List<*>
        val out = HashMap<Int, SurfaceControl>()
        for (c in changes) {
            c ?: continue
            val task = c.javaClass.getMethod("getTaskInfo").invoke(c) as? ActivityManager.RunningTaskInfo ?: continue
            val leash = c.javaClass.getMethod("getLeash").invoke(c) as? SurfaceControl ?: continue
            out[task.taskId] = leash
        }
        return out
    }

    private fun shellCall(
        binder: IBinder,
        code: Int,
        write: (Parcel) -> Unit,
    ) {
        val data = Parcel.obtain()
        try {
            data.writeInterfaceToken(SHELL_TRANSITIONS)
            write(data)
            binder.transact(code, data, null, IBinder.FLAG_ONEWAY)
        } finally {
            data.recycle()
        }
    }

    /** IRemoteTransitionFinishedCallback.onTransitionFinished(wct, sct). */
    private fun finished(
        callback: IBinder,
        wct: Any?,
        sct: SurfaceControl.Transaction?,
    ) {
        val data = Parcel.obtain()
        try {
            data.writeInterfaceToken(FINISHED_CALLBACK)
            data.writeTypedObject(wct as Parcelable?, 0)
            data.writeTypedObject(sct, 0)
            callback.transact(FINISHED, data, null, IBinder.FLAG_ONEWAY)
        } finally {
            data.recycle()
        }
    }

    /** IRemoteTransition: WM Shell's calls into a session (hand-written onTransact). */
    private class RemoteTransition(
        val session: Session,
    ) : Binder(REMOTE) {
        override fun onTransact(
            code: Int,
            data: Parcel,
            reply: Parcel?,
            flags: Int,
        ): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(REMOTE)
                return true
            }
            if (code < FIRST_CALL_TRANSACTION || code > LAST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags)
            data.enforceInterface(REMOTE)
            when (code) {
                START_ANIMATION -> {
                    val transition = data.readStrongBinder()
                    val info = runCatching { data.readTypedObject(creator("android.window.TransitionInfo")) }.onFailure { Log.w(TAG, "can't read the transition", it) }.getOrNull()
                    val t = runCatching { data.readTypedObject(SurfaceControl.Transaction.CREATOR) }.getOrNull()
                    val cb = data.readStrongBinder()
                    main.post { session.started(transition, info, t, cb) }
                }
                ON_TRANSITION_CONSUMED -> main.post { session.gone("consumed") }
                ON_TRANSITION_ABORT -> main.post { session.gone("aborted") }
                // mergeAnimation / takeOverAnimation: not merged, WM Shell plays the other one after this.
                MERGE_ANIMATION, TAKE_OVER_ANIMATION -> {}
                else -> return super.onTransact(code, data, reply, flags)
            }
            return true
        }

        @Suppress("UNCHECKED_CAST")
        private fun creator(cls: String) = Class.forName(cls).getField("CREATOR").get(null) as Parcelable.Creator<Any>
    }

    private const val SHELL_TRANSITIONS = "com.android.wm.shell.shared.IShellTransitions"
    private const val REMOTE = "android.window.IRemoteTransition"
    private const val FINISHED_CALLBACK = "android.window.IRemoteTransitionFinishedCallback"
    private const val REGISTER_REMOTE = 2
    private const val UNREGISTER_REMOTE = 3
    private const val START_ANIMATION = 1
    private const val MERGE_ANIMATION = 2
    private const val TAKE_OVER_ANIMATION = 3
    private const val ON_TRANSITION_CONSUMED = 4
    private const val ON_TRANSITION_ABORT = 5
    private const val FINISHED = 1

    /** WindowManager.TRANSIT_CHANGE and TransitionInfo's TRANSIT_CHANGE mode (both 6), WINDOWING_MODE_FREEFORM. */
    private const val TRANSIT_CHANGE = 6
    private const val FREEFORM = 5

    /** A page slide's task modes (PageSlide): changed, and brought up from under home (TRANSIT_OPEN 1, TO_FRONT 3). */
    val SLIDE_MODES = intArrayOf(TRANSIT_CHANGE, 1, 3)
    private const val MAX_TASKS = 24

    /** How long WM Shell may take to hand the leashes over before the drag goes the old way. */
    private const val START_MS = 600L

    /** The longest a session holds its transition open (every other transition of WM Shell's waits behind it). */
    private const val WATCHDOG_MS = 15_000L

    /** The descriptor is the bundle key in onInitialize. */
    const val KEY = SHELL_TRANSITIONS
}
