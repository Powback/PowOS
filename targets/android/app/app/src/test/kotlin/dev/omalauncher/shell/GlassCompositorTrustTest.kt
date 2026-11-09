package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Non-root glass (razr fold, 11-09): the compositor's blur regions only where the host can check SurfaceFlinger's
 * render of them (READ_FRAME_BUFFER); elsewhere the page's frosted picture under the same tint.
 */
class GlassCompositorTrustTest {
    @Test
    fun rootedHostKeepsTheCompositorBlur() {
        assertTrue(GlassBlur.compositorTrusted(setting = -1, frameBuffer = true))
    }

    @Test
    fun nonRootHostGetsTheFrostedPicture() {
        assertFalse(GlassBlur.compositorTrusted(setting = -1, frameBuffer = false))
    }

    @Test
    fun theSettingOverridesBothWays() {
        assertTrue(GlassBlur.compositorTrusted(setting = 1, frameBuffer = false))
        assertFalse(GlassBlur.compositorTrusted(setting = 0, frameBuffer = true))
    }
}
