package dev.omalauncher.shell

/**
 * A web window's display: its density ([WindowDpi]) and its frozen-app watch ([FrozenWatch]), pure so the JVM tests
 * drive them (the helper, [WebWindowsHost], and [WebWindows] act on their answers).
 */
internal object WindowDpi {
    /** Android's large-screen line (sw600dp: tablet/desktop layouts, Chrome's tab strip). */
    const val SW_LARGE = 600

    /**
     * HACK: apps that keep the metrics of the density they started at (React Native: Discord drew avatars and labels
     * at 0.68 of their size, cut, after moving between a window and full screen - 83fcef17, measured 2026-10-30) stay
     * at the screen's density. Real fix: such an app's activity relaunched (not just reconfigured) when its density
     * changes, so every app can take the desktop density.
     */
    val SCREEN_DENSITY_APPS = setOf("com.discord")

    /**
     * The dpi of a window's display, fixed for the window's life (never changed by a resize, a page reload or a
     * rebind, so an app never sees its density move under it while it's in the window): on a large screen (the
     * unfolded phone, [screenSmallestPx] at [screenDpi] >= [SW_LARGE] dp) the desktop density, 2/3 of the screen's
     * (442 -> 294: a 1135 px window is 617 dp, a 1450 px one 789 dp - Chrome's desktop tab strip, tablet layouts);
     * the folded screen and [SCREEN_DENSITY_APPS] keep [screenDpi].
     */
    fun of(
        screenDpi: Int,
        screenSmallestPx: Int,
        pkg: String,
    ): Int {
        if (screenDpi <= 0) return screenDpi
        if (screenSmallestPx * 160 / screenDpi < SW_LARGE) return screenDpi
        if (pkg in SCREEN_DENSITY_APPS) return screenDpi
        return screenDpi * 2 / 3
    }
}

/**
 * One window display's frozen-app watch (run by [WebWindowsHost] on its frames thread, one per display).
 *
 * The blind spot of [RenderWatch] (10-31 15:17, Chrome "crushed, just frozen"): the page's geometry kept flowing, the
 * display was resized ("29 relayouts for 67 steps, settled no frame after release"), but the app never composed a
 * frame at the new size - the user saw the old, stretched frame until they closed the window. A resize always makes
 * a live, visible app draw, so no display frame for [FROZEN_MS] after the last resize is a frozen app:
 * [step] reports it once ("quiet"), [WebWindows] decides with [rebind] (its app alive and visible) and the helper
 * re-binds the display's surface ([rebound]: off and on - the app stops and starts and draws again). At most
 * [MAX_REBINDS] per resize, never a loop.
 */
internal class FrozenWatch {
    private var resizedAt = 0L
    private var frameAt = 0L
    private var reported = false

    /** Rebinds since the last resize. */
    var rebinds = 0
        private set

    /** The display was resized at [now] (uptime ms): watched again. */
    fun resized(now: Long) {
        resizedAt = now
        reported = false
        rebinds = 0
    }

    /** The display composed a frame at [now]. */
    fun frame(now: Long) {
        frameAt = now
    }

    /** Its surface was re-bound at [now]: the app must draw again within [FROZEN_MS]. */
    fun rebound(now: Long) {
        resizedAt = now
        reported = false
        rebinds++
    }

    /** At [now]: the ms without a frame since the last resize/rebind, once, when that reached [FROZEN_MS]; else 0. */
    fun step(now: Long): Long {
        if (resizedAt == 0L || reported || frameAt >= resizedAt || rebinds >= MAX_REBINDS) return 0L
        val quiet = now - resizedAt
        if (quiet < FROZEN_MS) return 0L
        reported = true
        return quiet
    }

    companion object {
        const val FROZEN_MS = 2_000L
        const val MAX_REBINDS = 2

        /** A "quiet" display is re-bound only while its app is [alive] and its window [visible] (a hidden app draws nothing). */
        fun rebind(
            quietMs: Long,
            alive: Boolean,
            visible: Boolean,
        ) = quietMs >= FROZEN_MS && alive && visible
    }
}
