package dev.omalauncher.system.gesture

import kotlin.math.abs
import kotlin.math.hypot

/**
 * What a finger that went down on the navigation bar's strip means (gesture navigation): pure logic, no Android, so it's
 * unit-tested (NavGestureClassifierTest). Coordinates are screen pixels (y grows downwards), times milliseconds.
 *
 * - A swipe up shows the switcher from its start (the app's window shrinks into its card); where it's let go decides,
 *   by position and speed only - no waiting, no hold needed:
 *   - flung up ([homeFlingSpeed]) or let go high ([homeDistance], near the top: the home zone, [homeness]) → home;
 *   - let go anywhere between, at a relaxed speed → the switcher;
 *   - hardly moved ([minDistance]) or flung back down → nothing (back to the app).
 * - The direction is decided once the finger has moved [slop] px: mostly up is the swipe up, mostly sideways the quick
 *   switch (past [switchDistance] or flung sideways), down is nothing (the windows under it keep the touch).
 * - [armed] (held still a moment, as Quickstep's MotionPauseDetector) is kept for the log and the feel only: a hold
 *   lands in the switcher like any relaxed release.
 *
 * Ported in spirit from AOSP Launcher3 Quickstep (Apache-2.0: OtherActivityInputConsumer, MotionPauseDetector), with
 * thresholds of its own.
 */
class NavGestureClassifier(
    private val density: Float,
    /** The screen's height (px): the distances that go home scale with it. */
    screenHeight: Float,
    /** The system's touch slop (px). */
    private val slop: Float = 8f * density,
) {
    private val holdMinDistance = 48f * density

    /** Less than this up and let go: back to the app (a nudge, not a swipe). */
    private val minDistance = 48f * density
    private val pauseSpeed = 0.12f * density // px/ms
    private val holdMs = 140L
    private val flingSpeed = 0.9f * density // px/ms

    /**
     * Up this fast at the release goes home: a flick (1.2 dp/ms - a relaxed swipe slows to under half that by its
     * release, so it lands in the switcher).
     */
    private val homeFlingSpeed = 1.2f * density // px/ms

    /** Let go this high (half the screen up): home - the home zone the switcher fades out over ([homeness]). */
    private val homeDistance = screenHeight * 0.5f

    /** Where the home zone starts fading the switcher out (the cards fully up by here). */
    private val homeZoneStart = screenHeight * 0.3f
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

    /** Why [up] decided what it did (for the log: the numbers it went by). */
    var why = ""
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
        why = "lift ${lift.toInt()} px (app under ${minDistance.toInt()}, home over ${homeDistance.toInt()}), vy ${"%.2f".format(-vy / density)} dp/ms (home over ${"%.2f".format(homeFlingSpeed / density)}), armed $armed"
        return when (axis) {
            Axis.UP ->
                when {
                    vy >= flingSpeed -> Outcome.None
                    lift < minDistance -> Outcome.None
                    -vy >= homeFlingSpeed -> Outcome.Home
                    lift >= homeDistance -> Outcome.Home
                    else -> Outcome.Switcher
                }
            Axis.SIDEWAYS -> {
                val dx = x - x0
                if (abs(dx) >= switchDistance || abs(vx) >= flingSpeed) Outcome.QuickSwitch(rightwards = (if (abs(vx) >= flingSpeed) vx else dx) > 0) else Outcome.None
            }
            Axis.NONE, Axis.IGNORED -> Outcome.None
        }
    }

    /**
     * How far into the home zone [lift] is: 0 below [homeZoneStart], 1 at [homeDistance] - where letting go goes home.
     * The switcher fades out and home comes in as it rises, so it's plain where the release will land.
     */
    fun homeness(lift: Float = this.lift): Float = ((lift - homeZoneStart) / (homeDistance - homeZoneStart)).coerceIn(0f, 1f)

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
