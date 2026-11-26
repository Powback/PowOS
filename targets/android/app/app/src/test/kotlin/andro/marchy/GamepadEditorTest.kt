package andro.marchy

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The controller editor (11-26 user asks): select-then-edit instead of a resize handle on every control at once,
 * Back leaves the editor, and the backpad (cover screen) defaults to R1/R2 with every finger configurable.
 */
class GamepadEditorTest {
    private val a = Any()
    private val b = Any()

    @Test
    fun nothingShowsHandlesUntilSelected() {
        assertFalse(GamepadOverlay.showsHandle(a, null))
        assertFalse(GamepadOverlay.showsHandle(b, null))
    }

    @Test
    fun onlyTheSelectedControlShowsItsHandle() {
        val sel = GamepadOverlay.nextSelection<Any>(null, a)
        assertTrue(GamepadOverlay.showsHandle(a, sel))
        assertFalse(GamepadOverlay.showsHandle(b, sel))
    }

    @Test
    fun tappingAnotherControlMovesTheSelection() {
        assertEquals(b, GamepadOverlay.nextSelection(a, b))
    }

    @Test
    fun tappingEmptySpaceDeselects() {
        assertNull(GamepadOverlay.nextSelection<Any>(a, null))
    }

    @Test
    fun backLeavesTheEditor() {
        assertTrue(GamepadOverlay.backLeavesEditor(true, KeyEvent.KEYCODE_BACK))
    }

    @Test
    fun backIsUntouchedOutsideTheEditorAndOtherKeysPass() {
        assertFalse(GamepadOverlay.backLeavesEditor(false, KeyEvent.KEYCODE_BACK))
        assertFalse(GamepadOverlay.backLeavesEditor(true, KeyEvent.KEYCODE_VOLUME_UP))
    }

    @Test
    fun backpadDefaultsToR1R2() {
        val outs = CoverPadActivity.DEFAULT_OUTPUTS
        assertEquals("rb", outs[3]) // right index -> R1
        assertEquals("rt", outs[4]) // right middle -> R2
        val pressed = BooleanArray(6)
        pressed[3] = true
        assertEquals(PadSender.RB, CoverPadActivity.buttonBits(outs, pressed))
        pressed[3] = false
        pressed[4] = true
        assertEquals(0, CoverPadActivity.buttonBits(outs, pressed))
        assertEquals(1f, CoverPadActivity.trigger(outs, pressed, "rt"), 0f)
        assertEquals(0f, CoverPadActivity.trigger(outs, pressed, "lt"), 0f)
    }

    @Test
    fun everyBackpadOutputMapsToSomething() {
        val pressed = BooleanArray(1) { true }
        for (o in CoverPadActivity.OUTPUTS) {
            val bits = CoverPadActivity.buttonBits(arrayOf(o), pressed) // throws on an unknown button
            val trig = CoverPadActivity.trigger(arrayOf(o), pressed, "lt") + CoverPadActivity.trigger(arrayOf(o), pressed, "rt")
            if (o == "none") assertEquals(0, bits) else assertTrue(o, bits != 0 || trig > 0f)
        }
        assertEquals(CoverPadActivity.OUTPUTS.size, CoverPadActivity.OUTPUT_LABELS.size)
        for (d in CoverPadActivity.DEFAULT_OUTPUTS) assertTrue(d, CoverPadActivity.outputIndex(d) >= 0)
    }
}
