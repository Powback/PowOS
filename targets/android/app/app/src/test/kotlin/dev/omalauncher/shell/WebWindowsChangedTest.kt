package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * WINDOWS_FIX_PLAN 2.4: the host tells the page "webwindows.changed <generation>" after every bump, coalesced to one
 * event per main-loop turn (never one per bump, never for moveresize/resend/alive), with the generation as it is when
 * the event goes out (docs/WEB_WINDOWS.md "The host snapshot").
 */
class WebWindowsChangedTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()

    private class Loop {
        val queue = ArrayDeque<Runnable>()

        fun turn() {
            val now = queue.toList()
            queue.clear()
            now.forEach { it.run() }
        }
    }

    @Test
    fun aBurstOfBumpsIsOneChangedWithTheNewGeneration() {
        val loop = Loop()
        var gen = 0L
        val sent = mutableListOf<Pair<String, Any?>>()
        val signal = WebWindows.ChangedSignal({ loop.queue.add(it) }, { gen }, { e, d -> sent += e to d })
        repeat(5) {
            gen++
            signal.bumped()
        }
        assertTrue("sent before the loop turned", sent.isEmpty())
        loop.turn()
        assertEquals(listOf("webwindows.changed" to 5L), sent)
        loop.turn()
        assertEquals("nothing more without a bump", 1, sent.size)
        gen++
        signal.bumped()
        loop.turn()
        assertEquals("webwindows.changed" to 6L, sent.last())
        assertEquals(2, sent.size)
    }

    @Test
    fun aBumpWhileTheEventIsOutGetsItsOwn() {
        val loop = Loop()
        var gen = 1L
        val sent = mutableListOf<Any?>()
        lateinit var signal: WebWindows.ChangedSignal
        signal =
            WebWindows.ChangedSignal({ loop.queue.add(it) }, { gen }, { _, d ->
                sent += d
                // The page's answer (or anything) bumping again during the send: the next turn says so.
                if (sent.size == 1) {
                    gen++
                    signal.bumped()
                }
            })
        signal.bumped()
        loop.turn()
        loop.turn()
        assertEquals(listOf<Any?>(1L, 2L), sent)
    }

    @Test
    fun onlyStateEventsBump() {
        listOf("webwindows.moveresize", "webwindows.resend", "webwindows.alive", "webwindows.changed").forEach {
            assertFalse("$it must not bump", WebWindows.bumps(it))
        }
        assertTrue(WebWindows.bumps("webwindows.closed"))
    }

    /** The wiring: every bump ([changed]) goes through the signal, and the signal is posted to the main looper. */
    @Test
    fun everyBumpSignals() {
        val changed = src.substringAfter("private fun changed() {").substringBefore("\n    }\n")
        assertTrue("changed() no longer bumps", changed.contains("generation.incrementAndGet()"))
        assertTrue("changed() no longer signals the page", changed.contains("changedSignal.bumped()"))
        assertTrue("the signal must go out on the main looper, with the live generation", src.contains("ChangedSignal({ main.post(it) }, { generation.get() }, sink)"))
    }
}
