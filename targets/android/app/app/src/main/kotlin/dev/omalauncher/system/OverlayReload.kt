package dev.omalauncher.system

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.webkit.WebView

/**
 * A shell push's reload for a page kept warm in a hidden overlay window (the shade, Quick Tools, the pull-up panels),
 * done while nobody looks - not when the window next shows.
 *
 * The page's own hot reload (shell/hot.ts) waits while the page is hidden and reloads once it shows: for an overlay
 * that's the moment a pull brings it, so the pull showed the window's blur over a page still booting - the "blank
 * shade" (2026-10-22). A hidden WebView doesn't load at all (its window is GONE), so instead:
 *
 * - a changed shell file (not a stylesheet: the page swaps those in place) is the host's ([changed] true: not sent to
 *   the page). Window hidden: the page reloads now, its window made VISIBLE at alpha 0 (never touchable) so the
 *   WebView loads, then GONE again once the new page says it's alive. Window showing (open, or being pulled): the
 *   reload waits until it hides ([hidden]).
 * - a pull arriving mid-reload: the window comes up at alpha 0 and stays invisible until the page is ready; [onReady]
 *   then hands the page the gesture's state so far, and the window shows.
 */
internal class OverlayReload(
    private val name: String,
    private val wm: WindowManager,
    private val web: () -> WebView?,
    private val window: () -> Pair<View, WindowManager.LayoutParams>?,
    /** The window is showing (open, being pulled, or a heads-up banner). */
    private val shown: () -> Boolean,
    /** The new page is up while the window shows: give it the state it missed. */
    private val onReady: () -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())

    /** The page is reloading: its window is up at alpha 0 (or stays so if shown meanwhile). */
    var reloading = false
        private set
    private var pending = false
    private var serial = 0

    /** A shell file changed ([path] as hot.ts gets it): true when this host does the reload, false for the page. */
    fun changed(path: String): Boolean {
        if (path.endsWith(".css") || path.startsWith(".") || path.startsWith("dev/") || path.startsWith("test/") || path.startsWith("_app/")) return false
        if (reloading) {
            pending = true
        } else if (shown()) {
            pending = true
            Log.i(TAG, "$name: $path changed while showing - reloading once it hides")
        } else {
            // Several files of one push: one reload, after the last.
            main.removeCallbacks(start)
            main.postDelayed(start, SETTLE_MS)
        }
        return true
    }

    /** The window went away: a reload that waited for that now. */
    fun hidden() {
        if (pending && !reloading) {
            pending = false
            main.removeCallbacks(start)
            main.postDelayed(start, SETTLE_MS)
        }
    }

    private val start = Runnable { reload() }

    private fun reload() {
        if (reloading) return
        val w = web() ?: return
        val (v, p) = window() ?: return
        if (shown()) {
            pending = true
            return
        }
        reloading = true
        val mine = ++serial
        Log.i(TAG, "$name: reloading the hidden page for a shell push")
        p.alpha = 0f
        v.visibility = View.VISIBLE
        runCatching { wm.updateViewLayout(v, p) }
        // The old page marked, so the old page's answer isn't taken for the new one's.
        w.evaluateJavascript("window.__overlayStale = true", null)
        w.reload()
        // Asked every POLL_MS on its own clock: an evaluateJavascript asked while the page navigates never answers (its
        // callback is dropped with the old page) - waiting on answers left all three windows up at alpha 0 for good
        // (2026-10-22 19:09). And a hard deadline that ends it whatever answers.
        val poll =
            object : Runnable {
                override fun run() {
                    if (mine != serial || !reloading) return
                    w.evaluateJavascript("window.__powosAlive === true && !window.__overlayStale") { ok ->
                        if (mine == serial && reloading && ok == "true") done(true)
                    }
                    main.postDelayed(this, POLL_MS)
                }
            }
        main.postDelayed(poll, POLL_MS)
        main.postDelayed({ if (mine == serial && reloading) done(false) }, RELOAD_MAX_MS)
    }

    private fun done(ok: Boolean) {
        if (!reloading) return
        serial++
        reloading = false
        val (v, p) = window() ?: return
        p.alpha = 1f
        val showing = shown()
        if (!showing) v.visibility = View.GONE
        runCatching { wm.updateViewLayout(v, p) }
        Log.i(TAG, "$name: reloaded ${if (ok) "and ready" else "but not answering"}${if (showing) " (shown meanwhile)" else ""}")
        if (showing) onReady()
        if (pending && !showing) hidden()
    }

    private companion object {
        const val TAG = "PowosOverlay"
        const val SETTLE_MS = 400L
        const val POLL_MS = 120L
        const val RELOAD_MAX_MS = 8_000L
    }
}
