package dev.omalauncher.assist

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * The side (power) button's presses and releases, read as root from its input device - Android gives apps neither: a
 * long press opens the assistant, and its release stays with the system. Holding it to talk needs the release:
 * PowosAssistSession ends the dictation there and the words are sent (assist.tsx).
 *
 * One `getevent -ql` on the power key's evdev node (pmic_pwrkey on the OnePlus Open; found by its
 * device name), started once per app process (one `su`: one Magisk toast, not one per summoning), blocked on read
 * between presses - no CPU, no wakeups. Read-only: the events still go to the system as before (the release locks
 * nothing that it didn't lock before). No root, no node: [down] stays false and the page falls back to ending the
 * dictation at a pause.
 */
object PowerKey {
    private const val TAG = "speech"
    private val main = Handler(Looper.getMainLooper())
    private var started = false

    /** The button is down now (as last read). */
    @Volatile
    var down = false
        private set

    /** When it last went down (elapsedRealtime), 0: never seen. */
    @Volatile
    var downAt = 0L
        private set

    /** Hears the next release (main thread), once; null clears. */
    var onRelease: (() -> Unit)? = null

    fun start() {
        if (started) return
        started = true
        Thread({ run() }, "powos-powerkey").apply { isDaemon = true }.start()
    }

    /**
     * As root: the evdev node whose device is the power key (its name: pmic_pwrkey, qpnp_pon, ...), announced as "node
     * <path>", then its events. exec: getevent is the su's own process and goes when the app does (its pipe closes).
     */
    private const val READER =
        "n=; for e in /sys/class/input/event*; do case \"\$(cat \$e/device/name 2>/dev/null)\" in *pwrkey*|*pon*) " +
            "n=/dev/input/\${e##*/}; break;; esac; done; [ -n \"\$n\" ] || { echo 'no power key node'; exit 3; }; " +
            "echo node \$n; exec getevent -ql \$n"

    private fun run() {
        try {
            val p = ProcessBuilder("su", "-c", READER).redirectErrorStream(true).start()
            p.inputStream.bufferedReader().forEachLine { line ->
                if (line.startsWith("node ") || line.startsWith("no power")) {
                    Log.i(TAG, "power key: $line")
                    return@forEachLine
                }
                if (!line.contains("KEY_POWER")) return@forEachLine
                when {
                    line.contains("DOWN") -> {
                        Log.i(TAG, "power key: down")
                        down = true
                        downAt = SystemClock.elapsedRealtime()
                    }
                    line.contains("UP") -> {
                        Log.i(TAG, "power key: up (${SystemClock.elapsedRealtime() - downAt} ms held)")
                        down = false
                        main.post {
                            val r = onRelease
                            onRelease = null
                            r?.invoke()
                        }
                    }
                }
            }
            Log.i(TAG, "power key: reader ended (${p.waitFor()})")
        } catch (e: Exception) {
            Log.w(TAG, "power key: no reader", e)
        }
        down = false
    }
}
