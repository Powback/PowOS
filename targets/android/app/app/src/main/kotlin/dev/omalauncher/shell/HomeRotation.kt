package dev.omalauncher.shell

import android.app.Activity
import android.content.pm.ActivityInfo
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
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
 */
object HomeRotation {
    private const val TAG = "PowosHomeRotation"

    /** How long home holds its request at most while display 0 turns back. */
    private const val HOLD_MS = 2000L
    private const val POLL_MS = 100L

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

    /** Home paused: display 0's rotation now (before the app in front asks for its own). */
    fun paused(home: Activity) {
        atPause = runCatching { home.display?.rotation }.getOrNull() ?: -1
    }

    /** Main thread, after a task left display 0 for a window ([why]): display 0 back to [atPause] if it turned. */
    fun back(
        home: Activity,
        why: String,
    ) {
        val d = runCatching { home.display }.getOrNull() ?: return
        if (d.displayId != android.view.Display.DEFAULT_DISPLAY) return
        val now = d.rotation
        val size = android.graphics.Point().also { @Suppress("DEPRECATION") d.getRealSize(it) }
        val want = orientationFor(atPause, now, naturalPortrait(size.x, size.y, now)) ?: return
        val had = home.requestedOrientation
        if (had != ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED) return // home's own request: never overridden
        val before = atPause
        Log.i(TAG, "display 0 still at rotation $now after $why (home's was $before): home asks orientation $want, then lets go")
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
                    Log.i(TAG, "display 0 at rotation $r (wanted $before): home's request given up")
                }
            }
        main.postDelayed(check, POLL_MS)
    }
}
