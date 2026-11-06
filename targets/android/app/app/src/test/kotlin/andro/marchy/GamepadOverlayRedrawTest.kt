package andro.marchy

import android.view.MotionEvent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The on-screen pad redraws only when something on it changes: a finger held on a button / the d-pad reports moves
 * that change nothing (11-06 live Broforce play: com.powos.app main 11.4 %, RenderThread 5 % under the full-screen game).
 */
class GamepadOverlayRedrawTest {
    @Test
    fun heldButtonMovesDoNotRedraw() {
        assertFalse(GamepadOverlay.redraws(MotionEvent.ACTION_MOVE, false, false))
    }

    @Test
    fun stateChangeOrStickKnobRedraws() {
        assertTrue(GamepadOverlay.redraws(MotionEvent.ACTION_MOVE, true, false))
        assertTrue(GamepadOverlay.redraws(MotionEvent.ACTION_MOVE, false, true))
    }

    @Test
    fun downAndUpAlwaysRedraw() {
        for (a in intArrayOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP)) {
            assertTrue(GamepadOverlay.redraws(a, false, false))
        }
    }
}
