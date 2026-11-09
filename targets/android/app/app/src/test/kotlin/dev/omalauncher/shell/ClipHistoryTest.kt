package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** The terminals' paste picker's history (ClipHistory): newest first, deduped, capped, kept across restarts. */
class ClipHistoryTest {
    private var t = 0L
    private val clock = { ++t }

    @Test fun newestFirstAndRepeatsMoveToFront() {
        val h = ClipHistory(null, now = clock)
        assertTrue(h.add("a"))
        assertTrue(h.add("b"))
        assertTrue(h.add("c"))
        assertTrue(h.add("a"))
        assertEquals(listOf("a", "c", "b"), h.list().map { it.text })
        // Already the newest: nothing changes (the clipboard listener sees the page's own write again).
        assertFalse(h.add("a"))
        assertEquals(3, h.list().size)
        assertEquals(4L, h.list()[0].at)
    }

    @Test fun blankAndNullAreDropped() {
        val h = ClipHistory(null, now = clock)
        assertFalse(h.add(null))
        assertFalse(h.add(""))
        assertFalse(h.add("  \n\t"))
        assertTrue(h.list().isEmpty())
    }

    @Test fun cappedAtMaxOldestGoes() {
        val h = ClipHistory(null, max = 3, now = clock)
        listOf("1", "2", "3", "4", "5").forEach { h.add(it) }
        assertEquals(listOf("5", "4", "3"), h.list().map { it.text })
    }

    @Test fun longCopyIsKeptToMaxChars() {
        val h = ClipHistory(null, now = clock)
        h.add("x".repeat(ClipHistory.MAX_CHARS + 10))
        assertEquals(ClipHistory.MAX_CHARS, h.list()[0].text.length)
    }

    @Test fun survivesARestartFromItsFile() {
        val dir = Files.createTempDirectory("clips").toFile()
        val f = File(dir, "clip-history.json")
        val h = ClipHistory(f, now = clock)
        h.add("echo hi")
        h.add("multi\nline \"quoted\"")
        val again = ClipHistory(f)
        assertEquals(listOf("multi\nline \"quoted\"", "echo hi"), again.list().map { it.text })
        assertEquals(h.list(), again.list())
        dir.deleteRecursively()
    }

    @Test fun pageShapeIsTextAndAt() {
        val h = ClipHistory(null, now = clock)
        h.add("ls -la")
        val o = h.toJson().getJSONObject(0)
        assertEquals("ls -la", o.getString("text"))
        assertEquals(1L, o.getLong("at"))
        assertEquals(h.list(), ClipHistory.decode(h.toJson().toString()))
    }

    @Test fun aBrokenFileStartsEmpty() {
        val dir = Files.createTempDirectory("clips").toFile()
        val f = File(dir, "clip-history.json").apply { writeText("{not json") }
        assertTrue(ClipHistory(f).list().isEmpty())
        dir.deleteRecursively()
    }
}
