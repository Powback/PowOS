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
    fun boost(
        on: Boolean,
        by: String = "switcher",
    ) {
        // Two holders (the switcher, the page's own animations - ShellHost): one letting go keeps the other's.
        if (on) holders += by else holders -= by
        main.removeCallbacks(release)
        if (holders.isNotEmpty()) prefer(fastest()) else main.postDelayed(release, HOLD_MS)
    }

    private val holders = mutableSetOf<String>()

    private fun touched(e: MotionEvent) {
        main.removeCallbacks(release)
        when (e.actionMasked) {
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> main.postDelayed(release, HOLD_MS)
            MotionEvent.ACTION_DOWN -> prefer(fastest())
        }
    }

    private fun fastest(): Int = fastest(window.decorView.display)

    private fun prefer(id: Int) {
        if (id == mode) return
        mode = id
        window.attributes = window.attributes.apply { ask(this, window.decorView.display, id) }
        wanted = id
        onWanted?.invoke(id)
    }

    companion object {
        /** After the finger lifts: a page swipe's settle, a fling, the drawer's spring. */
        private const val HOLD_MS = 1500L

        /**
         * The mode a page asks for now (0: none). WM takes the TOP-most window's preferred mode, so a floating app
         * window over home (ColorOS's 60 Hz for it, or for PowOS's own Linux windows) capped home's page swipes at 60:
         * PowOS's window frames, over every app window, ask for the same while home does (WindowFrames).
         */
        @Volatile var wanted = 0
            private set

        /** Told every change of [wanted] (main thread). */
        var onWanted: ((Int) -> Unit)? = null

        /** [display]'s fastest mode at its current resolution (0: none to ask for). */
        fun fastest(display: android.view.Display?): Int {
            display ?: return 0
            val now = display.mode
            return display.supportedModes
                .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
                .maxByOrNull { it.refreshRate }
                ?.modeId ?: 0
        }

        /** Window attributes [p] asking for mode [id] of [display] (0: the system's choice again). */
        fun ask(
            p: android.view.WindowManager.LayoutParams,
            display: android.view.Display?,
            id: Int,
        ) {
            p.preferredDisplayModeId = id
            p.preferredRefreshRate = if (id == 0) 0f else display?.supportedModes?.firstOrNull { it.modeId == id }?.refreshRate ?: 0f
        }
    }
}
