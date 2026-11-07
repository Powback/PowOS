package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * N2 (docs/WEB_WINDOWS.md "Native-glued windows"): "w.f" geometry the page measured one frame ahead carries a third
 * stamp "1" after its two times; the host binds it to the visual-state callback of the commit that shows it
 * (FrameSync.ahead), never to the next draw (FrameSync.next, which would show it a frame EARLY). The page sends it only
 * once the host said "w.ahead 1", so an older host never sees one.
 */
class WebWindowsAheadTest {
    private val words = "12 2.5 0 1794000000000.00 1794000000003".split(' ')

    @Test
    fun theThirdStampMarksAheadFrames() {
        assertFalse(WebWindows.aheadFlag(words, 3))
        assertTrue(WebWindows.aheadFlag(words + "1", 3))
        assertFalse(WebWindows.aheadFlag(words + "0", 3))
    }

    @Test
    fun aheadFramesRideTheVisualStateCallback() {
        val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
        val cmd = src.substringAfter("fun frameCommand(").substringBefore("\n    }\n")
        assertTrue("an ahead frame no longer goes to FrameSync.ahead", cmd.contains("if (ahead) sync.ahead("))
        val sync = File("src/main/kotlin/dev/omalauncher/shell/FrameSync.kt").readText()
        val ahead = sync.substringAfter("fun ahead(").substringBefore("\n    }\n")
        assertTrue("FrameSync.ahead no longer binds to postVisualStateCallback", ahead.contains("web.postVisualStateCallback("))
        val native = File("src/main/kotlin/dev/omalauncher/shell/ShellNative.kt").readText()
        assertTrue("the host no longer tells the page it takes ahead frames", native.contains("WebMessage(\"w.ahead 1\")"))
    }
}
