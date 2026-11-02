package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** RT1: a blank home's evidence file - what triggers it, what it holds, how many are kept. */
class BlankCaptureTest {
    @Test
    fun onlyTheBlankKindCaptures() {
        assertTrue(BlankCapture.isBlank("blank"))
        assertFalse(BlankCapture.isBlank("error"))
        assertFalse(BlankCapture.isBlank("rejection"))
    }

    @Test
    fun keepsTheNewestCaptures() {
        val names = (1..15).map { "blank-${1000L + it}.txt" } + listOf("perf-1.json", "screen-2.jpg", "blank-x.txt")
        val gone = BlankCapture.stale(names, keep = 12)
        assertEquals(listOf("blank-1003.txt", "blank-1002.txt", "blank-1001.txt"), gone)
    }

    @Test
    fun holdsLogcatAndRotation() {
        val cmds = BlankCapture.commands.joinToString("\n") { it.second }
        assertTrue(cmds.contains("logcat -d -v time -t 2000"))
        assertTrue(cmds.contains("user_rotation"))
        assertTrue(cmds.contains("mCurrentRotation"))
    }
}
