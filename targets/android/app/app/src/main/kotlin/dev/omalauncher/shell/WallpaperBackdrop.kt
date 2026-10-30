package dev.omalauncher.shell

import android.graphics.Bitmap
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
 * HACK: IWindowManager.mirrorWallpaperSurface / captureDisplay and ScreenCapture.captureLayers are hidden (the system
 * UI's calls; the permission they check, READ_FRAME_BUFFER, PowOS holds legitimately), reflected ([HiddenApi]). Real
 * fix: a public wallpaper-backdrop API (none: apps can't sample what's behind their window), or the frames handed over
 * by PowOS's system module (a platform-signed hook) through a HardwareBuffer.
 */
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
internal class WallpaperBackdrop(
    /** The display home is on. */
    private val display: () -> Int,
    /** Home's window surface: left out of a display capture. */
    private val window: () -> SurfaceControl?,
    /** The screen's size in px: the mirror's crop (a mirror has no bounds of its own). */
    private val size: () -> android.graphics.Rect,
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
                backoff = 0
                capture()
                val wait = maxOf(backoff, 1000L / FPS - (SystemClock.uptimeMillis() - t0))
                worker.postDelayed(this, wait.coerceAtLeast(0))
            }
        }

    /**
     * How it's captured. MIRROR: the wallpaper's own surface, mirrored (exactly the wallpaper). DISPLAY: the display
     * without home's window (the window manager's captureDisplay, our window excluded) - the wallpaper, and the
     * system bars over it - where the mirror can't be captured. Picked once: the first that gives a frame.
     */
    private enum class Way { MIRROR, DISPLAY }

    @Volatile private var way = Way.MIRROR

    /** The frames have the system bars in them (the display's capture): no rims over the bars. */
    val barsInFrames get() = way == Way.DISPLAY

    /** On the worker. */
    private fun capture() {
        try {
            val m = methods ?: error("no capture calls")
            val id = display()
            val sharp = shot(m, id, SHARP) ?: return
            val soft = shot(m, id, SOFT) ?: return
            // The mirror can come back all black (OxygenOS 16: the wallpaper's mirror renders nothing): the display then.
            if (way == Way.MIRROR && black(soft.copy(Bitmap.Config.ARGB_8888, false))) {
                Log.w(TAG, "the wallpaper's mirror came back black: capturing the display without home instead")
                mirror?.release()
                mirror = null
                way = Way.DISPLAY
                return
            }
            if (!logged) {
                logged = true
                Log.i(TAG, "live wallpaper backdrop ($way): ${sharp.width}x${sharp.height} (+${soft.width}x${soft.height}), display $id")
            }
            main.post { frame(sharp, soft) }
        } catch (e: Throwable) {
            give(e.toString(), e)
        }
    }

    private fun give(
        why: String,
        e: Throwable? = null,
    ) {
        Log.w(TAG, "no live wallpaper backdrop ($why): the liquid glass goes", e)
        dead = true
        until = 0
        main.post(failed)
    }

    /** One frame at [scale], the way that works ([way]; the mirror falls back to the display once); null: none now. */
    private fun shot(
        m: Methods,
        id: Int,
        scale: Float,
    ): Bitmap? {
        if (way == Way.MIRROR) {
            val (buffer, status) = mirrorShot(m, id, scale)
            if (buffer != null) return bitmap(m, buffer)
            Log.w(TAG, "the wallpaper's mirror gave no frame (status $status): capturing the display without home instead")
            mirror?.release()
            mirror = null
            way = Way.DISPLAY
        }
        val (buffer, status) = displayShot(m, id, scale)
        if (buffer != null) {
            misses = 0
            return bitmap(m, buffer)
        }
        // Permission or not supported: for good. Anything else (no answer in time - the compositor busy, a
        // transition, a secure layer up for a moment; home's window not there yet): this frame is skipped and the
        // next one waits a little longer; only a long run of them gives up.
        if (status == PERMISSION_DENIED || status == INVALID_OPERATION) {
            give("display capture status $status")
            return null
        }
        misses++
        Log.w(TAG, "no frame this time (status $status, $misses in a row): trying again")
        if (misses >= MAX_MISSES) give("$misses captures in a row without a frame, the last status $status")
        backoff = (BACKOFF_MS shl (misses - 1).coerceAtMost(4)).coerceAtMost(1_000)
        return null
    }

    /** Captures in a row that gave nothing, and how long the next waits for it. */
    private var misses = 0
    @Volatile private var backoff = 0L

    private fun mirrorShot(
        m: Methods,
        id: Int,
        scale: Float,
    ): Pair<Any?, Int> {
        val mir =
            mirror?.takeIf { mirrorDisplay == id && it.isValid } ?: run {
                mirror?.release()
                (m.mirror.invoke(m.wm, id) as SurfaceControl?).also {
                    mirror = it
                    mirrorDisplay = id
                } ?: return null to NO_MIRROR
            }
        val args = m.layerArgs.newInstance(mir)
        m.setScale.invoke(args, scale)
        // A mirror is boundless: without a crop the compositor answers BAD_VALUE (-22, seen on OxygenOS 16).
        m.setCrop.invoke(args, size())
        return await { listener -> m.captureLayers.invoke(null, m.layerBuild.invoke(args), listener) as Int }
    }

    private fun displayShot(
        m: Methods,
        id: Int,
        scale: Float,
    ): Pair<Any?, Int> {
        val home = window() ?: return null to NO_WINDOW
        val args = m.argsBuilder.newInstance()
        m.setScale.invoke(args, scale)
        m.exclude.invoke(args, arrayOf(home))
        return await { listener ->
            m.captureDisplay.invoke(m.wm, id, m.argsBuild.invoke(args), listener)
            0
        }
    }

    /** Asks with a listener and waits (at most [WAIT_MS]) for its buffer and status ([NO_ANSWER] if none came). */
    private fun await(ask: (Any) -> Int): Pair<Any?, Int> {
        val m = methods!!
        val done = java.util.concurrent.CountDownLatch(1)
        val late = java.util.concurrent.atomic.AtomicBoolean(false)
        var got: Any? = null
        var status = 0
        val listener =
            m.listener.newInstance(
                java.util.function.ObjIntConsumer<Any?> { buffer, s ->
                    // An answer after we stopped waiting: its buffer is nobody's - freed here.
                    if (late.get()) {
                        buffer?.let { b -> runCatching { (m.hardwareBuffer.invoke(b) as android.hardware.HardwareBuffer).close() } }
                        return@ObjIntConsumer
                    }
                    got = buffer
                    status = s
                    done.countDown()
                },
            )
        val asked = ask(listener)
        if (asked != 0) return null to asked
        if (!done.await(WAIT_MS, java.util.concurrent.TimeUnit.MILLISECONDS)) {
            late.set(true)
            return null to NO_ANSWER
        }
        return (if (status == 0) got else null) to status
    }

    private fun bitmap(
        m: Methods,
        buffer: Any,
    ): Bitmap? {
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
        val listener: java.lang.reflect.Constructor<*>,
        val layerArgs: java.lang.reflect.Constructor<*>,
        val layerBuild: java.lang.reflect.Method,
        val captureLayers: java.lang.reflect.Method,
        val argsBuilder: java.lang.reflect.Constructor<*>,
        val argsBuild: java.lang.reflect.Method,
        val setScale: java.lang.reflect.Method,
        val setCrop: java.lang.reflect.Method,
        val exclude: java.lang.reflect.Method,
        val captureDisplay: java.lang.reflect.Method,
        val asBitmap: java.lang.reflect.Method,
        val hardwareBuffer: java.lang.reflect.Method,
    )

    companion object {
        private const val TAG = "PowosBackdrop"
        const val FPS = 30
        const val BURST_MS = 3_000L
        const val WAIT_MS = 500L
        const val BACKOFF_MS = 50L
        const val MAX_MISSES = 40

        /** The compositor's answers (status_t): the ones that won't change by asking again. */
        const val PERMISSION_DENIED = -1
        const val INVALID_OPERATION = -38

        /** Ours: no answer within [WAIT_MS], no mirror to capture, no window of home's to leave out. */
        const val NO_ANSWER = -1001
        const val NO_MIRROR = -1002
        const val NO_WINDOW = -1003

        /** The two sizes captured: lightly blurred by the scaling (the edge's), and as soft as the inside's blur. */
        const val SHARP = 0.25f
        const val SOFT = 1f / 32f

        /**
         * The wallpaper as it is on screen now, once (ShellWallpaper's picture of a live wallpaper - the exact frame,
         * never the system's stale screenshot of it): its mirror captured at [scale] within [crop], copied into a plain
         * bitmap. Blocks up to [WAIT_MS]: not on the main thread. Null: it can't (no permission, no wallpaper surface).
         */
        /** Home's window surface, while home is up (ShellActivity sets it): left out of a display capture. */
        @Volatile var homeWindow: (() -> SurfaceControl?)? = null

        /** The system bars' heights over home, px (top, bottom): painted over in a display capture's picture. */
        @Volatile var homeBars: (() -> Pair<Int, Int>)? = null

        /**
         * The status and navigation bars in a display capture painted over with the wallpaper's pixels just inside
         * them (each bar strip filled with the row next to it): a page drawing this picture under itself must not
         * draw a second, blurred copy of the bars.
         */
        private fun fillBars(
            b: Bitmap,
            scale: Float,
        ) {
            val (top, bottom) = homeBars?.invoke() ?: return
            val t = kotlin.math.ceil(top * scale).toInt().coerceIn(0, b.height / 3)
            val u = kotlin.math.ceil(bottom * scale).toInt().coerceIn(0, b.height / 3)
            val row = IntArray(b.width)
            if (t > 0) {
                b.getPixels(row, 0, b.width, 0, t, b.width, 1)
                for (y in 0 until t) b.setPixels(row, 0, b.width, 0, y, b.width, 1)
            }
            if (u > 0) {
                b.getPixels(row, 0, b.width, 0, b.height - u - 1, b.width, 1)
                for (y in b.height - u until b.height) b.setPixels(row, 0, b.width, 0, y, b.width, 1)
            }
        }

        /** All but black: a 16 x 16 grid of its pixels darker than 8 in every channel. */
        fun black(b: Bitmap): Boolean {
            for (y in 0 until 16) for (x in 0 until 16) {
                val c = b.getPixel(x * (b.width - 1) / 15, y * (b.height - 1) / 15)
                if ((c shr 16 and 0xff) > 8 || (c shr 8 and 0xff) > 8 || (c and 0xff) > 8) return false
            }
            return true
        }

        /**
         * The wallpaper as it is on screen now, once: its mirror; if that comes back black (as on OxygenOS 16), the
         * display with home's window left out ([homeWindow]) - the wallpaper and the system bars over it.
         */
        fun still(
            displayId: Int,
            crop: android.graphics.Rect,
            scale: Float,
        ): Bitmap? {
            mirrorStill(displayId, crop, scale)?.let { if (!black(it)) return it else it.recycle() }
            return displayStill(displayId, scale)
        }

        private fun displayStill(
            displayId: Int,
            scale: Float,
        ): Bitmap? {
            val m = methods ?: return null
            val home = homeWindow?.invoke() ?: return null.also { Log.w(TAG, "no still: home's window isn't up") }
            try {
                val args = m.argsBuilder.newInstance()
                m.setScale.invoke(args, scale)
                m.exclude.invoke(args, arrayOf(home))
                val done = java.util.concurrent.CountDownLatch(1)
                var got: Any? = null
                var status = -1
                val listener =
                    m.listener.newInstance(
                        java.util.function.ObjIntConsumer<Any?> { b, st ->
                            got = b
                            status = st
                            done.countDown()
                        },
                    )
                m.captureDisplay.invoke(m.wm, displayId, m.argsBuild.invoke(args), listener)
                if (!done.await(WAIT_MS, java.util.concurrent.TimeUnit.MILLISECONDS) || status != 0 || got == null) {
                    Log.w(TAG, "no still of the display: status $status")
                    return null
                }
                val buffer = got!!
                val hw = m.asBitmap.invoke(buffer) as Bitmap? ?: return null
                runCatching { (m.hardwareBuffer.invoke(buffer) as android.hardware.HardwareBuffer).close() }
                return hw.copy(Bitmap.Config.ARGB_8888, true).also {
                    hw.recycle()
                    fillBars(it, scale)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "no still of the display", e)
                return null
            }
        }

        /**
         * [layer]'s tree (an offscreen one too) rendered by the compositor within [crop] at [scale], once, as a hardware
         * bitmap ([RestGlass]'s probe: its blur regions drawn by SurfaceFlinger's own blur). Blocks up to [WAIT_MS]: not
         * on the main thread. Null: it can't.
         */
        fun layerShot(
            layer: SurfaceControl,
            crop: android.graphics.Rect,
            scale: Float,
        ): Bitmap? {
            val m = methods ?: return null
            try {
                val args = m.layerArgs.newInstance(layer)
                m.setScale.invoke(args, scale)
                m.setCrop.invoke(args, crop)
                val done = java.util.concurrent.CountDownLatch(1)
                var got: Any? = null
                var status = -1
                val listener =
                    m.listener.newInstance(
                        java.util.function.ObjIntConsumer<Any?> { b, st ->
                            got = b
                            status = st
                            done.countDown()
                        },
                    )
                val asked = m.captureLayers.invoke(null, m.layerBuild.invoke(args), listener) as Int
                if (asked != 0 || !done.await(WAIT_MS, java.util.concurrent.TimeUnit.MILLISECONDS) || status != 0 || got == null) {
                    Log.w(TAG, "no shot of a layer: asked $asked, status $status")
                    return null
                }
                val buffer = got ?: return null
                val hw = m.asBitmap.invoke(buffer) as Bitmap? ?: return null
                runCatching { (m.hardwareBuffer.invoke(buffer) as android.hardware.HardwareBuffer).close() }
                return hw
            } catch (e: Throwable) {
                Log.w(TAG, "no shot of a layer", e)
                return null
            }
        }

        private fun mirrorStill(
            displayId: Int,
            crop: android.graphics.Rect,
            scale: Float,
        ): Bitmap? {
            val m = methods ?: return null
            val mir =
                runCatching { m.mirror.invoke(m.wm, displayId) as SurfaceControl? }.onFailure { Log.w(TAG, "no wallpaper mirror", it) }.getOrNull()
                    ?: return null
            try {
                val args = m.layerArgs.newInstance(mir)
                m.setScale.invoke(args, scale)
                m.setCrop.invoke(args, crop)
                val done = java.util.concurrent.CountDownLatch(1)
                var got: Any? = null
                var status = -1
                val listener =
                    m.listener.newInstance(
                        java.util.function.ObjIntConsumer<Any?> { b, st ->
                            got = b
                            status = st
                            done.countDown()
                        },
                    )
                val asked = m.captureLayers.invoke(null, m.layerBuild.invoke(args), listener) as Int
                val answered = asked == 0 && done.await(WAIT_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
                if (!answered || status != 0 || got == null) {
                    Log.w(TAG, "no still of the wallpaper: asked $asked, answered $answered, status $status (the screen off: nothing drawn)")
                    return null
                }
                val buffer = got ?: return null
                val hw = m.asBitmap.invoke(buffer) as Bitmap? ?: return null
                runCatching { (m.hardwareBuffer.invoke(buffer) as android.hardware.HardwareBuffer).close() }
                return hw.copy(Bitmap.Config.ARGB_8888, false).also { hw.recycle() }
            } catch (e: Throwable) {
                Log.w(TAG, "no still of the wallpaper", e)
                return null
            } finally {
                mir.release()
            }
        }

        private val methods: Methods? by lazy {
            runCatching {
                HiddenApi.allow()
                val wmg = Class.forName("android.view.WindowManagerGlobal")
                val wm = wmg.getMethod("getWindowManagerService").invoke(null) ?: error("no window manager")
                val iwm = Class.forName("android.view.IWindowManager")
                val sc = Class.forName("android.window.ScreenCapture")
                val listener = Class.forName("android.window.ScreenCapture\$ScreenCaptureListener")
                val args = Class.forName("android.window.ScreenCapture\$CaptureArgs")
                val argsBuilder = Class.forName("android.window.ScreenCapture\$CaptureArgs\$Builder")
                val layerArgs = Class.forName("android.window.ScreenCapture\$LayerCaptureArgs")
                val layerBuilder = Class.forName("android.window.ScreenCapture\$LayerCaptureArgs\$Builder")
                val shb = Class.forName("android.window.ScreenCapture\$ScreenshotHardwareBuffer")
                Methods(
                    wm,
                    iwm.getMethod("mirrorWallpaperSurface", Int::class.javaPrimitiveType),
                    listener.getDeclaredConstructor(java.util.function.ObjIntConsumer::class.java).apply { isAccessible = true },
                    layerBuilder.getConstructor(SurfaceControl::class.java),
                    layerBuilder.getMethod("build"),
                    sc.getMethod("captureLayers", layerArgs, listener),
                    argsBuilder.getConstructor(),
                    argsBuilder.getMethod("build"),
                    argsBuilder.getMethod("setFrameScale", Float::class.javaPrimitiveType),
                    argsBuilder.getMethod("setSourceCrop", android.graphics.Rect::class.java),
                    argsBuilder.getMethod("setExcludeLayers", Array<SurfaceControl>::class.java),
                    iwm.getMethod("captureDisplay", Int::class.javaPrimitiveType, args, listener),
                    shb.getMethod("asBitmap"),
                    shb.getMethod("getHardwareBuffer"),
                )
            }.onFailure { Log.w(TAG, "no wallpaper capture calls on this Android", it) }.getOrNull()
        }
    }
}
