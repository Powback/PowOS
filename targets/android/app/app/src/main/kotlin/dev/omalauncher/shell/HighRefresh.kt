package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.Window

/**
 * A page's window at the panel's fastest refresh rate while the finger is on it and a moment after (a page swipe
 * settling, a list flinging), at the system's choice otherwise - so swiping home is 120 Hz where the screen can.
 *
 * HACK: ColorOS's refresh-rate policy (the oplusscreenmode service, /my_product/etc/refresh_rate_config.xml) gives each
 * package it lists a rate per screen mode, and one it doesn't list - PowOS - the default, 60 Hz in its auto mode: a
 * PRIORITY_WINDOW_REQUEST vote for our windows caps the render rate at 60 under the user's 120 Hz peak, whatever the
 * page draws or asks for per frame (the WebView's frame rate votes, frameRateBoostOnTouch), while the stock launcher,
 * which it lists, scrolls at 120. A window's own preferred display mode wins over that list (its "window override"),
 * so this asks for the fastest mode while touched and gives it back when idle - no 120 Hz while nothing moves. Real
 * fix: none in PowOS; ColorOS listing the package, or honoring AOSP's frame rate votes for unlisted ones.
 */
internal class HighRefresh(
    private val window: Window,
    view: View,
) {
    private val main = Handler(Looper.getMainLooper())
    private val release = Runnable { prefer(0) }
    private var mode = 0

    init {
        // Watching only: false, so the page gets every event as before.
        @SuppressLint("ClickableViewAccessibility")
        view.setOnTouchListener { _, e ->
            touched(e)
            false
        }
    }

    /**
     * The page animates without a finger on it (the switcher layer following a swipe up over an app): fastest while
     * [on], given back a moment after.
     */
    fun boost(on: Boolean) {
        main.removeCallbacks(release)
        if (on) prefer(fastest()) else main.postDelayed(release, HOLD_MS)
    }

    private fun touched(e: MotionEvent) {
        main.removeCallbacks(release)
        when (e.actionMasked) {
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> main.postDelayed(release, HOLD_MS)
            MotionEvent.ACTION_DOWN -> prefer(fastest())
        }
    }

    /** The display's fastest mode at its current resolution (0: none to ask for). */
    private fun fastest(): Int {
        val display = window.decorView.display ?: return 0
        val now = display.mode
        return display.supportedModes
            .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
            .maxByOrNull { it.refreshRate }
            ?.modeId ?: 0
    }

    private fun prefer(id: Int) {
        if (id == mode) return
        mode = id
        window.attributes =
            window.attributes.apply {
                preferredDisplayModeId = id
                preferredRefreshRate = if (id == 0) 0f else window.decorView.display?.supportedModes?.firstOrNull { it.modeId == id }?.refreshRate ?: 0f
            }
    }

    private companion object {
        /** After the finger lifts: a page swipe's settle, a fling, the drawer's spring. */
        const val HOLD_MS = 1500L
    }
}
