package dev.omalauncher.system.gesture

import kotlin.math.abs
import kotlin.math.hypot

/**
 * What a finger that went down on the navigation bar's strip means (gesture navigation): pure logic, no Android, so it's
 * unit-tested (NavGestureClassifierTest). Coordinates are screen pixels (y grows downwards), times milliseconds.
 *
 * - Swipe up and let go: home. Swipe up and hold still a moment: the switcher. Along the bottom edge: the previous app.
 * - The direction is decided once the finger has moved [slop] px: mostly up is the swipe up, mostly sideways the quick
 *   switch, down is nothing (the windows under it keep the touch).
 * - "Hold": after at least [holdMinDistance] up, the finger slower than [pauseSpeed] for [holdMs]. Moving on fast again
 *   un-arms it (as Quickstep's MotionPauseDetector).
 * - Let go: armed and not flung up → switcher; flung up ([flingSpeed]) or past [homeDistance] → home; else nothing
 *   (back to the app). Sideways: past [switchDistance] or flung sideways → quick switch.
 *
 * Ported in spirit from AOSP Launcher3 Quickstep (Apache-2.0: OtherActivityInputConsumer, MotionPauseDetector), with
 * thresholds of its own.
 */
class NavGestureClassifier(
    density: Float,
    /** The screen's height (px): the distances that go home scale with it. */
    screenHeight: Float,
    /** The system's touch slop (px). */
    private val slop: Float = 8f * density,
) {
    private val holdMinDistance = 48f * density
    private val pauseSpeed = 0.12f * density // px/ms
    private val holdMs = 140L
    private val flingSpeed = 0.9f * density // px/ms
    private val homeDistance = screenHeight * 0.22f
    private val switchDistance = 56f * density

    enum class Axis { NONE, UP, SIDEWAYS, IGNORED }

    sealed interface Outcome {
        data object None : Outcome

        data object Home : Outcome

        data object Switcher : Outcome

        /** Along the bottom edge; [rightwards]: the finger went right (to the previous app, as Android's). */
        data class QuickSwitch(
            val rightwards: Boolean,
        ) : Outcome
    }

    var axis = Axis.NONE
        private set

    /** The swipe up is held still: let go now and it's the switcher. */
    var armed = false
        private set

    /** How far the finger went up since it went down (px, never negative). */
    var lift = 0f
        private set

    private var x0 = 0f
    private var y0 = 0f
    private var pauseSince = -1L
    private val samples = ArrayDeque<Sample>()

    private data class Sample(
        val x: Float,
        val y: Float,
        val t: Long,
    )

    fun down(
        x: Float,
        y: Float,
        t: Long,
    ) {
        x0 = x
        y0 = y
        axis = Axis.NONE
        armed = false
        lift = 0f
        pauseSince = -1L
        samples.clear()
        samples.addLast(Sample(x, y, t))
    }

    /** A move: returns the axis when it's decided by this move (else null). */
    fun move(
        x: Float,
        y: Float,
        t: Long,
    ): Axis? {
        record(x, y, t)
        lift = (y0 - y).coerceAtLeast(0f)
        if (axis == Axis.NONE) {
            val dx = x - x0
            val dy = y - y0
            if (hypot(dx, dy) < slop) return null
            axis =
                when {
                    -dy >= abs(dx) -> Axis.UP
                    abs(dx) > abs(dy) -> Axis.SIDEWAYS
                    else -> Axis.IGNORED
                }
            return axis
        }
        if (axis == Axis.UP) {
            val (vx, vy) = velocity()
            val speed = hypot(vx, vy)
            if (lift >= holdMinDistance && speed < pauseSpeed) {
                if (pauseSince < 0) pauseSince = t
                if (t - pauseSince >= holdMs) armed = true
            } else {
                pauseSince = -1L
                if (speed >= pauseSpeed * 3) armed = false
            }
        }
        return null
    }

    /** The finger is lifted at ([x], [y]): what the gesture was. */
    fun up(
        x: Float,
        y: Float,
        t: Long,
    ): Outcome {
        val previous = samples.lastOrNull()?.t ?: t
        record(x, y, t)
        lift = (y0 - y).coerceAtLeast(0f)
        // A finger held still sends no moves: a long enough gap before the release (or a pause that was under way) is
        // a hold too.
        if (axis == Axis.UP && !armed && lift >= holdMinDistance) {
            if (t - previous >= holdMs || (pauseSince >= 0 && t - pauseSince >= holdMs)) armed = true
        }
        val (vx, vy) = velocity()
        return when (axis) {
            Axis.UP ->
                when {
                    -vy >= flingSpeed -> Outcome.Home
                    armed -> Outcome.Switcher
                    vy >= flingSpeed -> Outcome.None
                    lift >= homeDistance -> Outcome.Home
                    else -> Outcome.None
                }
            Axis.SIDEWAYS -> {
                val dx = x - x0
                if (abs(dx) >= switchDistance || abs(vx) >= flingSpeed) Outcome.QuickSwitch(rightwards = (if (abs(vx) >= flingSpeed) vx else dx) > 0) else Outcome.None
            }
            Axis.NONE, Axis.IGNORED -> Outcome.None
        }
    }

    /** px/ms over the last [WINDOW_MS] of samples. */
    private fun velocity(): Pair<Float, Float> {
        if (samples.size < 2) return 0f to 0f
        val last = samples.last()
        val first = samples.first()
        val dt = (last.t - first.t).coerceAtLeast(1L).toFloat()
        return (last.x - first.x) / dt to (last.y - first.y) / dt
    }

    private fun record(
        x: Float,
        y: Float,
        t: Long,
    ) {
        samples.addLast(Sample(x, y, t))
        while (samples.size > 2 && t - samples.first().t > WINDOW_MS) samples.removeFirst()
    }

    private companion object {
        const val WINDOW_MS = 80L
    }
}

/**
 * The shade's pull (ShadeHost): whether a pull from the top edge let go with [velocity] (CSS px/ms, down positive) at
 * openness [q] (0..1) opens the shade - a flick down, or past a third without a flick up. As the page's own swipe.
 */
fun shadeOpens(
    velocity: Float,
    q: Double,
    cancelled: Boolean,
): Boolean = !cancelled && (velocity > SHADE_FLICK || (velocity >= -SHADE_FLICK && q > SHADE_OPEN_AT))

/** CSS px/ms: a flick, as the page's. */
const val SHADE_FLICK = 0.45f

/** The openness the shade opens at when let go without a flick. */
const val SHADE_OPEN_AT = 0.33
