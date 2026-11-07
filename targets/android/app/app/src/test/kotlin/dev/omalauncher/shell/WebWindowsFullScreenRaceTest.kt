package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * FS10 (11-07 03:14, Besiege unfolded: Steam's window on screen, the status bar up, no game layer composed, although
 * "full screen" was logged 140 ms after home's surface was made again). The page's placements ride home's NEXT DRAW
 * (applyTransactionOnDraw); right after a new surface that draw waits on its first-frame sync, so a placement queued
 * before the full-screen move landed after it and undid it. The model below is SurfaceControl's: transactions applied
 * in order, a later write of a property wins; queued-on-draw ones go out together, in the order they were queued, when
 * home draws. The source checks pin WebWindows to the order the model proves right.
 */
class WebWindowsFullScreenRaceTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n    }\n")

    /** One container's layer state: its parent and whether it shows. */
    private data class Layer(val parent: String, val shown: Boolean)

    private class Screen {
        var layer = Layer("root", false)
        private val onDraw = mutableListOf<Layer>()

        fun applyNow(l: Layer) {
            layer = l
        }

        fun queueOnDraw(l: Layer) {
            onDraw += l
        }

        fun draw() {
            onDraw.forEach { layer = it }
            onDraw.clear()
        }
    }

    private val pagePlaced = Layer("root", false) // a new window the page has not laid out yet: hidden under the root
    private val full = Layer("home's surface", true)

    @Test
    fun aPlacementQueuedBeforeTheFullScreenNoLongerLandsLast() {
        // Before: the page's placement queued, the full screen applied now, home's (held) first draw lands last.
        val before = Screen().apply { queueOnDraw(pagePlaced); applyNow(full); draw() }
        assertEquals("the race as seen (game hidden)", pagePlaced, before.layer)
        // Now: the full-screen state is queued on the draw too, after the placement.
        val now = Screen().apply { queueOnDraw(pagePlaced); applyNow(full); queueOnDraw(full); draw() }
        assertEquals(full, now.layer)
    }

    @Test
    fun leavingFullScreenQueuesItsOwnPlaceAfterTheRestate() {
        val back = Layer("root", true)
        val s = Screen().apply { applyNow(full); queueOnDraw(full); applyNow(back); queueOnDraw(back); draw() }
        assertEquals("a restate still queued put the window back over everything", back, s.layer)
    }

    /** WebWindows does what the model needs: one writer, queued on draw after the immediate write, the way out queued too. */
    @Test
    fun webWindowsKeepsTheOrder() {
        val fill = body("private fun fillScreen(")
        assertTrue("fillScreen writes the layer through fullLayer", fill.contains("fullLayer(t, win)"))
        assertTrue("the restate is queued after the immediate write", fill.indexOf("t.apply()") in 0 until fill.indexOf("restateFull("))
        val restate = body("private fun restateFull(")
        assertTrue("restateFull no longer rides home's next draw", restate.contains("applyTransactionOnDraw(t)"))
        assertTrue("restateFull doesn't ask home to draw", restate.contains("web.invalidate()"))
        assertTrue("no direct restate after the draw path settles", restate.contains("FULL_RESTATE_MS") && restate.contains("restateNow("))
        val now = body("private fun restateNow(")
        assertTrue("a window that left full screen is restated", now.contains("it.linuxFull && !it.closed"))
        assertTrue("the immersive status bar isn't asked hidden again", now.contains("statusBarHidden()"))
        val again = body("private fun fullAgain(")
        assertTrue("home's new surface doesn't restate after its first draw", again.contains("restateFull("))
        val off = src.substringAfter("private fun linuxFullScreen(").substringBefore("\n    }\n")
        assertTrue("leaving full screen doesn't queue its place after a queued restate", off.contains("backOnDraw(win)"))
        val layer = body("private fun fullLayer(")
        assertTrue(layer.contains("setLayer(c, FULL_LAYER)") && layer.contains("setVisibility(c, fullVisible(win))"))
        // Only fullLayer hangs a full-screen container on home's surface.
        assertEquals(1, Regex("""buildReparentTransaction\(c\)""").findAll(src).count())
    }
}
