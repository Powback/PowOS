package dev.omalauncher.system.gesture

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * What a finger that went down on an edge handle means ([EdgeGestures]): pure logic, no Android, so it's unit-tested
 * (EdgeGestureClassifierTest). Screen pixels (y grows downwards), milliseconds.
 *
 * - The finger moves in from its edge: once it has travelled [trigger] px (mostly inwards), the swipe's direction is
 *   decided and kept - straight in (within [STRAIGHT_DEG] of level), diagonally up or diagonally down (up to
 *   [DIAGONAL_DEG]). Steeper than that it runs along the edge: not an edge gesture.
 * - Short or long: held still ([HOLD_MS] without moving [stillSlop]) once decided, it's long - a "swipe and hold", as
 *   Good Lock's One Hand Operation+ has it. [hold] is asked by the host's timer, so a finger that rests without sending
 *   moves still arms it.
 * - Let go before [trigger]: nothing.
 */
class EdgeGestureClassifier(
    /** The handle's side: true for the right edge (inwards is leftwards). */
    private val right: Boolean,
    density: Float,
    /** The travel (px) that makes it a swipe: the sensitivity setting. */
    private val trigger: Float = 28f * density,
) {
    private val stillSlop = 6f * density

    enum class Direction(val key: String) { STRAIGHT("straight"), UP("up"), DOWN("down") }

    data class Gesture(val direction: Direction, val long: Boolean) {
        /** The settings' key: "short.straight" ... "long.down". */
        val key get() = "${if (long) "long" else "short"}.${direction.key}"
    }

    private var x0 = 0f
    private var y0 = 0f

    /** The decided direction (null: not yet, or never). */
    var direction: Direction? = null
        private set

    /** Ran along the edge instead: nothing more to decide. */
    var rejected = false
        private set

    /** Held still once decided: a long swipe. */
    var long = false
        private set

    private var stillX = 0f
    private var stillY = 0f
    private var stillAt = 0L

    /** How far in (px) the finger is from where it went down, inwards positive. */
    var inward = 0f
        private set

    fun down(
        x: Float,
        y: Float,
        t: Long,
    ) {
        x0 = x
        y0 = y
        direction = null
        rejected = false
        long = false
        inward = 0f
        still(x, y, t)
    }

    /** A move: the direction just decided (once), or null. */
    fun move(
        x: Float,
        y: Float,
        t: Long,
    ): Direction? {
        inward = if (right) x0 - x else x - x0
        if (rejected) return null
        val d = direction
        if (d != null) {
            if (hypot(x - stillX, y - stillY) > stillSlop) still(x, y, t)
            hold(t)
            return null
        }
        val dy = y - y0
        if (hypot(inward, dy) < trigger) return null
        // Outwards, or steeper than a diagonal: the finger runs along the edge (or off it).
        val angle = Math.toDegrees(atan2(abs(dy).toDouble(), inward.toDouble()))
        if (inward <= 0f || angle > DIAGONAL_DEG) {
            rejected = true
            return null
        }
        val decided = if (angle <= STRAIGHT_DEG) Direction.STRAIGHT else if (dy < 0) Direction.UP else Direction.DOWN
        direction = decided
        still(x, y, t)
        return decided
    }

    /** The time is [t] with the finger where it was: true if this makes it long (once). */
    fun hold(t: Long): Boolean {
        if (direction == null || long || rejected) return false
        if (t - stillAt < HOLD_MS) return false
        long = true
        return true
    }

    /** Let go: the gesture, or null (not far enough, or along the edge). */
    fun up(
        x: Float,
        y: Float,
        t: Long,
    ): Gesture? {
        move(x, y, t)
        val d = direction ?: return null
        if (rejected) return null
        return Gesture(d, long)
    }

    private fun still(
        x: Float,
        y: Float,
        t: Long,
    ) {
        stillX = x
        stillY = y
        stillAt = t
    }

    companion object {
        /** Within this of level (degrees): straight in. */
        const val STRAIGHT_DEG = 30.0

        /** Steeper than this: along the edge, not an edge gesture. */
        const val DIAGONAL_DEG = 75.0

        /** Held still this long once decided: a long swipe. */
        const val HOLD_MS = 300L
    }
}
