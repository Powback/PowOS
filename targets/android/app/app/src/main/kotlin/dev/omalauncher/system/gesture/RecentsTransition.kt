package dev.omalauncher.system.gesture

import android.animation.ValueAnimator
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
import android.view.RemoteAnimationTarget
import android.view.SurfaceControl
import android.view.animation.DecelerateInterpolator
import androidx.annotation.RequiresApi
import dev.omalauncher.system.HiddenApi
import java.util.concurrent.Executors

/**
 * The app's window following the finger on a swipe up (gesture navigation), as Quickstep's recents animation: PowOS
 * asks WM Shell for a recents transition (IRecentTasks.startRecentsTransition, the binder SystemUI hands over in
 * ILauncherProxy.onInitialize), which launches PowOS's home transiently behind the app and gives PowOS the app's
 * surface (a leash) to move; the gesture's end finishes it - to home (home stays), or back to the app.
 *
 * - [drag]: the window shrinks as the finger goes up, its bottom edge under the finger.
 * - [end]: animates to where the gesture went (home, the switcher - also home, the switcher then shown over it - or
 *   back to the app), finishes the transition, then calls back: true when the transition did it, false when it never
 *   came up or was cancelled (the caller then does the plain thing: a home intent).
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
    private val screenHeight: Float,
) {
    enum class End { HOME, SWITCHER, APP }

    private enum class State { STARTING, RUNNING, ENDING, DONE }

    private val main = Handler(Looper.getMainLooper())
    private var state = State.STARTING
    private var controller: IBinder? = null
    private var apps: List<Leash> = emptyList()
    private var lift = 0f
    private var pending: Pair<End, (Boolean) -> Unit>? = null
    private var animator: ValueAnimator? = null

    /** The end under way's callback (until the windows got there, or WM Shell called it off). */
    private var ending: ((Boolean) -> Unit)? = null

    /** An app window of the transition and where it was. */
    private class Leash(
        val surface: SurfaceControl,
        val bounds: Rect,
    )

    /** The look of the windows: scale, the bottom edge's lift, opacity. */
    private data class Look(
        val scale: Float,
        val lift: Float,
        val alpha: Float,
    )

    private var look = Look(1f, 0f, 1f)

    /** The finger is [lift] px above where it went down. */
    fun drag(lift: Float) {
        if (state == State.DONE || state == State.ENDING) return
        this.lift = lift
        look = dragLook(lift)
        apply(look)
    }

    /** The gesture ended as [end]: animate there and finish; [done] hears whether the transition did it. */
    fun end(
        end: End,
        done: (Boolean) -> Unit,
    ) {
        when (state) {
            State.STARTING -> {
                pending = end to done
                // The start never came: give up (it's finished the moment it comes, if it does).
                main.postDelayed({
                    if (state == State.STARTING && pending != null) {
                        val (_, cb) = pending!!
                        pending = null
                        state = State.DONE
                        abandoned = end
                        Log.w(TAG, "the recents transition didn't start in time: the plain way")
                        cb(false)
                    }
                }, START_TIMEOUT_MS)
            }
            State.RUNNING -> finishAnimated(end, done)
            State.ENDING -> done(true)
            State.DONE -> done(interrupted)
        }
    }

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
        apps =
            targets.filterNotNull().filter { it.mode == RemoteAnimationTarget.MODE_CLOSING && it.leash != null }.map {
                Leash(it.leash, it.screenSpaceBounds ?: Rect(0, 0, 0, 0))
            }
        state = State.RUNNING
        apply(look)
        main.postDelayed(watchdog, WATCHDOG_MS)
        pending?.let { (end, done) ->
            pending = null
            finishAnimated(end, done)
        }
    }

    /** WM Shell called it off (another transition took over): the windows are WM's again. */
    private fun canceled() {
        if (state == State.DONE) return
        stop()
        pending?.let { (_, done) ->
            pending = null
            done(false)
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
        pending?.let { (_, done) ->
            pending = null
            done(true)
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
                finishAnimated(End.APP) {}
            }
        }

    private fun finishAnimated(
        end: End,
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
                End.HOME -> Look(0.3f, screenHeight * 0.45f, 0f)
                End.SWITCHER -> Look(0.5f, screenHeight * 0.3f, 0f)
                End.APP -> Look(1f, 0f, 1f)
            }
        animator?.cancel()
        animator =
            ValueAnimator.ofFloat(0f, 1f).apply {
                duration = if (toHome) 220 else 180
                interpolator = DecelerateInterpolator()
                addUpdateListener {
                    val f = it.animatedValue as Float
                    look = Look(lerp(from.scale, to.scale, f), lerp(from.lift, to.lift, f), lerp(from.alpha, to.alpha, f))
                    apply(look)
                }
                addListener(
                    object : android.animation.AnimatorListenerAdapter() {
                        override fun onAnimationEnd(animation: android.animation.Animator) {
                            if (state != State.ENDING) return
                            stop()
                            if (c != null) control(c) { finishCall(it, toHome, userLeaveHint = end == End.HOME) }
                            ending?.let { cb ->
                                ending = null
                                cb(true)
                            }
                        }
                    },
                )
                start()
            }
    }

    /** Done with the windows: no more moving them, the leashes let go. */
    private fun stop() {
        state = State.DONE
        main.removeCallbacks(watchdog)
        animator?.cancel()
        animator = null
        controller = null
        apps.forEach { runCatching { it.surface.release() } }
        apps = emptyList()
    }

    private fun dragLook(lift: Float): Look {
        val q = (lift / (screenHeight * 0.5f)).coerceIn(0f, 1f)
        return Look(1f - 0.4f * q, lift, 1f)
    }

    /** The windows as [look] says: scaled about their bottom middle, the bottom edge [Look.lift] px up. */
    private fun apply(look: Look) {
        if (state != State.RUNNING && state != State.ENDING) return
        if (apps.isEmpty()) return
        runCatching {
            val t = SurfaceControl.Transaction()
            for (app in apps) {
                if (!app.surface.isValid) continue
                val w = app.bounds.width().toFloat().takeIf { it > 0 } ?: continue
                val h = app.bounds.height().toFloat().takeIf { it > 0 } ?: continue
                t.setScale(app.surface, look.scale, look.scale)
                t.setPosition(app.surface, app.bounds.left + w * (1 - look.scale) / 2, app.bounds.top + h * (1 - look.scale) - look.lift)
                t.setAlpha(app.surface, look.alpha)
            }
            t.apply()
        }.onFailure { Log.w(TAG, "can't move the app's window", it) }
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
            screenHeight: Float,
        ): RecentsTransition? {
            HiddenApi.allow()
            val transition = RecentsTransition(screenHeight)
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
