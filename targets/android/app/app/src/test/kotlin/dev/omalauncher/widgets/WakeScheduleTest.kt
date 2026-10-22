package dev.omalauncher.widgets

import dev.omalauncher.widgets.lang.Compiler
import dev.omalauncher.widgets.lang.Global
import dev.omalauncher.widgets.runtime.WidgetInstance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The idle home's wakes, headless: the polled sources of the widgets a fresh home shows (assets/widgets/ *.owl), run
 * through [WidgetInstance.nextWake] for a minute. Sources Android pushes (battery) and streams/files wait on events.
 * Budget (powos-perf): the home's only steady wake is the performance tile's 5 s, everything else shares it.
 */
class WakeScheduleTest {
    private val pushed = setOf("android.battery", "android.media", "android.notifications", "android.volume", "android.alarm", "android.modes")

    private fun polled(): List<Global.Source> =
        File("src/main/assets/widgets").listFiles { f -> f.extension == "owl" }!!.flatMap { f ->
            Compiler.compile(f.readText()).globals.filterIsInstance<Global.Source>().filter {
                it.kind !in pushed && it.kind != "stream" && it.kind != "file"
            }
        }

    /** Distinct instants (ms) any source woke at in the minute after [start], each source updating at start first. */
    private fun wakes(
        start: Long,
        next: (Global.Source, Long) -> Long,
    ): Set<Long> {
        val out = HashSet<Long>()
        for (s in polled()) {
            var t = start
            while (true) {
                t += next(s, t)
                if (t > start + 60_000) break
                out += t
            }
        }
        return out
    }

    @Test fun homeSourcesShareOneWake() {
        val start = 1_760_000_000_123L // not on any boundary
        val aligned = wakes(start) { s, now -> WidgetInstance.nextWake(s.every, now) }
        // Before: each source on its own phase (clocks aligned, the rest counted from their own start).
        val before = wakes(start + 7) { s, now -> if (s.kind == "clock") WidgetInstance.nextWake(s.every, now) else (s.every * 1000).toLong() }
        println("idle home polled-source wakes/min: aligned=${aligned.size} own-phase=${before.size}")
        // The 5 s tile: 12 a minute; nothing else adds a wake of its own.
        assertTrue("wakes/min ${aligned.size}", aligned.size <= 12)
        assertTrue(aligned.all { it % 5000 == 0L })
    }

    @Test fun nextWakeIsOnTheBoundary() {
        assertEquals(4877L, WidgetInstance.nextWake(5.0, 1_000_123L))
        assertEquals(5000L, WidgetInstance.nextWake(5.0, 1_000_000L))
        assertEquals(100L, WidgetInstance.nextWake(Double.NaN, 1_000_000L))
    }
}
