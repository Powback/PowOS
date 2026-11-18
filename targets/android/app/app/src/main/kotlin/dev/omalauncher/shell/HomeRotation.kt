package dev.omalauncher.shell

import android.app.Activity
import android.content.pm.ActivityInfo
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface

/**
 * Display 0 turned back to home's rotation once the app that turned it moves into a web window (board
 * inner-screen-stays-landscape-after-an-app-moves, 11-11 21:45: com.oplus.camera started full screen on the inner screen,
 * asked for landscape (rot 0 -> 1), was moved into its window's display - and the inner screen and home STAYED landscape).
 *
 * Why it stays: home (ShellActivity) asks for no orientation (UNSPECIFIED). With auto-rotate on, WM's
 * DisplayRotation.rotationForOrientation gives UNSPECIFIED the sensor's proposal, and with no proposal (the phone lying
 * flat, on a stand) the LAST rotation - the camera's landscape. Nothing in PowOS held it; the app's request simply
 * outlived the app on display 0 because the sensor never proposed anything else.
 *
 * Fix: home's rotation when it last paused (an app came over it, before that app's request turned the display) is
 * kept; after PowOS moves a task off display 0 into a window, home asks for that rotation for a moment
 * ([back]) and gives the request up again (UNSPECIFIED) once display 0 is there: with no sensor proposal the display
 * then keeps home's rotation; a real one (the user turned the phone) still wins as before.
 *
 * And when the app never makes it into a window (11-18 21:11: the camera's adopt failed, it stayed full screen on
 * display 0; or an app web windows refuse - Android's own window), the same rotation is asked back when home is in
 * front again ([resumed]: the app closed or the user went home). Only a turn that came right after home paused
 * ([APP_TURN_MS]: the app's own orientation request at its launch) is undone; a later one is the user turning the phone
 * and stays theirs. A fold in between (display 0 another screen) is never "turned back".
 */
object HomeRotation {
    private const val TAG = "PowosHomeRotation"

    /** How long home holds its request at most while display 0 turns back. */
    private const val HOLD_MS = 2000L
    private const val POLL_MS = 100L

    /** A turn of display 0 this soon after home paused is the app's orientation request at its launch, not the user's. */
    const val APP_TURN_MS = 3000L

    /** When home last paused (uptime ms), display 0's turn after it (uptime ms, -1: none seen), its size then. */
    @Volatile private var pausedAt = 0L

    @Volatile private var turnedAt = -1L

    @Volatile private var pauseScreen = ""

    @Volatile private var homePaused = false
    private var listening = false

    /**
     * Whether home asks [before] back while display 0 is at [now]: it turned ([before] != [now], both known), on the same
     * screen ([sameScreen]: no fold since), and the turn was the app's - [turnMs] after home paused within [APP_TURN_MS]
     * (null: not seen - the listener missed it; turned back, as before).
     */
    fun restore(
        before: Int,
        now: Int,
        sameScreen: Boolean,
        turnMs: Long?,
    ): Boolean = before in 0..3 && now in 0..3 && before != now && sameScreen && (turnMs == null || turnMs in 0..APP_TURN_MS)

    /** Display 0's physical screen, rotation-free ("short x long"): a fold changes it, a turn doesn't. */
    fun screenKey(
        w: Int,
        h: Int,
    ): String = "${minOf(w, h)}x${maxOf(w, h)}"

    /** Display 0's Surface.ROTATION_* when home last paused; -1 unknown. */
    @Volatile var atPause = -1

    /**
     * The ActivityInfo.SCREEN_ORIENTATION_* that turns display 0 from [now] back to [before], or null (unknown, or
     * already there). [naturalPortrait]: the display at ROTATION_0 is taller than wide (WM's portrait/landscape
     * rotations: natural portrait 0/90/180/270 = portrait/landscape/upside down/seascape; natural landscape 90 = portrait).
     * ROTATION_0 is NOSENSOR (always rotation 0, whatever the sensor says).
     */
    fun orientationFor(
        before: Int,
        now: Int,
        naturalPortrait: Boolean,
    ): Int? {
        if (before !in 0..3 || now !in 0..3 || before == now) return null
        return (if (naturalPortrait) BY_ROTATION_PORTRAIT else BY_ROTATION_LANDSCAPE)[before]
    }

    // Surface.ROTATION_0..270 -> the orientation WM turns to that rotation, for a natural portrait / landscape display.
    private val BY_ROTATION_PORTRAIT =
        intArrayOf(
            ActivityInfo.SCREEN_ORIENTATION_NOSENSOR,
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE,
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT,
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE,
        )
    private val BY_ROTATION_LANDSCAPE =
        intArrayOf(
            ActivityInfo.SCREEN_ORIENTATION_NOSENSOR,
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT,
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE,
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT,
        )

    /** Whether display 0 is taller than wide at ROTATION_0, from its size ([w] x [h]) at [rotation]. */
    fun naturalPortrait(
        w: Int,
        h: Int,
        rotation: Int,
    ): Boolean = if (rotation == Surface.ROTATION_90 || rotation == Surface.ROTATION_270) h < w else w < h

    /** Home paused: display 0's rotation now (before the app in front asks for its own), and its turns watched. */
    fun paused(home: Activity) {
        val d = runCatching { home.display }.getOrNull()
        atPause = d?.rotation ?: -1
        pauseScreen = d?.let { screenOf(it) } ?: ""
        pausedAt = SystemClock.uptimeMillis()
        turnedAt = -1
        homePaused = true
        watch(home)
    }

    /** Home in front again: the app that turned display 0 left it full screen (closed, or never made a window) - turned back. */
    fun resumed(home: Activity) {
        homePaused = false
        back(home, "home in front again")
    }

    /** The orientation home asks for display 0 ([d]) to turn back to [atPause] after [why], or null: left so. */
    private fun wanted(
        d: android.view.Display,
        why: String,
    ): Int? {
        val now = d.rotation
        val size = android.graphics.Point().also { @Suppress("DEPRECATION") d.getRealSize(it) }
        val screen = screenKey(size.x, size.y)
        val turn = turnedAt.takeIf { it >= 0 }?.let { it - pausedAt }
        if (!restore(atPause, now, pauseScreen.isEmpty() || pauseScreen == screen, turn)) {
            if (atPause in 0..3 && now != atPause) WindowLog.i(TAG, "display 0 at rotation $now after $why (home's was $atPause): left so (turned ${turn ?: "?"} ms after home paused, screen $screen was $pauseScreen)")
            return null
        }
        return orientationFor(atPause, now, naturalPortrait(size.x, size.y, now))
    }

    private fun screenOf(d: android.view.Display): String {
        val size = android.graphics.Point().also { @Suppress("DEPRECATION") d.getRealSize(it) }
        return screenKey(size.x, size.y)
    }

    /** Display 0's first turn while home is paused, timed (main thread; one listener for the process). */
    private fun watch(home: Activity) {
        if (listening) return
        val dm = home.applicationContext.getSystemService(android.hardware.display.DisplayManager::class.java) ?: return
        listening = true
        dm.registerDisplayListener(
            object : android.hardware.display.DisplayManager.DisplayListener {
                override fun onDisplayAdded(displayId: Int) = Unit

                override fun onDisplayRemoved(displayId: Int) = Unit

                override fun onDisplayChanged(displayId: Int) {
                    if (displayId != android.view.Display.DEFAULT_DISPLAY || !homePaused || turnedAt >= 0) return
                    val r = runCatching { dm.getDisplay(displayId)?.rotation }.getOrNull() ?: return
                    if (r != atPause) turnedAt = SystemClock.uptimeMillis()
                }
            },
            Handler(Looper.getMainLooper()),
        )
    }

    /** Main thread, after a task left display 0 for a window ([why]): display 0 back to [atPause] if it turned. */
    fun back(
        home: Activity,
        why: String,
    ) {
        val d = runCatching { home.display }.getOrNull() ?: return
        if (d.displayId != android.view.Display.DEFAULT_DISPLAY) return
        val want = wanted(d, why) ?: return
        val now = d.rotation
        val had = home.requestedOrientation
        if (had != ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED) return // home's own request: never overridden
        val before = atPause
        WindowLog.i(TAG, "display 0 still at rotation $now after $why (home's was $before): home asks orientation $want, then lets go")
        home.requestedOrientation = want
        val main = Handler(Looper.getMainLooper())
        val until = SystemClock.uptimeMillis() + HOLD_MS
        val check =
            object : Runnable {
                override fun run() {
                    val r = runCatching { home.display?.rotation }.getOrNull()
                    if (r != before && SystemClock.uptimeMillis() < until && !home.isDestroyed) {
                        main.postDelayed(this, POLL_MS)
                        return
                    }
                    if (home.requestedOrientation == want) home.requestedOrientation = had
                    WindowLog.i(TAG, "display 0 at rotation $r (wanted $before): home's request given up")
                }
            }
        main.postDelayed(check, POLL_MS)
    }
}
