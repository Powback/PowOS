package andro.marchy

import org.junit.Assert.assertEquals
import org.junit.Test

/** The games' built-in fps counter (GameFpsCounter): presented frames per second between two reads. */
class GameFpsCounterTest {
    @Test
    fun ratesFromPresentedCounts() {
        assertEquals(60, GameFpsCounter.fps(100, 1_000, 130, 1_500))
        assertEquals(23, GameFpsCounter.fps(0, 0, 46, 2_000)) // ABZU-like 23 fps
        assertEquals(0, GameFpsCounter.fps(500, 0, 500, 500)) // a stalled game: 0, not a dash
    }

    @Test
    fun nothingToTell() {
        assertEquals(-1, GameFpsCounter.fps(-1, 0, 30, 500)) // the first read
        assertEquals(-1, GameFpsCounter.fps(10, 500, 20, 500)) // no time passed
        assertEquals(-1, GameFpsCounter.fps(900, 0, 12, 500)) // a new consumer counts from zero again
    }

    @Test
    fun labels() {
        assertEquals("-- fps", GameFpsCounter.label(-1))
        assertEquals("120 fps", GameFpsCounter.label(120))
    }
}
