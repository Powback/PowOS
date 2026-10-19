package dev.omalauncher.shell

import android.util.Log
import android.webkit.WebView

/**
 * Whether a PowOS window's page is alive, for the hosts whose windows cover the screen (the shade, its banner, the lock
 * face, the assistant): a page that never ran (a shell module that didn't load - an import cycle, a syntax error) or
 * that hangs can't ask its host to put the window away, and a window left up eats every touch (2026-10-20: the shade's
 * invisible full-screen window over the lock face for 14 minutes - no swipe up, no unlock). So the host asks the page
 * itself: `window.__powosAlive`, which shell/app.tsx sets once a screen has rendered; no answer in time is no.
 */
class PageWatchdog(
    private val web: WebView,
    private val name: String,
    /** Not now (the screen is off: a page may be throttled then, its silence means nothing) - looked at again later. */
    private val skip: () -> Boolean = { false },
    /** The page didn't answer, or answered no: the host takes its window away ([why] for the log). */
    private val dead: (why: String) -> Unit,
) {
    private var running = false
    private var serial = 0

    private val tick = Runnable { check() }

    /** Watching: the first look after [FIRST_MS], then every [EVERY_MS], until [stop]. */
    fun start() {
        if (running) return
        running = true
        serial++
        web.removeCallbacks(tick)
        web.postDelayed(tick, FIRST_MS)
    }

    fun stop() {
        running = false
        serial++
        web.removeCallbacks(tick)
    }

    private fun check() {
        if (!running) return
        if (skip()) {
            web.postDelayed(tick, EVERY_MS)
            return
        }
        val mine = serial
        probe(web) { alive, why ->
            if (!running || mine != serial) return@probe
            if (alive) {
                web.postDelayed(tick, EVERY_MS)
            } else {
                running = false
                Log.w(TAG, "$name: its page isn't answering ($why) - the window goes")
                dead(why)
            }
        }
    }

    companion object {
        private const val TAG = "PageWatchdog"
        private const val FIRST_MS = 1_500L
        private const val EVERY_MS = 2_000L
        private const val ANSWER_MS = 1_500L

        /** Asks [web]'s page once: [result] (alive, and why not) within [ANSWER_MS], on the main thread. */
        fun probe(
            web: WebView,
            result: (Boolean, String) -> Unit,
        ) {
            var answered = false
            val late =
                Runnable {
                    if (answered) return@Runnable
                    answered = true
                    result(false, "no answer in ${ANSWER_MS} ms")
                }
            web.postDelayed(late, ANSWER_MS)
            runCatching {
                web.evaluateJavascript("window.__powosAlive === true") { v ->
                    if (answered) return@evaluateJavascript
                    answered = true
                    web.removeCallbacks(late)
                    result(v == "true", "not rendered (__powosAlive is $v)")
                }
            }.onFailure {
                answered = true
                web.removeCallbacks(late)
                result(false, "can't ask: $it")
            }
        }
    }
}
