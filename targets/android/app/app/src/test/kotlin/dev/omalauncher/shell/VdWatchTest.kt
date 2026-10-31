package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VdWatchTest {
    @Test fun unfoldedWindowGetsDesktopDensity() {
        val dpi = WindowDpi.of(442, 2268, "com.android.chrome")
        assertEquals(294, dpi)
        // The user's ~1450 px Chrome window: large-screen layout.
        assertTrue(1450 * 160 / dpi >= WindowDpi.SW_LARGE)
    }

    @Test fun foldedAndScreenDensityAppsKeepTheScreens() {
        assertEquals(442, WindowDpi.of(442, 1116, "com.android.chrome"))
        assertEquals(442, WindowDpi.of(442, 2268, "com.discord"))
    }

    @Test fun contentZoomScalesTheBaseDensityClamped() {
        assertEquals(294, WindowDpi.zoomed(294, 1.0))
        assertEquals(441, WindowDpi.zoomed(294, 1.5)) // bigger content, less fits
        assertEquals(221, WindowDpi.zoomed(294, 0.75)) // more fits
        assertEquals(588, WindowDpi.zoomed(294, 9.0)) // clamped to MAX_ZOOM
        assertEquals(147, WindowDpi.zoomed(294, 0.1)) // clamped to MIN_ZOOM
        assertEquals(294, WindowDpi.zoomed(294, Double.NaN))
    }

    @Test fun noFrameTwoSecondsAfterResizeIsFrozenOnce() {
        val f = FrozenWatch()
        f.resized(1_000)
        assertEquals(0L, f.step(2_500))
        assertEquals(2_100L, f.step(3_100))
        assertEquals(0L, f.step(4_000)) // reported once
    }

    @Test fun aFrameAfterTheResizeIsNotFrozen() {
        val f = FrozenWatch()
        f.frame(900)
        f.resized(1_000)
        f.frame(1_016)
        assertEquals(0L, f.step(5_000))
    }

    @Test fun geometryStillFlowingRearmsFromTheLastResize() {
        val f = FrozenWatch()
        f.resized(1_000)
        f.frame(1_010)
        f.resized(2_500) // drag goes on; the app drew for the first size only
        assertEquals(0L, f.step(4_000))
        assertTrue(f.step(4_600) >= FrozenWatch.FROZEN_MS)
    }

    @Test fun rebindsAreBoundedPerResize() {
        val f = FrozenWatch()
        f.resized(100)
        assertTrue(f.step(2_100) > 0)
        f.rebound(2_000)
        assertTrue(f.step(4_000) > 0)
        f.rebound(4_000)
        assertEquals(0L, f.step(10_000)) // MAX_REBINDS: no loop
        f.resized(11_000)
        assertTrue(f.step(13_000) > 0)
    }

    @Test fun neverIdleWithoutAResize() {
        assertEquals(0L, FrozenWatch().step(60_000))
    }

    @Test fun rebindOnlyAliveAndVisible() {
        assertTrue(FrozenWatch.rebind(2_100, alive = true, visible = true))
        assertFalse(FrozenWatch.rebind(2_100, alive = true, visible = false))
        assertFalse(FrozenWatch.rebind(2_100, alive = false, visible = true))
        assertFalse(FrozenWatch.rebind(1_000, alive = true, visible = true))
    }
}
