package dev.omalauncher.system.gesture

import dev.omalauncher.system.gesture.EdgeGestureClassifier.Direction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EdgeGestureClassifierTest {
    private val density = 2.5f
    private val width = 1080f

    /** A swipe on the [right] edge from y 1800 by ([dx] inwards, [dy]) over [ms], then [holdMs] still, then let go. */
    private fun swipe(
        right: Boolean,
        dx: Float,
        dy: Float,
        ms: Long = 120,
        holdMs: Long = 0,
    ): EdgeGestureClassifier.Gesture? {
        val c = EdgeGestureClassifier(right, density)
        val x0 = if (right) width - 4f else 4f
        val y0 = 1800f
        c.down(x0, y0, 0)
        var t = 0L
        val steps = (ms / 8).coerceAtLeast(1)
        var x = x0
        var y = y0
        for (i in 1..steps) {
            t = i * 8
            x = x0 + (if (right) -dx else dx) * i / steps
            y = y0 + dy * i / steps
            c.move(x, y, t)
        }
        // The host's timer asks while the finger rests.
        var h = t
        while (h < t + holdMs) {
            h += 50
            c.hold(h)
        }
        return c.up(x, y, t + holdMs)
    }

    @Test fun straightIn() = assertEquals(EdgeGestureClassifier.Gesture(Direction.STRAIGHT, false), swipe(true, 200f, 20f))

    @Test fun leftEdgeToo() = assertEquals(EdgeGestureClassifier.Gesture(Direction.STRAIGHT, false), swipe(false, 200f, -10f))

    @Test fun diagonalUp() = assertEquals(Direction.UP, swipe(true, 150f, -150f)?.direction)

    @Test fun diagonalDown() = assertEquals(Direction.DOWN, swipe(false, 150f, 150f)?.direction)

    @Test fun heldIsLong() {
        val g = swipe(true, 150f, -150f, holdMs = 400)
        assertEquals(Direction.UP, g?.direction)
        assertTrue(g!!.long)
        assertEquals("long.up", g.key)
    }

    @Test fun shortHoldIsShort() = assertEquals("short.straight", swipe(true, 200f, 0f, holdMs = 150)?.key)

    @Test fun tooShortIsNothing() = assertNull(swipe(true, 30f, 0f))

    @Test fun alongTheEdgeIsNothing() = assertNull(swipe(true, 20f, -300f))

    @Test fun outwardsIsNothing() = assertNull(swipe(false, -200f, 0f))
}
