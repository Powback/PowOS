package dev.omalauncher.system.gesture

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.input.InputManager
import android.os.Looper
import android.util.Log
import android.view.InputChannel
import android.view.InputEvent
import android.view.InputEventReceiver
import android.view.InputMonitor
import android.view.MotionEvent
import dev.omalauncher.system.HiddenApi

/**
 * PowOS's system gesture input, as Quickstep's TouchInteractionService has it: an input monitor on the display
 * (InputManager.monitorGestureInput, which the recents role's MONITOR_INPUT allows) sees every touch without being a
 * window in the way, and takes a gesture from the windows under it ([InputMonitor.pilferPointers]: they get a cancel)
 * only once it's recognised as one of PowOS's. Taps and everything else go through untouched.
 *
 * [consumers] are asked in order on each finger down; the first that takes it follows the gesture to its end
 * ([GestureConsumer]). Runs on the main looper.
 *
 * HACK: InputManager.monitorGestureInput, InputMonitor and InputEventReceiver are hidden API (compiled against
 * stand-ins, hidden-stubs/; let past the runtime checks by [HiddenApi]). Real fix: none for an app - the system's own
 * gesture providers (Quickstep, SystemUI's back gesture) are platform-signed and call them directly.
 */
class GestureMonitor private constructor(
    private val monitor: InputMonitor,
    private val consumers: List<GestureConsumer>,
) {
    private val receiver = Receiver(monitor.inputChannel, Looper.getMainLooper(), ::dispatch)

    /** The consumer following the current gesture, and whether it has taken it from the windows. */
    private var active: GestureConsumer? = null
    private var pilfered = false

    fun dispose() {
        cancelActive()
        runCatching { receiver.dispose() }
        runCatching { monitor.dispose() }
    }

    private fun dispatch(e: MotionEvent) {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                cancelActive()
                pilfered = false
                active = consumers.firstOrNull { runCatching { it.onDown(e) }.onFailure { t -> Log.w(TAG, "gesture consumer failed", t) }.getOrDefault(false) }
                // A consumer whose zone is all its own (the edge handles): taken on the down, before anything under it
                // - SystemUI's edge-back gesture included - can decide it's theirs.
                if (active?.takesOnDown == true) {
                    pilfered = true
                    runCatching { monitor.pilferPointers() }.onFailure { Log.w(TAG, "can't take the gesture from the windows", it) }
                }
            }
            else -> {
                val consumer = active ?: return
                val verdict = runCatching { consumer.onEvent(e) }.onFailure { Log.w(TAG, "gesture consumer failed", it) }.getOrDefault(GestureConsumer.Verdict.DROP)
                when (verdict) {
                    GestureConsumer.Verdict.TAKE ->
                        if (!pilfered) {
                            pilfered = true
                            runCatching { monitor.pilferPointers() }.onFailure { Log.w(TAG, "can't take the gesture from the windows", it) }
                        }
                    GestureConsumer.Verdict.DROP -> active = null
                    GestureConsumer.Verdict.FOLLOW -> {}
                }
                if (e.actionMasked == MotionEvent.ACTION_UP || e.actionMasked == MotionEvent.ACTION_CANCEL) active = null
            }
        }
    }

    /** Tells the consumer following a gesture that it's over (a new one began, or the monitor goes). */
    private fun cancelActive() {
        val consumer = active ?: return
        active = null
        val now = android.os.SystemClock.uptimeMillis()
        val e = MotionEvent.obtain(now, now, MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
        runCatching { consumer.onEvent(e) }
        e.recycle()
    }

    /**
     * The monitor's channel, read on the main looper. Kept from R8's renaming (proguard-rules.pro): the framework
     * calls [onInputEvent] by name.
     */
    private class Receiver(
        channel: InputChannel,
        looper: Looper,
        private val sink: (MotionEvent) -> Unit,
    ) : InputEventReceiver(channel, looper) {
        override fun onInputEvent(event: InputEvent) {
            try {
                if (event is MotionEvent) sink(event)
            } catch (t: Throwable) {
                Log.w(TAG, "gesture input failed", t)
            } finally {
                finishInputEvent(event, true)
            }
        }
    }

    companion object {
        private const val TAG = "PowosGestures"
        private const val PERMISSION_MONITOR_INPUT = "android.permission.MONITOR_INPUT"

        /**
         * The monitor on [displayId], or null where it can't be had (MONITOR_INPUT not granted: PowOS isn't the recents
         * provider; or this Android refuses the hidden calls) - callers then keep their fallbacks.
         */
        fun start(
            context: Context,
            displayId: Int,
            consumers: List<GestureConsumer>,
        ): GestureMonitor? {
            if (context.checkSelfPermission(PERMISSION_MONITOR_INPUT) != PackageManager.PERMISSION_GRANTED) {
                Log.w(TAG, "no gesture input: MONITOR_INPUT not granted (PowOS isn't the recents provider)")
                return null
            }
            HiddenApi.allow()
            return runCatching {
                val im = context.getSystemService(InputManager::class.java)
                val monitor =
                    im.javaClass.getMethod("monitorGestureInput", String::class.java, Int::class.javaPrimitiveType)
                        .invoke(im, "powos-gestures", displayId) as InputMonitor
                GestureMonitor(monitor, consumers)
            }.onFailure { Log.w(TAG, "no gesture input: can't monitor the display", it) }.getOrNull()
        }
    }
}

/** One kind of system gesture the [GestureMonitor] recognises (the nav bar's swipes, the shade's pull). */
interface GestureConsumer {
    enum class Verdict {
        /** Keep sending the gesture; the windows under it keep it too, for now. */
        FOLLOW,

        /** It's this consumer's: the windows under it get a cancel, and the rest comes here alone. */
        TAKE,

        /** Not this consumer's after all: it hears no more of this gesture. */
        DROP,
    }

    /**
     * The gesture is taken from the windows (and the other monitors) as soon as [onDown] says it follows it, not once
     * recognised: for a zone that's wholly the consumer's, where nothing under it may start a gesture of its own.
     */
    val takesOnDown: Boolean get() = false

    /** A finger down (display px, [MotionEvent.getRawX]/Y): true to follow this gesture. */
    fun onDown(e: MotionEvent): Boolean

    /** The followed gesture's next event (moves, more fingers, the lift or a cancel). */
    fun onEvent(e: MotionEvent): Verdict
}
