package dev.omalauncher.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The recording ring's hole (11-25: "the camera ring is too big compared to the camera size" - it was sized from the
 * padded cutout box). OnePlus Open, read off the phone: cover cutout box [521,595) x [0,126), OEM hole 523,29:594,100;
 * inner 2268x2440, box [2142,2268) x [0,126), OEM hole 2144,46:2220,122. Both cutout paths are plain rectangles.
 */
class CameraHoleTest {
    private val coverBox = BarRect(521, 0, 595, 126)
    private val innerBox = BarRect(2142, 0, 2268, 126)
    private val coverHole = BarRect(523, 29, 594, 100)
    private val innerHole = BarRect(2144, 46, 2220, 122)

    @Test
    fun parsesTheOemHole() {
        assertEquals(innerHole, CameraHole.parse("2144,46:2220,122"))
        assertNull(CameraHole.parse(""))
        assertNull(CameraHole.parse("1,2:3"))
        assertNull(CameraHole.parse("5,5:1,1"))
    }

    @Test
    fun theDeclaredHoleInsideThisScreensBox() {
        val both = listOf(innerHole, coverHole)
        assertEquals(coverHole, CameraHole.inside(coverBox, both, null))
        assertEquals(innerHole, CameraHole.inside(innerBox, both, null))
    }

    @Test
    fun theTracedShapeWhenNoneIsDeclared() {
        val circle = BarRect(520, 40, 560, 80)
        assertEquals(circle, CameraHole.inside(BarRect(500, 0, 580, 90), listOf(innerHole), circle))
    }

    @Test
    fun elseTheCircleCentredInTheBox() {
        assertEquals(BarRect(521, 26, 595, 100), CameraHole.inside(coverBox, emptyList(), null))
    }

    @Test
    fun turnsWithTheDisplay() {
        // The inner screen turned 90 (the hole top-right upright ends up top-left): RotationUtils' physical -> logical.
        assertEquals(BarRect(46, 48, 122, 124), CameraHole.turn(innerHole, 1, 2268, 2440))
        assertEquals(innerHole, CameraHole.turn(innerHole, 0, 2268, 2440))
        assertEquals(BarRect(48, 2318, 124, 2394), CameraHole.turn(innerHole, 2, 2268, 2440))
        // A scaled resolution (wm size at half): the hole halves too.
        assertEquals(BarRect(1072, 23, 1110, 61), CameraHole.turn(innerHole, 0, 2268, 2440, 0.5f))
    }

    @Test
    fun aRectangleFillsItsBoundsACircleDoesNot() {
        assertEquals(1f, CameraHole.fill(listOf(coverBox), coverBox), 0.001f)
        val rows = (0 until 40).map { y -> val dy = y - 19.5; val half = Math.sqrt(400 - dy * dy).toInt(); BarRect(20 - half, y, 20 + half, y + 1) }
        assert(CameraHole.fill(rows, BarRect(0, 0, 40, 40)) < 0.95f)
    }
}
