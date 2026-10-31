package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
    view: View,
    /** The window's display now (its modes are per physical screen). */
    private val display: () -> android.view.Display?,
    /** The window asks for mode [id] (0: the system's choice): its attributes changed and applied. */
    private val apply: (Int) -> Unit,
    /** Home's page: its ask is [wanted], which the windows over it follow (WindowFrames, the status bar). */
    private val global: Boolean = false,
) {
    /** An activity's window (home, the switcher). */
    constructor(window: Window, view: View, global: Boolean = true) :
        this(view, { window.decorView.display }, { id -> window.attributes = window.attributes.apply { ask(this, window.decorView.display, id) } }, global)

    private val main = Handler(Looper.getMainLooper())
    private val vote = RefreshVote()
    private val idle = Runnable { set(vote.poll(SystemClock.uptimeMillis())) }
    private val target = view
    private var mode = 0

    init {
        // Watching only: false, so the page gets every event as before.
        @SuppressLint("ClickableViewAccessibility")
        view.setOnTouchListener { _, e ->
            touched(e)
            false
        }
        // Touches a hook took before the listener (HomeWebView.touchHook; web windows only watch them now).
        (view as? HomeWebView)?.stolenWatch = ::touched
    }

    /**
     * The page animates without a finger on it (the switcher layer following a swipe up over an app, the page's own
     * transition, an overlay's gesture): fastest while [on], given back [RefreshVote.IDLE_MS] after.
     */
    fun boost(
        on: Boolean,
        by: String = "switcher",
    ) = set(vote.hold(by, on, SystemClock.uptimeMillis()))

    private fun touched(e: MotionEvent) {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> set(vote.touch(true, SystemClock.uptimeMillis()))
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> set(vote.touch(false, SystemClock.uptimeMillis()))
        }
    }

    private fun set(high: Boolean) {
        main.removeCallbacks(idle)
        if (vote.releaseAt != 0L) main.postAtTime(idle, vote.releaseAt)
        prefer(if (high) fastest(display()) else 0)
        // AOSP's own vote too (Android 15+: the view's frame rate category, read on each of its draws). ColorOS's
        // SurfaceFlinger doesn't use layer votes (ro.surface_flinger.use_content_detection_for_refresh_rate=false, its
        // own OPlusRefreshRateSelector picks), so the window's mode above is what counts on the phone; this is what
        // does on a stock Android 16, where an unvoted view under a finger is "normal" (60 Hz).
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            runCatching {
                target.requestedFrameRate = if (high) View.REQUESTED_FRAME_RATE_CATEGORY_HIGH else View.REQUESTED_FRAME_RATE_CATEGORY_DEFAULT
            }
        }
    }

    private fun prefer(id: Int) {
        if (id == mode) return
        mode = id
        apply(id)
        if (!global) return
        wanted = id
        onWanted?.invoke(id)
        followers.forEach { it(id) }
    }

    companion object {
        /**
         * The mode a page asks for now (0: none). WM takes the TOP-most window's preferred mode, so a floating app
         * window over home (ColorOS's 60 Hz for it, or for PowOS's own Linux windows) capped home's page swipes at 60:
         * PowOS's window frames, over every app window, ask for the same while home does (WindowFrames).
         */
        @Volatile var wanted = 0
            private set

        /** Told every change of [wanted] (main thread): WindowFrames' frames. */
        var onWanted: ((Int) -> Unit)? = null

        /** Also told every change of [wanted] (main thread): the windows always over home (the status bar strip). */
        val followers = java.util.concurrent.CopyOnWriteArrayList<(Int) -> Unit>()

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
