package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Windows back with home at once (the user, 11-01 15:48: "should be more or less instant"). Home's surface is back
 * mid-swipe; its windows' root stayed hidden "under the switcher" until the finger let go (window log: 113-714 ms
 * after "surfaceCreated: windows' root re-attached"). Now a swipe past its home point shows them, and home's surface
 * coming back keeps every layer (re-parented in its first frame's transaction, never released or blanked).
 */
class WebWindowsHomeReturnTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
    private val switcher = File("src/main/kotlin/dev/omalauncher/system/Switcher.kt").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n    }\n")

    @Test
    fun rootShowsWhenHomeIsWhatShows() {
        assertTrue(WebWindows.rootShownFor(switcherOpen = false, homeBound = false))
        assertFalse(WebWindows.rootShownFor(switcherOpen = true, homeBound = false))
        assertTrue(WebWindows.rootShownFor(switcherOpen = true, homeBound = true))
        assertTrue(WebWindows.swipeShowsHome(1f))
        assertFalse(WebWindows.swipeShowsHome(0.99f))
        assertFalse(WebWindows.swipeShowsHome(0f))
    }

    /** The swipe's frames decide it, and a new swipe starts headed for the switcher. */
    @Test
    fun swipeDrivesIt() {
        val drag = switcher.substringAfter("fun drag(").substringBefore("\n    }\n")
        assertTrue(drag.contains("homeBound = dev.omalauncher.shell.WebWindows.swipeShowsHome(homeness)"))
        val begin = switcher.substringAfter("fun begin(").substringBefore("\n    }\n")
        assertTrue(begin.indexOf("homeBound = false") in 0 until begin.indexOf("open = true"))
        assertTrue(switcher.contains("WebWindows.switcherOpen(v, homeBound)"))
    }

    /** A full-screen Linux window (above home's buffer) stays hidden until the swipe ends: it would cover home. */
    @Test
    fun overHomeWaitsForTheEnd() {
        assertTrue(src.contains("ww.rootShown(rootShownFor(open, homeBound), !open)"))
        assertTrue(body("private fun rootShown(").contains("t.setVisibility(w.container, over && w.shown)"))
    }

    /** Home's surface back: the root re-parented in that surface's first-frame transaction; no layer released or hidden. */
    @Test
    fun surfaceBackKeepsLayers() {
        val call = src.substringAfter("\"surfaceCreated\", \"surfaceReplaced\" -> {").substringBefore("}")
        assertTrue(call.contains("reattach(args?.getOrNull(0) as? SurfaceControl.Transaction"))
        val reattach = body("private fun reattach(")
        assertTrue(reattach.contains("if (t != null) t.merge(re) else re.apply()"))
        assertFalse(reattach.contains("setVisibility"))
        assertFalse(reattach.contains(".release()"))
        val destroyed = src.substringAfter("\"surfaceDestroyed\" ->").substringBefore("\n")
        assertFalse(destroyed.contains("release") || destroyed.contains("setVisibility"))
    }
}
