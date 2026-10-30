package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The web windows' layer order check (the user, 2026-10-30 21:31: "titlebar z issue still" - Brave, a Linux window, was
 * above Calculator in the page, its bar over Calculator's, yet Calculator's app layer drew over Brave's content).
 * SurfaceFlinger's output for the inner display then: Wallpaper, HomeShell, [BBQ] powos-ww-1-linux, Calculator.
 */
class WebWindowsLayerOrderTest {
    private val dump =
        """
        Display 4630946704981769859 (physical, "")
           Composition Display State:
           isEnabled=true isSecure=true usesDeviceComposition=true
           10 Layers
          - Output Layer 0xb4000073131a6e00(Wallpaper BBQ wrapper#1670)
                Region visibleRegion (this=0xb4000073131a6e20, count=1)
          - Output Layer 0xb40000730583da00(com.powos.app/andro.marchy.HomeShell#22780)
          - Output Layer 0xb400007313098400([BBQ] powos-ww-1-linux#22809#22810)
          - Output Layer 0xb4000073132d5400(com.oneplus.calculator/com.android.calculator2.Calculator#22855)
          - Output Layer 0xb4000073132daa00(PowOS panel anchor#22679)
        Display 4630946316123810436 (physical, "")
           Composition Display State:
           isEnabled=false isSecure=true
          - Output Layer 0xb4000073059fce00(StatusBar#1701)
        """.trimIndent()

    @Test
    fun readsTheEnabledDisplaysOutputBottomFirst() {
        val layers = WebWindows.outputLayers(dump)
        assertNotNull(layers)
        assertEquals("[BBQ] powos-ww-1-linux#22809#22810", layers!![2])
        assertEquals(5, layers.size)
    }

    @Test
    fun theUsersCaseIsReported() {
        val layers = WebWindows.outputLayers(dump)!!
        // Page: Calculator (2) at the bottom, Brave (1) above it.
        val at = mapOf(2 to layers.indexOfFirst { it.contains("com.oneplus.calculator/") }, 1 to layers.indexOfFirst { it.contains("powos-ww-1-linux") })
        val d = WebWindows.orderDivergence(listOf(2, 1), at)
        assertNotNull(d)
        assertTrue(d!!, d.startsWith("window 1 is above window 2 in the page but drawn under it"))
    }

    @Test
    fun agreeingOrUncomposedWindowsAreQuiet() {
        assertNull(WebWindows.orderDivergence(listOf(1, 2), mapOf(1 to 2, 2 to 3)))
        assertNull("one not composed (occluded, off screen): nothing to compare", WebWindows.orderDivergence(listOf(2, 1), mapOf(1 to 2, 2 to -1)))
    }

    @Test
    fun noEnabledDisplayWithHomeIsNull() {
        assertNull(WebWindows.outputLayers(dump.replace("isEnabled=true", "isEnabled=false")))
    }

    /** Wired: every apply schedules the check, and a Linux window is placed back under the root before its z is set. */
    @Test
    fun wired() {
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        assertTrue(src.contains("orderCheckSoon(geos)"))
        val place = src.substringAfter("private fun place(").substringBefore("private fun ")
        assertTrue("place() re-parents a stray container before its z", place.indexOf("underRoot(t, win)") in 0 until place.indexOf("t.setLayer(c, g.z)"))
    }
}
