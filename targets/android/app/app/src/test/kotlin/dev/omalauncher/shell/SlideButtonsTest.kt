package dev.omalauncher.shell

import andro.marchy.SlideButtons
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The touch controller's buttons work like a real pad (board on-screen-game-controls-slide-a-finger-between-b, user:
 * "can't slide your finger between the on-screen buttons"): sliding A -> B presses B and releases A, a finger on the
 * border of two face buttons presses both, and every finger is independent.
 */
class SlideButtonsTest {
    // The default layout's face-button diamond on a 2484x1116 landscape screen: A bottom, B right, X left, Y top.
    private val h = 1116f
    private val w = 2484f
    private val r = 0.045f * h
    private fun c(fx: Float, fy: Float) = floatArrayOf(fx * w, fy * h, r)
    private val a = c(0.785f, 0.825f)
    private val b = c(0.865f, 0.725f)
    private val x = c(0.705f, 0.725f)
    private val y = c(0.785f, 0.625f)
    private val names = "ABXY"

    private class Log : SlideButtons.Sink {
        val events = mutableListOf<String>()
        val held = sortedSetOf<Char>()
        override fun press(button: Int) { events += "+${"ABXY"[button]}"; held += "ABXY"[button] }
        override fun release(button: Int) { events += "-${"ABXY"[button]}"; held -= "ABXY"[button] }
    }

    private fun pad(): SlideButtons = SlideButtons().apply {
        slop = 4f / 25.4f * 160f * 2.75f // 4 mm at density 2.75
        assertTrue(setButtons(a + b + x + y))
        assertEquals(names.length, count())
    }

    @Test
    fun tapCentrePressesOnlyThatButton() {
        val p = pad(); val s = Log()
        assertTrue(p.down(0, a[0], a[1], s))
        assertEquals(setOf('A'), s.held)
        p.up(0, s)
        assertEquals(listOf("+A", "-A"), s.events)
    }

    @Test
    fun slideAToBPressesBReleasesA() {
        val p = pad(); val s = Log()
        p.down(0, a[0], a[1], s)
        // Slide in steps from A's centre to B's centre.
        for (i in 1..20) p.move(0, a[0] + (b[0] - a[0]) * i / 20, a[1] + (b[1] - a[1]) * i / 20, s)
        assertEquals(setOf('B'), s.held)
        assertTrue(s.events.indexOf("+B") >= 0 && s.events.indexOf("-A") >= 0)
        // Off every button: nothing held, the finger is still tracked and can slide back on.
        p.move(0, b[0] + 4 * r, b[1], s)
        assertTrue(s.held.isEmpty())
        p.move(0, b[0], b[1], s)
        assertEquals(setOf('B'), s.held)
        p.up(0, s)
        assertTrue(s.held.isEmpty())
    }

    @Test
    fun fingerOnBorderOfTwoPressesBoth() {
        val p = pad(); val s = Log()
        // Diagonal between A and B: the midpoint of their centres.
        assertTrue(p.down(0, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2, s))
        assertEquals(setOf('A', 'B'), s.held)
        p.up(0, s)
        assertTrue(s.held.isEmpty())
    }

    @Test
    fun missesEveryButtonIsNotTracked() {
        val p = pad(); val s = Log()
        assertFalse(p.down(0, 10f, 10f, s))
        assertFalse(p.tracks(0))
        assertTrue(s.events.isEmpty())
    }

    @Test
    fun twoFingersIndependent() {
        val p = pad(); val s = Log()
        p.down(0, a[0], a[1], s)
        p.down(1, y[0], y[1], s)
        assertEquals(setOf('A', 'Y'), s.held)
        // Finger 1 slides Y -> X; finger 0 stays on A.
        p.move(1, x[0], x[1], s)
        assertEquals(setOf('A', 'X'), s.held)
        // Both fingers on B: it stays pressed until the last one leaves.
        p.move(0, b[0], b[1], s)
        p.move(1, b[0], b[1], s)
        assertEquals(setOf('B'), s.held)
        p.up(0, s)
        assertEquals(setOf('B'), s.held)
        p.up(1, s)
        assertTrue(s.held.isEmpty())
        assertEquals(1, s.events.count { it == "+B" })
    }

    @Test
    fun geometryKeptUnderAFinger() {
        val p = pad(); val s = Log()
        p.down(0, a[0], a[1], s)
        assertFalse(p.setButtons(floatArrayOf()))
        p.up(0, s)
        assertTrue(p.setButtons(floatArrayOf()))
    }
}
