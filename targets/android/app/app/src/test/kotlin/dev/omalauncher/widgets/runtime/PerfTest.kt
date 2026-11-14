package dev.omalauncher.widgets.runtime

import dev.omalauncher.widgets.lang.Null
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Value
import dev.omalauncher.widgets.lang.bool
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** android.perf from what an unrooted app may read: cpuidle load, thermal zones, the GPU marked as needing root. */
class PerfTest {
    private val sys = Files.createTempDirectory("perf-sys").toFile()

    private fun put(path: String, text: String) = File(sys, path).apply { parentFile.mkdirs(); writeText(text) }

    private fun zone(n: Int, type: String, milli: Long) {
        put("class/thermal/thermal_zone$n/type", "$type\n")
        put("class/thermal/thermal_zone$n/temp", "$milli\n")
    }

    private fun idle(cpu: Int, state0: Long, state1: Long) {
        put("devices/system/cpu/cpu$cpu/cpuidle/state0/time", "$state0\n")
        put("devices/system/cpu/cpu$cpu/cpuidle/state1/time", "$state1\n")
    }

    private fun Value.at(k: String) = (this as Obj).fields[k]

    @Test
    fun loadFromCpuidleAndTempsFromZones() {
        put("devices/system/cpu/online", "0-1\n")
        zone(0, "cpu-0-0-0", 41000)
        zone(1, "cpu-1-0-1", 47500)
        zone(2, "cpu-hw-trip-0", 105000)
        zone(3, "gpuss-0", 39000)
        zone(4, "back_temp", 30000)
        zone(5, "battery", 28000)
        zone(6, "mmw0", -273000)
        var t = 1_000_000L
        val perf = Perf(sys, { t }, { false })
        idle(0, 100, 200)
        idle(1, 0, 0)
        val first = perf.value()
        assertEquals(Null, first.at("cpu"))
        // 1 s on 2 cores = 2 000 000 us; they idled 500 000 us of it: 75 % busy.
        t += 1_000_000
        idle(0, 100, 200 + 300_000)
        idle(1, 200_000, 0)
        val v = perf.value()
        assertEquals(Num(75.0), v.at("cpu"))
        assertEquals(Num(47.5), v.at("cpuTemp"))
        assertEquals(Num(39.0), v.at("gpuTemp"))
        assertEquals(Num(30.0), v.at("skinTemp"))
        assertEquals(Num(28.0), v.at("battTemp"))
        assertEquals(Null, v.at("gpu"))
        assertEquals(bool(true), v.at("gpuNeedsRoot"))
    }

    @Test
    fun gpuReadableOrRootedIsNotLocked() {
        put("class/kgsl/kgsl-3d0/gpu_busy_percentage", "37 %\n")
        val v = Perf(sys, { 1L }, { false }).value()
        assertEquals(Num(37.0), v.at("gpu"))
        assertEquals(bool(false), v.at("gpuNeedsRoot"))
        File(sys, "class/kgsl").deleteRecursively()
        assertEquals(bool(false), Perf(sys, { 1L }, { true }).value().at("gpuNeedsRoot"))
    }

    @Test
    fun gpubusyTicksWhenThePercentIsDenied() {
        put("class/kgsl/kgsl-3d0/gpubusy", "  25856  1003524\n")
        val v = Perf(sys, { 1L }, { false }).value()
        assertEquals(Num(25856 * 100.0 / 1003524), v.at("gpu"))
        assertEquals(bool(false), v.at("gpuNeedsRoot"))
        put("class/kgsl/kgsl-3d0/gpubusy", "0 0\n")
        assertEquals(Num(0.0), Perf(sys, { 1L }, { false }).value().at("gpu"))
    }

    @Test
    fun nothingReadableIsNullNotAnError() {
        val v = Perf(sys, { 1L }, { false }).value()
        assertEquals(Null, v.at("cpu"))
        assertEquals(Num(0.0), v.at("cpuTemp"))
    }
}
