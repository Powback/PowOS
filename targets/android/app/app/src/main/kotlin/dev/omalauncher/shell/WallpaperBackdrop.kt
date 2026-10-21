package dev.omalauncher.shell

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.SurfaceControl
import androidx.annotation.RequiresApi
import dev.omalauncher.system.HiddenApi

/**
 * What's behind home, live: the wallpaper's own frames, for the liquid glass to bend ([LiquidGlass]). The window
 * manager gives a privileged holder of READ_FRAME_BUFFER (PowOS: the recents role grants it) a mirror of the wallpaper
 * window's surface ([mirrorWallpaperSurface]: a layer showing exactly the wallpaper's buffers, whatever draws them - a
 * still picture, OxygenOS's video wallpapers, any live one); the compositor renders that layer into a buffer on request
 * ([captureLayers], scaled down: it's bent and blurred anyway) - the wallpaper only, never our own window over it.
 *
 * Captured in bursts, not per frame: a wallpaper changes when it's set, when home comes back (an unlock, a fold - when
 * OxygenOS's video wallpapers play), when the screen changes; [burst] captures at up to [FPS] for a while then stops.
 * While home is still, or while only the page's surfaces move over an unchanged wallpaper, nothing is captured.
 *
 * HACK: IWindowManager.mirrorWallpaperSurface and ScreenCapture.captureLayers are hidden (the system UI's calls; the
 * permission they check, READ_FRAME_BUFFER, PowOS holds legitimately), reflected past the checks ([HiddenApi]). Real
 * fix: a public wallpaper-backdrop API (none: apps can't sample what's behind their window), or the frames handed over
 * by PowOS's system module (a platform-signed hook) through a HardwareBuffer.
 */
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
internal class WallpaperBackdrop(
    /** The display home is on. */
    private val display: () -> Int,
    /** A new frame (main thread): the wallpaper at [SHARP] and [SOFT] of its size. */
    private val frame: (sharp: Bitmap, soft: Bitmap) -> Unit,
    /** It can't (no permission, no such call, nothing comes back): the liquid glass goes. */
    private val failed: () -> Unit,
) {
    private val thread = HandlerThread("powos-backdrop").apply { start() }
    private val worker = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private var mirror: SurfaceControl? = null
    private var mirrorDisplay = -1

    @Volatile private var until = 0L
    private var running = false

    @Volatile private var dead = false
    private var logged = false

    /** Captures for [ms] from now (at most [FPS] a second), then stops. */
    fun burst(ms: Long = BURST_MS) {
        if (dead) return
        val end = SystemClock.uptimeMillis() + ms
        if (end > until) until = end
        worker.post {
            if (running) return@post
            running = true
            loop.run()
        }
    }

    private val loop: Runnable =
        object : Runnable {
            override fun run() {
                if (dead || SystemClock.uptimeMillis() > until) {
                    running = false
                    return
                }
                val t0 = SystemClock.uptimeMillis()
                capture()
                worker.postDelayed(this, (1000L / FPS - (SystemClock.uptimeMillis() - t0)).coerceAtLeast(0))
            }
        }

    /** On the worker. */
    private fun capture() {
        try {
            val m = methods ?: error("no capture calls")
            val id = display()
            val mir =
                mirror?.takeIf { mirrorDisplay == id && it.isValid } ?: run {
                    mirror?.release()
                    (m.mirror.invoke(m.wm, id) as SurfaceControl?).also {
                        mirror = it
                        mirrorDisplay = id
                    } ?: error("no wallpaper surface to mirror on display $id")
                }
            val sharp = shot(m, mir, SHARP) ?: return again(mir, "no frame")
            val soft = shot(m, mir, SOFT) ?: return again(mir, "no soft frame")
            if (!logged) {
                logged = true
                Log.i(TAG, "live wallpaper backdrop: ${sharp.width}x${sharp.height} (+${soft.width}x${soft.height}), display $id")
            }
            main.post { frame(sharp, soft) }
        } catch (e: Throwable) {
            Log.w(TAG, "no live wallpaper backdrop: the liquid glass goes", e)
            dead = true
            main.post(failed)
        }
    }

    /** Nothing came back: the mirror is likely stale (another wallpaper) - a new one next time. */
    private fun again(
        mir: SurfaceControl,
        why: String,
    ) {
        Log.w(TAG, "$why: mirroring the wallpaper again")
        mir.release()
        mirror = null
    }

    private fun shot(
        m: Methods,
        mir: SurfaceControl,
        scale: Float,
    ): Bitmap? {
        val buffer = m.capture.invoke(null, mir, null as Rect?, scale) ?: return null
        val bitmap = m.asBitmap.invoke(buffer) as Bitmap? ?: return null
        // The bitmap holds the buffer now; our own reference goes.
        runCatching { (m.hardwareBuffer.invoke(buffer) as android.hardware.HardwareBuffer).close() }
        return bitmap
    }

    fun close() {
        dead = true
        worker.post {
            mirror?.release()
            mirror = null
            thread.quitSafely()
        }
    }

    private class Methods(
        val wm: Any,
        val mirror: java.lang.reflect.Method,
        val capture: java.lang.reflect.Method,
        val asBitmap: java.lang.reflect.Method,
        val hardwareBuffer: java.lang.reflect.Method,
    )

    companion object {
        private const val TAG = "PowosBackdrop"
        const val FPS = 30
        const val BURST_MS = 3_000L

        /** The two sizes captured: lightly blurred by the scaling (the edge's), and as soft as the inside's blur. */
        const val SHARP = 0.25f
        const val SOFT = 1f / 32f

        private val methods: Methods? by lazy {
            runCatching {
                HiddenApi.allow()
                val wmg = Class.forName("android.view.WindowManagerGlobal")
                val wm = wmg.getMethod("getWindowManagerService").invoke(null) ?: error("no window manager")
                val iwm = Class.forName("android.view.IWindowManager")
                val sc = Class.forName("android.window.ScreenCapture")
                val shb = Class.forName("android.window.ScreenCapture\$ScreenshotHardwareBuffer")
                Methods(
                    wm,
                    iwm.getMethod("mirrorWallpaperSurface", Int::class.javaPrimitiveType),
                    sc.getMethod("captureLayers", SurfaceControl::class.java, Rect::class.java, Float::class.javaPrimitiveType),
                    shb.getMethod("asBitmap"),
                    shb.getMethod("getHardwareBuffer"),
                )
            }.onFailure { Log.w(TAG, "no wallpaper capture calls on this Android", it) }.getOrNull()
        }
    }
}
