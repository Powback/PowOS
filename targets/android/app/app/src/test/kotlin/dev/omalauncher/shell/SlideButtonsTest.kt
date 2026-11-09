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

    // pad-slide.sh's phone run (job 20261109-230930-16340): the default layout on a 1116x2310 portrait overlay at
    // 420 dpi, one finger B -> Y -> B -> off every button -> B. powos-padd logs one press per button going down.
    private val pw = 1116f
    private val ph = 2310f
    private fun pc(x0: Float, y0: Float, x1: Float, y1: Float) =
        floatArrayOf((x0 + x1) / 2 * pw, (y0 + y1) / 2 * ph, minOf((x1 - x0) * pw, (y1 - y0) * ph) / 2)
    private val pb = pc(0.82f, 0.68f, 0.91f, 0.77f)
    private val py = pc(0.74f, 0.58f, 0.83f, 0.67f)
    private val off = floatArrayOf(0.97f * pw, 0.97f * ph)

    private fun portrait(): SlideButtons = SlideButtons().apply {
        slop = 4f / 25.4f * 420f
        assertTrue(setButtons(pb + py))
    }

    /** "B" for button 0, "Y" for 1; presses only, like powos-padd's log. */
    private class Presses : SlideButtons.Sink {
        val pressed = mutableListOf<String>()
        val held = sortedSetOf<String>()
        override fun press(button: Int) { "BY"[button].toString().let { pressed += it; held += it } }
        override fun release(button: Int) { held -= "BY"[button].toString() }
    }

    private fun path() = listOf(pb, py, pb, off, pb)

    @Test
    fun slidePathBYBOffBPressesBYBB() {
        val p = portrait(); val s = Presses()
        val pts = path()
        assertTrue(p.down(0, pts[0][0], pts[0][1], s))
        for (q in pts.drop(1)) {
            p.slide(0, q[0], q[1], s)
            if (q === off) assertTrue("off every button releases", s.held.isEmpty())
        }
        assertEquals("B Y B B", s.pressed.joinToString(" "))
        p.up(0, s)
        assertTrue(s.held.isEmpty())
    }

    @Test
    fun fingerDroppedMidSlideIsPickedUpAgain() {
        // releaseAll (a focus change switched the layout) forgets every finger mid-gesture; the next moves of the
        // same finger must still press what it slides onto - the phone's "B Y" for "B Y B B".
        val p = portrait(); val s = Presses()
        p.down(0, pb[0], pb[1], s)
        p.slide(0, py[0], py[1], s)
        p.clear(); s.held.clear()
        assertTrue(p.setButtons(pb + py))
        for (q in listOf(pb, off, pb)) p.slide(0, q[0], q[1], s)
        assertEquals("B Y B B", s.pressed.joinToString(" "))
        assertEquals(setOf("B"), s.held)
    }

    @Test
    fun fingerLandingOffButtonsPressesWhatItSlidesOnto() {
        val p = portrait(); val s = Presses()
        assertFalse(p.slide(0, off[0], off[1], s))
        assertTrue(p.slide(0, py[0], py[1], s))
        assertEquals(listOf("Y"), s.pressed)
    }

    @Test
    fun twoFingersSlidePathKeepsTheOtherFingersButton() {
        // Finger 0 rests on B; finger 1 runs the same path. B is held throughout (finger 0 never left it), so the
        // only new presses are B (finger 0) and Y; finger 1 leaving B never releases finger 0's B.
        val p = portrait(); val s = Presses()
        p.down(0, pb[0], pb[1], s)
        p.down(1, pb[0], pb[1], s)
        for (q in path().drop(1)) {
            p.slide(1, q[0], q[1], s)
            assertTrue("B held by finger 0", "B" in s.held)
        }
        assertEquals("B Y", s.pressed.joinToString(" "))
        p.up(0, s)
        assertEquals(setOf("B"), s.held) // finger 1 is back on B
        p.slide(1, off[0], off[1], s)
        assertTrue(s.held.isEmpty())
        p.slide(1, py[0], py[1], s)
        p.up(1, s)
        assertEquals("B Y Y", s.pressed.joinToString(" "))
        assertTrue(s.held.isEmpty())
    }
}
