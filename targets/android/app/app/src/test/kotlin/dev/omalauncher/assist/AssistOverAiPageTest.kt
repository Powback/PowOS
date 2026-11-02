package dev.omalauncher.assist

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The side button opens the assist overlay over home's PowOS AI page too (the user, 11-02: "I tried to open like the
 * AI overlay with the side button on the AI page and it doesn't work"): no early finish() in onShow, and the screenshot
 * isn't compressed on the main thread there.
 */
class AssistOverAiPageTest {
    private val src = File("src/main/kotlin/dev/omalauncher/assist/PowosAssistSession.kt").readText()

    private fun body(name: String): String {
        val start = src.indexOf("override fun $name(")
        assertTrue("$name not found", start >= 0)
        val next = src.indexOf("\n    override fun ", start + 1).let { if (it < 0) src.length else it }
        return src.substring(start, next)
    }

    @Test
    fun onShowNeverFinishesBeforeShowing() {
        val show = body("onShow")
        assertFalse("onShow finishes the session (the overlay never shows)", show.contains("finish()\n            return"))
        assertFalse(show.contains("focusAiOnHome"))
        assertTrue(show.contains("assist.reset"))
    }

    @Test
    fun screenshotIsEncodedThroughTheEncoder() {
        val shot = body("onHandleScreenshot")
        assertTrue(shot.contains("encoder.encode("))
        assertFalse("compressed straight into the file on the main thread", shot.contains("outputStream().use"))
    }
}
