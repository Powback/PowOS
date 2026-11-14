package dev.omalauncher.widgets.runtime

import dev.omalauncher.widgets.lang.Null
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Value
import dev.omalauncher.widgets.lang.bool
import java.io.File

/**
 * The phone under load from what ANY app may read, for `source p = android.perf every 5s` (55-performance.owl): no
 * root and no Linux image. Measured on the unrooted razr fold (11-09, untrusted app): /proc/stat, /proc/loadavg and
 * kgsl's gpu_busy_percentage / temp are denied, but every thermal zone's type + temp and each core's cpuidle state
 * times are readable. So:
 *  - cpu: load % = 1 - (idle time the online cores' cpuidle states gained) / (wall time x online cores), between two
 *    reads (null on the first);
 *  - cpuTemp / gpuTemp / skinTemp / battTemp (°C): the hottest `cpu*` zone, the hottest `gpu*` zone, the first skin-like
 *    zone, the battery zone; 0 when the phone has none;
 *  - gpu: kgsl's gpu_busy_percentage, else its `gpubusy` ticks (readable unrooted on the razr, 11-14: the tile said
 *    "root" while gpubusy answered); null and gpuNeedsRoot true only when neither can be read and PowOS isn't rooted.
 * [sys] is `/sys` (a temp dir in the JVM test); [now] the wall clock in microseconds (cpuidle's unit).
 */
class Perf(
    private val sys: File = File("/sys"),
    private val now: () -> Long = { System.nanoTime() / 1000 },
    /** Rooted PowOS reads the GPU in its Linux session (the widget's cmd), so the GPU isn't "needs root" there. */
    private val rooted: () -> Boolean = { andro.marchy.RootMode.enabled() },
) {
    private var lastIdle = -1L
    private var lastAt = -1L
    private var lastCores = 0

    fun value(): Value {
        val zones = zones()
        val gpuBusy = gpuBusy()
        return Obj(
            mapOf(
                "cpu" to (cpuLoad()?.let(::Num) ?: Null),
                "gpu" to (gpuBusy?.let(::Num) ?: Null),
                "gpuNeedsRoot" to bool(gpuBusy == null && !rooted()),
                "cpuTemp" to Num(zones.filterKeys { it.startsWith("cpu") && !it.contains("trip") }.values.maxOrNull() ?: 0.0),
                "gpuTemp" to Num(zones.filterKeys { it.startsWith("gpu") }.values.maxOrNull() ?: 0.0),
                "skinTemp" to Num(SKIN.firstNotNullOfOrNull { zones[it] } ?: zones.entries.firstOrNull { it.key.contains("skin") }?.value ?: 0.0),
                "battTemp" to Num(BATTERY.firstNotNullOfOrNull { zones[it] } ?: 0.0),
            ),
        )
    }

    /** kgsl's busy percent, else its `gpubusy` ticks; null when neither can be read. */
    private fun gpuBusy(): Double? {
        val kgsl = File(sys, "class/kgsl/kgsl-3d0")
        return read(File(kgsl, "gpu_busy_percentage"))?.trim()?.split(Regex("\\s+"))?.firstOrNull()?.toDoubleOrNull()
            ?: busyRatio(read(File(kgsl, "gpubusy")))
    }

    /** kgsl's `gpubusy` ("<busy> <total>" ticks of its last sample window) as a percent; an idle window (total 0) is 0 %. */
    private fun busyRatio(text: String?): Double? {
        val n = text?.trim()?.split(Regex("\\s+"))?.mapNotNull { it.toLongOrNull() } ?: return null
        if (n.size < 2) return null
        return if (n[1] > 0) (n[0] * 100.0 / n[1]).coerceIn(0.0, 100.0) else 0.0
    }

    /** type -> °C of every readable thermal zone with a plausible reading (unused sensors say -273 or 0). */
    private fun zones(): Map<String, Double> {
        val out = HashMap<String, Double>()
        File(sys, "class/thermal").listFiles { f -> f.name.startsWith("thermal_zone") }?.forEach { z ->
            val type = read(File(z, "type"))?.trim() ?: return@forEach
            val milli = read(File(z, "temp"))?.trim()?.toLongOrNull() ?: return@forEach
            val c = milli / 1000.0
            if (c in 1.0..150.0 && (out[type] ?: -1.0) < c) out[type] = c
        }
        return out
    }

    private fun cpuLoad(): Double? {
        val cores = online()
        if (cores.isEmpty()) return null
        val idle = cores.sumOf { idleOf(it) }
        val at = now()
        val comparable = lastAt >= 0 && lastCores == cores.size && idle >= lastIdle && at > lastAt
        val load = if (comparable) ((1.0 - (idle - lastIdle).toDouble() / ((at - lastAt).toDouble() * cores.size)) * 100).coerceIn(0.0, 100.0) else null
        lastIdle = idle
        lastAt = at
        lastCores = cores.size
        return load
    }

    /** The microseconds core [n] has spent idle, all its cpuidle states together. */
    private fun idleOf(n: Int): Long =
        File(sys, "devices/system/cpu/cpu$n/cpuidle").listFiles { f -> f.name.startsWith("state") }
            ?.sumOf { s -> read(File(s, "time"))?.trim()?.toLongOrNull() ?: 0L } ?: 0L

    /** The online cores, from /sys/devices/system/cpu/online ("0-7" or "0-3,6"). */
    private fun online(): List<Int> =
        read(File(sys, "devices/system/cpu/online"))?.trim()?.split(',')?.flatMap { r ->
            val (a, b) = r.split('-').let { p -> p[0] to p.getOrElse(1) { p[0] } }
            val lo = a.toIntOrNull() ?: return@flatMap emptyList()
            (lo..(b.toIntOrNull() ?: lo)).toList()
        } ?: emptyList()

    private fun read(f: File): String? = runCatching { f.readText() }.getOrNull()

    private companion object {
        /** Skin sensors by name, most telling first (OnePlus, Motorola, Pixel, generic). */
        val SKIN = listOf("skin-msm-therm", "back_temp", "skin-therm", "sys-therm-0", "quiet-therm")
        val BATTERY = listOf("battery", "batt-therm", "main_battery")
    }
}
