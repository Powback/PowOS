package dev.omalauncher.system.gesture

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.IInterface
import android.os.Looper
import android.os.Parcel
import android.provider.Settings
import android.util.Log
import android.view.Choreographer
import android.view.RemoteAnimationTarget
import android.view.SurfaceControl
import androidx.annotation.RequiresApi
import dev.omalauncher.system.HiddenApi
import dev.omalauncher.system.Switcher
import java.util.concurrent.Executors

/**
 * The app's window following the finger on a swipe up (gesture navigation), as Quickstep's recents animation: PowOS
 * asks WM Shell for a recents transition (IRecentTasks.startRecentsTransition, the binder SystemUI hands over in
 * ILauncherProxy.onInitialize), which launches PowOS's home transiently behind the app and gives PowOS the app's
 * surface (a leash) to move; the gesture's end finishes it - to home (home stays), or back to the app.
 *
 * - [drag]: the window shrinks toward its card in the switcher (home's recents layer, shell/ui/recents.tsx: where that
 *   card is, [slot], is the page's) as the finger goes up, its bottom edge under the finger and sideways with it, as
 *   Quickstep's TaskViewSimulator; every frame's progress goes to [onFrame] (the page moves the other cards with it).
 * - [end]: animates to where the gesture went - home (it shrinks away), the switcher (onto its card exactly: home's
 *   page is already showing the switcher behind it, so finishing to home leaves the switcher up) or back to the app -,
 *   finishes the transition, then calls back: true when the transition did it, false when it never came up or was
 *   cancelled (the caller then does the plain thing: a home intent). A `hold` keeps the window on its card until the
 *   page has put the app's fresh snapshot on that card (Switcher.settle), then finishes.
 * - Every path finishes: a start that doesn't come in time is given up (and finished at once if it comes later), a
 *   task appearing mid-gesture ends it back to the apps, and WM Shell itself finishes it if PowOS dies (its
 *   RecentsController's death recipient).
 *
 * Android 16 only: IRecentTasks', IRecentsAnimationRunner's and IRecentsAnimationController's transaction codes and
 * parcels are the OnePlus Open's (its decompiled SystemUI/WM Shell: startRecentsTransition 6, onAnimationCanceled 2,
 * onAnimationStart 3, onTasksAppeared 4, OnePlus's onTasksAppearedCallback 6; finish 2, setWillFinishToHome 4), which
 * are AOSP android16's plus OnePlus's own. Off with `settings put global powos_recents_animation 0`.
 *
 * HACK: those three interfaces are WM Shell's, hidden and not in the SDK: their calls are written by hand here (as the
 * generated AIDL would), RemoteAnimationTarget is a compile-time stand-in (hidden-stubs/), and the hidden members used
 * (ActivityOptions.setTransientLaunch, the app's IApplicationThread) are let past the runtime checks by [HiddenApi].
 * Real fix: none for an app - Quickstep compiles against the platform's own copies.
 */
@RequiresApi(Build.VERSION_CODES.BAKLAVA)
class RecentsTransition private constructor(
    /** The display (px): the windows' full-screen frame. */
    private val screen: Rect,
) {
    /** Where the app's card is (screen px) - the switcher's slot the window lands on; null: a default slot. */
    var slot: () -> Rect? = { null }

    /** Every frame the windows move: progress 0 (full screen) .. 1 (on the card), and the sideways / upwards offset (px). */
    var onFrame: ((progress: Float, dx: Float, dy: Float, home: Float) -> Unit)? = null

    enum class End { HOME, SWITCHER, APP }

    private enum class State { STARTING, RUNNING, ENDING, DONE }

    private val main = Handler(Looper.getMainLooper())
    private var state = State.STARTING
    private var controller: IBinder? = null
    private var apps: List<Leash> = emptyList()
    private var pending: Ending? = null

    /** The end under way's callback (until the windows got there, or WM Shell called it off). */
    private var ending: ((Boolean) -> Unit)? = null

    /** An app window of the transition and where it was. */
    private class Leash(
        val surface: SurfaceControl,
        val bounds: Rect,
    )

    /**
     * Where the windows are: [progress] 0 (full screen) .. 1 (on the card's slot), then moved by [dx], [dy] (px), shrunk
     * about their middle by [shrink], at [alpha].
     */
    private data class Look(
        val progress: Float,
        val dx: Float,
        val dy: Float,
        val shrink: Float = 1f,
        val alpha: Float = 1f,
        /** How far into the home zone (0..1): where letting go goes home - the page fades the switcher out with it. */
        val home: Float = 0f,
    )

    private var look = Look(0f, 0f, 0f)

    /** A gesture's end waiting for the transition to start. */
    private class Ending(
        val end: End,
        val hold: ((() -> Unit) -> Unit)?,
        val done: (Boolean) -> Unit,
    )

    /** The finger is [lift] px above where it went down and [dx] px to the side of it. */
    fun drag(
        lift: Float,
        dx: Float,
        home: Float = 0f,
    ) {
        if (state == State.DONE || state == State.ENDING) return
        look = dragLook(lift, dx, home)
        // Once per display frame (touch comes in faster than the screen refreshes): the window and the page move
        // together on the frame, with the newest finger position.
        if (!framePending) {
            framePending = true
            choreographer.postFrameCallback(frame)
        }
    }

    private val choreographer = Choreographer.getInstance()
    private var framePending = false
    private val frame =
        Choreographer.FrameCallback {
            framePending = false
            if (state == State.RUNNING) apply(look)
        }

    /**
     * The gesture ended as [end]: animate there and finish; [done] hears whether the transition did it. [hold], when
     * given, is called once the windows got there, before finishing: the transition finishes when it calls back.
     */
    fun end(
        end: End,
        hold: ((() -> Unit) -> Unit)? = null,
        /** The finger's speed at the release (px/ms, upwards): the settle carries on with it. */
        liftSpeed: Float = 0f,
        done: (Boolean) -> Unit,
    ) {
        releaseSpeed = liftSpeed
        when (state) {
            State.STARTING -> {
                pending = Ending(end, hold, done)
                // The start never came: give up (it's finished the moment it comes, if it does).
                main.postDelayed({
                    if (state == State.STARTING && pending != null) {
                        val cb = pending!!.done
                        pending = null
                        state = State.DONE
                        abandoned = end
                        Log.w(TAG, "the recents transition didn't start in time: the plain way")
                        cb(false)
                    }
                }, START_TIMEOUT_MS)
            }
            State.RUNNING -> finishAnimated(end, hold, done)
            State.ENDING -> done(true)
            State.DONE -> done(interrupted)
        }
    }

    /** The finger's upward speed at the release (px/ms). */
    private var releaseSpeed = 0f

    /** The settle's spring (Choreographer-paced) while it runs. */
    private var settleFrame: Choreographer.FrameCallback? = null

    /** Set when the transition was given up before it started: how a late start is finished. */
    private var abandoned: End? = null

    /** A task appeared mid-gesture (an app was opened): the transition was ended to it, nothing more to do. */
    private var interrupted = false

    private fun started(
        controller: IBinder,
        targets: List<RemoteAnimationTarget?>,
    ) {
        if (state != State.STARTING) {
            // Given up already: let it go at once, where the gesture went.
            control(controller) { finishCall(it, toHome = abandoned != End.APP, userLeaveHint = false) }
            return
        }
        this.controller = controller
        Log.i(TAG, "started: " + targets.filterNotNull().joinToString { "task ${it.taskId} mode ${it.mode} at ${it.screenSpaceBounds}" })
        apps =
            targets.filterNotNull().filter { it.mode == RemoteAnimationTarget.MODE_CLOSING && it.leash != null }.map {
                Leash(it.leash, it.screenSpaceBounds ?: Rect(0, 0, 0, 0))
            }
        state = State.RUNNING
        // Home (the opening target) is what the switcher is drawn in: shown from the first frame, under the app. WM
        // Shell leaves the recents target's surface to the recents provider (Quickstep shows its launcher itself).
        runCatching {
            val t = SurfaceControl.Transaction()
            targets.filterNotNull().filter { it.mode == RemoteAnimationTarget.MODE_OPENING && it.leash != null }.forEach {
                t.setVisibility(it.leash, true)
                t.setAlpha(it.leash, 1f)
            }
            t.apply()
        }.onFailure { Log.w(TAG, "can't show home under the app", it) }
        apply(look)
        main.postDelayed(watchdog, WATCHDOG_MS)
        pending?.let { p ->
            pending = null
            finishAnimated(p.end, p.hold, p.done)
        }
    }

    /** WM Shell called it off (another transition took over): the windows are WM's again. */
    private fun canceled() {
        if (state == State.DONE) return
        stop()
        pending?.let { p ->
            pending = null
            p.done(false)
        }
        ending?.let { done ->
            ending = null
            done(false)
        }
    }

    /** An app was started meanwhile: back to the apps (it comes to the front), the gesture's end does nothing more. */
    private fun tasksAppeared(callback: IBinder?) {
        callback?.let { cb -> control(cb) { transitionFinished(it) } }
        if (state == State.DONE) return
        interrupted = true
        val c = controller
        stop()
        c?.let { control(it) { b -> finishCall(b, toHome = false, userLeaveHint = false) } }
        pending?.let { p ->
            pending = null
            p.done(true)
        }
        ending?.let { done ->
            ending = null
            done(true)
        }
    }

    private val watchdog =
        Runnable {
            if (state == State.RUNNING) {
                Log.w(TAG, "the recents transition was left running: back to the app")
                finishAnimated(End.APP, null) {}
            }
        }

    private fun finishAnimated(
        end: End,
        hold: ((() -> Unit) -> Unit)?,
        done: (Boolean) -> Unit,
    ) {
        state = State.ENDING
        ending = done
        val c = controller
        val toHome = end != End.APP
        if (toHome && c != null) control(c) { setWillFinishToHome(it, true) }
        val from = look
        val to =
            when (end) {
                // Shrinks away into home (the layer collapses behind it).
                End.HOME -> Look(1f, 0f, -screen.height() * 0.04f, shrink = 0.6f, alpha = 0f, home = 1f)
                // Onto its card exactly.
                End.SWITCHER -> Look(1f, 0f, 0f)
                End.APP -> Look(0f, 0f, 0f)
            }
        val finish = {
            if (state == State.ENDING) {
                stop()
                if (c != null) control(c) { finishCall(it, toHome, userLeaveHint = end == End.HOME) }
                ending?.let { cb ->
                    ending = null
                    cb(true)
                }
            }
        }
        // From where the finger left the windows, at its speed: the settle's start speed in its own units (fractions
        // of the way per second) is the finger's speed through the progress it moved (lift / travel).
        val travel = (screen.bottom - target().bottom).toFloat().coerceAtLeast(screen.height() * 0.12f)
        val progressPerSec = releaseSpeed * 1000f / travel
        val span = to.progress - from.progress
        val v0 = if (kotlin.math.abs(span) > 0.02f) (progressPerSec / span).coerceIn(-4f, 12f) else 0f
        settle(v0, { f ->
            look =
                Look(
                    lerp(from.progress, to.progress, f),
                    lerp(from.dx, to.dx, f),
                    lerp(from.dy, to.dy, f),
                    lerp(from.shrink, to.shrink, f),
                    lerp(from.alpha, to.alpha, f).coerceIn(0f, 1f),
                    lerp(from.home, to.home, f),
                )
            apply(look)
        }) {
            if (state != State.ENDING) return@settle
            // The windows stay where they are (on the card) until the holder lets them go.
            if (hold != null) hold { main.post(finish) } else finish()
        }
    }

    /**
     * A spring from 0 to 1 starting at speed [v0] (per second), each display frame to [onFrame], then [onDone]: the
     * drawer's and the shade's settle (their 280 ms ease-out, cubic-bezier(0.2, 0.9, 0.3, 1)) with the finger's
     * momentum kept - critically damped, so it never overshoots a window past its card. Quickstep settles its windows
     * with a spring the same way (AnimatedFloat + SpringAnimation from the release velocity).
     */
    private fun settle(
        v0: Float,
        onFrame: (Float) -> Unit,
        onDone: () -> Unit,
    ) {
        settleFrame?.let(choreographer::removeFrameCallback)
        var x = 0f
        var v = v0
        var last = 0L
        val cb =
            object : Choreographer.FrameCallback {
                override fun doFrame(now: Long) {
                    if (state != State.ENDING) return
                    val dt = if (last == 0L) 1f / 120 else ((now - last) / 1e9f).coerceIn(0.001f, 0.05f)
                    last = now
                    // Semi-implicit Euler in small steps: steady at 60 or 120 Hz.
                    var left = dt
                    while (left > 0f) {
                        val h = minOf(left, 0.004f)
                        v += (-SPRING_K * (x - 1f) - SPRING_C * v) * h
                        x += v * h
                        left -= h
                    }
                    val settled = kotlin.math.abs(x - 1f) < 0.003f && kotlin.math.abs(v) < 0.05f
                    onFrame(if (settled) 1f else x)
                    if (settled) {
                        settleFrame = null
                        onDone()
                    } else {
                        choreographer.postFrameCallback(this)
                    }
                }
            }
        settleFrame = cb
        choreographer.postFrameCallback(cb)
    }

    /** Done with the windows: no more moving them, the leashes let go. */
    private fun stop() {
        state = State.DONE
        if (framePending) choreographer.removeFrameCallback(frame)
        framePending = false
        main.removeCallbacks(watchdog)
        settleFrame?.let(choreographer::removeFrameCallback)
        settleFrame = null
        controller = null
        apps.forEach { runCatching { it.surface.release() } }
        apps = emptyList()
    }

    /** The card's slot (screen px): the page's, or where a card would be (the middle 70% of the screen). */
    private fun target(): Rect =
        slot()?.takeIf { it.width() > 0 && it.height() > 0 }
            ?: Rect(
                screen.left + (screen.width() * 0.15f).toInt(),
                screen.top + (screen.height() * 0.15f).toInt(),
                screen.right - (screen.width() * 0.15f).toInt(),
                screen.top + (screen.height() * 0.85f).toInt(),
            )

    /**
     * The finger [lift] px up: the window's bottom edge stays under it on its way to the card (progress 1 when the
     * bottom edges meet); past that the window goes on up, slower (a rubber band), and sideways with the finger.
     */
    private fun dragLook(
        lift: Float,
        dx: Float,
        home: Float,
    ): Look {
        val travel = (screen.bottom - target().bottom).toFloat().coerceAtLeast(screen.height() * 0.12f)
        val progress = (lift / travel).coerceIn(0f, 1f)
        val over = (lift - travel).coerceAtLeast(0f)
        // Into the home zone the window shrinks and fades toward home, as the release there will take it.
        return Look(progress, dx, -over * RUBBER, shrink = 1f - 0.35f * home, alpha = 1f - 0.6f * home, home = home)
    }

    /** The windows as [look] says: their frame between full screen and the card, moved, shrunk, faded. */
    private fun apply(look: Look) {
        if (state != State.RUNNING && state != State.ENDING) return
        onFrame?.invoke(look.progress, look.dx, look.dy, look.home)
        if (apps.isEmpty()) return
        val card = target()
        val p = look.progress
        val w = lerp(screen.width().toFloat(), card.width().toFloat(), p) * look.shrink
        val h = lerp(screen.height().toFloat(), card.height().toFloat(), p) * look.shrink
        val cx = lerp(screen.exactCenterX(), card.exactCenterX(), p) + look.dx
        val cy = lerp(screen.exactCenterY(), card.exactCenterY(), p) + look.dy
        val scale = w / screen.width()
        val left = cx - w / 2
        val top = cy - h / 2
        val radius = Switcher.slotRadius * p
        runCatching {
            val t = SurfaceControl.Transaction()
            for (app in apps) {
                if (!app.surface.isValid) continue
                if (app.bounds.width() <= 0 || app.bounds.height() <= 0) continue
                t.setScale(app.surface, scale, scale)
                t.setPosition(app.surface, left + (app.bounds.left - screen.left) * scale, top + (app.bounds.top - screen.top) * scale)
                t.setAlpha(app.surface, look.alpha)
                corners(t, app, radius / scale)
            }
            t.apply()
        }.onFailure { Log.w(TAG, "can't move the app's window", it) }
    }

    /**
     * The window's corners rounded as the card's, [radius] in the window's own px. HACK: Transaction.setCornerRadius is
     * hidden (the call Quickstep makes); reflected, and skipped where it isn't there. Real fix: none for an app.
     */
    private fun corners(
        t: SurfaceControl.Transaction,
        app: Leash,
        radius: Float,
    ) {
        val m = cornerRadius ?: return
        runCatching {
            t.setCrop(app.surface, Rect(0, 0, app.bounds.width(), app.bounds.height()))
            m.invoke(t, app.surface, radius)
        }.onFailure {
            Log.w(TAG, "no rounded corners for the window", it)
            cornerRadius = null
        }
    }

    /** IRecentsAnimationRunner, the transition's side in PowOS (WM Shell calls it; hand-written onTransact). */
    private val runner =
        object : Binder(RUNNER) {
            override fun onTransact(
                code: Int,
                data: Parcel,
                reply: Parcel?,
                flags: Int,
            ): Boolean {
                if (code == INTERFACE_TRANSACTION) {
                    reply?.writeString(RUNNER)
                    return true
                }
                if (code < FIRST_CALL_TRANSACTION || code > LAST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags)
                data.enforceInterface(RUNNER)
                when (code) {
                    RUNNER_ON_ANIMATION_START -> {
                        val c = data.readStrongBinder()
                        val targets: List<RemoteAnimationTarget?> =
                            runCatching { data.createTypedArray(RemoteAnimationTarget.CREATOR)?.toList() }
                                .onFailure { Log.w(TAG, "can't read the transition's windows", it) }.getOrNull() ?: emptyList()
                        main.post {
                            if (c == null) canceled() else started(c, targets)
                        }
                    }
                    RUNNER_ON_ANIMATION_CANCELED -> main.post { canceled() }
                    RUNNER_ON_TASKS_APPEARED -> main.post { tasksAppeared(null) }
                    RUNNER_ON_TASKS_APPEARED_CALLBACK -> {
                        runCatching { data.createTypedArray(RemoteAnimationTarget.CREATOR) }
                        val cb = data.readStrongBinder()
                        main.post { tasksAppeared(cb) }
                    }
                    RUNNER_NOTIFY_INTERCEPT_KEY_EVENT -> {}
                    else -> return super.onTransact(code, data, reply, flags)
                }
                return true
            }
        }

    companion object {
        private const val TAG = "PowosRecentsAnim"

        /** The bundle key onInitialize keys WM Shell's IRecentTasks by: its descriptor. */
        const val RECENT_TASKS = "com.android.wm.shell.recents.IRecentTasks"
        private const val RUNNER = "com.android.wm.shell.recents.IRecentsAnimationRunner"
        private const val CONTROLLER = "com.android.wm.shell.recents.IRecentsAnimationController"
        private const val FINISHED_CALLBACK = "android.window.IRemoteTransitionFinishedCallback"

        // Transaction codes (the phone's: see the class comment).
        private const val RECENT_TASKS_START_RECENTS_TRANSITION = 6
        private const val RUNNER_ON_ANIMATION_CANCELED = 2
        private const val RUNNER_ON_ANIMATION_START = 3
        private const val RUNNER_ON_TASKS_APPEARED = 4
        private const val RUNNER_NOTIFY_INTERCEPT_KEY_EVENT = 5
        private const val RUNNER_ON_TASKS_APPEARED_CALLBACK = 6
        private const val CONTROLLER_FINISH = 2
        private const val CONTROLLER_SET_WILL_FINISH_TO_HOME = 4
        private const val FINISHED_CALLBACK_ON_TRANSITION_FINISHED = 1

        private const val START_TIMEOUT_MS = 700L

        /**
         * The settle's spring (1/s², 1/s): critically damped (c = 2 sqrt k), settled in about 280 ms from rest - the
         * drawer's and the shade's settle.
         */
        private const val SPRING_K = 500f
        private val SPRING_C = 2f * kotlin.math.sqrt(SPRING_K)

        /** Past the card, the window goes up this much of the finger's way. */
        private const val RUBBER = 0.3f

        /** SurfaceControl.Transaction.setCornerRadius (hidden), looked up once. */
        private var cornerRadius: java.lang.reflect.Method? =
            runCatching {
                HiddenApi.allow()
                SurfaceControl.Transaction::class.java.getMethod("setCornerRadius", SurfaceControl::class.java, Float::class.javaPrimitiveType)
            }.getOrNull()
        private const val WATCHDOG_MS = 10_000L

        /** The transition's blocking calls go here, off the main thread (as Quickstep's UI helper executor). */
        private val calls = Executors.newSingleThreadExecutor { Thread(it, "powos-recents-anim") }

        /** Whether the animated path is on (`settings put global powos_recents_animation 0` turns it off). */
        fun enabled(context: Context): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA &&
                runCatching { Settings.Global.getInt(context.contentResolver, "powos_recents_animation", 1) != 0 }.getOrDefault(true)

        /**
         * Starts a recents transition over the app in front, with [home] (PowOS's home activity) launched behind it; null
         * if WM Shell can't be asked (the caller keeps to the plain way).
         */
        fun start(
            context: Context,
            recentTasks: IBinder,
            home: ComponentName,
            screen: Rect,
        ): RecentsTransition? {
            HiddenApi.allow()
            val transition = RecentsTransition(screen)
            return runCatching {
                val creator = ActivityOptions.makeBasic().setPendingIntentCreatorBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS)
                // As Quickstep's SystemUiProxy: an intent for the package, the component filled in from the next one.
                val pending =
                    PendingIntent.getActivity(
                        context,
                        0,
                        Intent().setPackage(context.packageName),
                        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_ALLOW_UNSAFE_IMPLICIT_INTENT or Intent.FILL_IN_COMPONENT,
                        creator.toBundle(),
                    )
                val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).setComponent(home).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        // Not Home pressed: home's page keeps what it shows (its recents layer is coming up).
                        .putExtra(Switcher.EXTRA_RECENTS, true)
                val options = ActivityOptions.makeBasic()
                ActivityOptions::class.java.getMethod("setTransientLaunch").invoke(options)
                val data = Parcel.obtain()
                try {
                    data.writeInterfaceToken(RECENT_TASKS)
                    data.writeTypedObject(pending, 0)
                    data.writeTypedObject(intent, 0)
                    data.writeTypedObject(options.toBundle(), 0)
                    data.writeStrongBinder(applicationThread(context))
                    data.writeStrongBinder(transition.runner)
                    recentTasks.transact(RECENT_TASKS_START_RECENTS_TRANSITION, data, null, IBinder.FLAG_ONEWAY)
                } finally {
                    data.recycle()
                }
                transition
            }.onFailure { Log.w(TAG, "can't start the recents transition", it) }.getOrNull()
        }

        /** The app process's IApplicationThread (WM Shell boosts it while the transition runs). */
        private fun applicationThread(context: Context): IBinder? =
            runCatching { (context.javaClass.getMethod("getIApplicationThread").invoke(context) as IInterface).asBinder() }
                .recoverCatching {
                    val thread = Class.forName("android.app.ActivityThread").getMethod("currentActivityThread").invoke(null)
                    (thread.javaClass.getMethod("getApplicationThread").invoke(thread) as IInterface).asBinder()
                }.onFailure { Log.w(TAG, "no IApplicationThread", it) }.getOrNull()

        private fun control(
            binder: IBinder,
            call: (IBinder) -> Unit,
        ) {
            calls.execute { runCatching { call(binder) }.onFailure { Log.w(TAG, "recents transition call failed", it) } }
        }

        /** IRecentsAnimationController.finish(toHome, sendUserLeaveHint, IResultReceiver = null). */
        private fun finishCall(
            controller: IBinder,
            toHome: Boolean,
            userLeaveHint: Boolean,
        ) = transact(controller, CONTROLLER, CONTROLLER_FINISH) {
            it.writeInt(if (toHome) 1 else 0)
            it.writeInt(if (userLeaveHint) 1 else 0)
            it.writeStrongBinder(null)
        }

        private fun setWillFinishToHome(
            controller: IBinder,
            toHome: Boolean,
        ) = transact(controller, CONTROLLER, CONTROLLER_SET_WILL_FINISH_TO_HOME) { it.writeInt(if (toHome) 1 else 0) }

        /** IRemoteTransitionFinishedCallback.onTransitionFinished(null, null): the merged transition is done here. */
        private fun transitionFinished(callback: IBinder) =
            transact(callback, FINISHED_CALLBACK, FINISHED_CALLBACK_ON_TRANSITION_FINISHED) {
                it.writeInt(0)
                it.writeInt(0)
            }

        private fun transact(
            binder: IBinder,
            descriptor: String,
            code: Int,
            write: (Parcel) -> Unit,
        ) {
            val data = Parcel.obtain()
            val reply = Parcel.obtain()
            try {
                data.writeInterfaceToken(descriptor)
                write(data)
                binder.transact(code, data, reply, 0)
                reply.readException()
            } finally {
                reply.recycle()
                data.recycle()
            }
        }

        private fun lerp(
            a: Float,
            b: Float,
            f: Float,
        ) = a + (b - a) * f
    }
}
