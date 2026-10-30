package dev.omalauncher.shell

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.SurfaceControl
import android.view.View
import androidx.annotation.RequiresApi

/**
 * Home's glass at rest: SurfaceFlinger's blur, rendered once, drawn as a picture in home's own buffer - so a still
 * home has no blur regions and its layers are composited by the display hardware (DEVICE), not by the GPU every frame.
 *
 * Any blur region on a layer makes SurfaceFlinger GPU-composite (CLIENT, clientType=BLUR) every layer up to and
 * including it: with the dock's, the widgets' and the nav strip's regions on home's window, the wallpaper and home were
 * CLIENT-composited every frame of a home where nothing moved (dumpsys SurfaceFlinger, 2026-10-30; the inner display's
 * "GPU missed frame count" ~236k). The page says when it is still ("b.rest 1", ui/nativeglass.ts: no glass moved for
 * its still frames plus REST_MS) and when it moves again ("b.rest 0", the frame motion starts, before that frame's
 * regions); [GlassBlur] swaps the live regions for this picture and back.
 *
 * The picture is the compositor's own blur, not a copy of it: the wallpaper as it is on screen now
 * ([WallpaperBackdrop.still], full size) is set as the buffer of an offscreen layer, a second offscreen layer above it
 * carries the very blur regions the window has now (the same encoded arrays: radius, corners, alpha), and
 * SurfaceFlinger renders that little tree ([WallpaperBackdrop.layerShot]) - with the blur it draws on screen. Each
 * region's rect (a little larger: its rounded corners come with the picture, the wallpaper's own sharp pixels outside
 * them) of that render is drawn under the page; live and at rest are the same pixels.
 *
 * Only while the wallpaper itself is still (two small captures [MOTION_MS] apart the same: OxygenOS's video wallpapers
 * play after an unlock or a fold), else the live regions stay and it is tried again a little later. The same regions
 * over the same wallpaper reuse the last render.
 *
 * HACK: the probe needs the hidden capture calls ([WallpaperBackdrop]) and blur regions ([GlassBlur]); real fix: a
 * compositor that composites a static blur once and caches it (SurfaceFlinger re-blurs every frame of a still screen),
 * or the cache from PowOS's system module.
 */
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
internal class RestGlass(
    context: Context,
    /** The window's encoded blur regions onto a layer (GlassBlur's hidden Transaction.setBlurRegions). */
    private val setRegions: (SurfaceControl.Transaction, SurfaceControl, Array<FloatArray>) -> Unit,
) {
    private val thread = HandlerThread("powos-rest-glass").apply { start() }
    private val worker = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())

    /** Draws the render under the page, cropped to the regions' boxes. */
    val view: View = Picture(context)

    /** The last render, what it was made of: the same regions over the same wallpaper draw it again. */
    private var cache: Bitmap? = null
    private var cacheFor: Array<FloatArray>? = null
    private var cacheTiny: Bitmap? = null

    /** The request now: a newer one (or a cancel) makes an older one's answer moot. */
    @Volatile private var seq = 0

    /** It can't here (the probe rendered nothing): the live regions stay for good. */
    @Volatile var dead = false
        private set

    private var retry = 0L

    /**
     * Renders [shown] (the window's encoded regions) over the wallpaper as it is now, on the worker; [ready] gets the
     * picture on the main thread, unless [cancel] or another [render] came first. Null: not now (the wallpaper moving
     * - asked again by itself in a moment - or a capture failed).
     */
    fun render(
        display: Int,
        size: Rect,
        shown: Array<FloatArray>,
        ready: (Bitmap) -> Unit,
    ) {
        if (dead) return
        val id = ++seq
        worker.removeCallbacksAndMessages(null)
        worker.post {
            if (id != seq) return@post
            val tiny = WallpaperBackdrop.still(display, size, TINY) ?: return@post
            Thread.sleep(MOTION_MS)
            if (id != seq) return@post
            val again = WallpaperBackdrop.still(display, size, TINY) ?: return@post
            if (!same(tiny, again)) {
                // The wallpaper plays (a video one, after an unlock): live blur until it's still.
                retry = (retry * 2).coerceIn(RETRY_MS, MAX_RETRY_MS)
                Log.i(TAG, "the wallpaper moves: live glass, again in ${retry} ms")
                worker.postDelayed({ if (id == seq) main.post { if (id == seq) render(display, size, shown, ready) } }, retry)
                return@post
            }
            retry = 0
            val hit = cache?.takeIf { cacheFor?.contentDeepEquals(shown) == true && cacheTiny?.let { same(it, again) } == true }
            val pic = hit ?: probe(display, size, shown) ?: return@post
            if (hit == null) {
                cache = pic
                cacheFor = shown
                cacheTiny = again
            }
            main.post { if (id == seq) ready(pic) }
        }
    }

    /** Whatever render is under way: its answer goes nowhere. */
    fun cancel() {
        seq++
    }

    /** SurfaceFlinger's render of [shown] over the wallpaper now, full size (a hardware bitmap); null: it can't. */
    private fun probe(
        display: Int,
        size: Rect,
        shown: Array<FloatArray>,
    ): Bitmap? {
        val sharp = WallpaperBackdrop.still(display, size, 1f) ?: return null
        val hw = sharp.copy(Bitmap.Config.HARDWARE, false)
        sharp.recycle()
        val buffer = hw?.hardwareBuffer ?: return null
        val root = SurfaceControl.Builder().setName("powos-rest-probe").build()
        val pic = SurfaceControl.Builder().setName("powos-rest-wallpaper").setParent(root).setBufferSize(hw.width, hw.height).build()
        val blur = SurfaceControl.Builder().setName("powos-rest-blur").setParent(root).build()
        try {
            val committed = java.util.concurrent.CountDownLatch(1)
            val t = SurfaceControl.Transaction()
            t.setBuffer(pic, buffer).setLayer(pic, 0).setVisibility(pic, true)
            t.setLayer(blur, 1).setVisibility(blur, true)
            t.setVisibility(root, true)
            // A layer without a buffer of its own has its parent's bounds: an offscreen root's are the screen's here.
            t.setCrop(root, Rect(0, 0, size.width(), size.height()))
            setRegions(t, blur, shown)
            t.addTransactionCommittedListener(Runnable::run) { committed.countDown() }
            t.apply()
            committed.await(WallpaperBackdrop.WAIT_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
            val out = WallpaperBackdrop.layerShot(root, Rect(0, 0, size.width(), size.height()), 1f) ?: return null
            // Nothing rendered (the buffer not latched yet, or a compositor that won't render an offscreen tree): a
            // transparent picture would show bare wallpaper where the glass is - never; the live glass stays.
            val check = WallpaperBackdrop.layerShot(root, Rect(0, 0, size.width(), size.height()), TINY)?.let { s -> s.copy(Bitmap.Config.ARGB_8888, false).also { s.recycle() } }
            val opaque = check != null && (check.getPixel(check.width / 2, check.height / 2) ushr 24) > 0xf0
            check?.recycle()
            if (!opaque) {
                Log.w(TAG, "the probe rendered nothing: no rest glass here")
                out.recycle()
                dead = true
                return null
            }
            return out
        } catch (e: Throwable) {
            Log.w(TAG, "no rest glass", e)
            dead = true
            return null
        } finally {
            SurfaceControl.Transaction().reparent(pic, null).reparent(blur, null).apply()
            pic.release()
            blur.release()
            root.release()
            buffer.close()
            hw.recycle()
        }
    }

    /** Shows [pic] within [boxes] (window px) on the window's next draw. */
    fun show(
        pic: Bitmap,
        boxes: List<RectF>,
    ) = (view as Picture).show(pic, boxes)

    /** Off on the window's next draw. */
    fun hide() = (view as Picture).show(null, emptyList())

    val shown get() = (view as Picture).pic != null

    fun close() {
        cancel()
        hide()
        thread.quitSafely()
    }

    private class Picture(context: Context) : View(context) {
        var pic: Bitmap? = null
        private var boxes: List<RectF> = emptyList()
        private val at = IntArray(2)

        init {
            neverFocus()
            isClickable = false
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        fun show(
            p: Bitmap?,
            b: List<RectF>,
        ) {
            if (p == null && pic == null) return
            pic = p
            boxes = b
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            val p = pic ?: return
            getLocationInWindow(at)
            for (r in boxes) {
                canvas.save()
                canvas.translate(-at[0].toFloat(), -at[1].toFloat())
                canvas.clipRect(r)
                canvas.drawBitmap(p, 0f, 0f, null)
                canvas.restore()
            }
        }
    }

    companion object {
        private const val TAG = "PowosRestGlass"

        /** The wallpaper's motion check: two captures this small, this far apart. */
        private const val TINY = 1f / 32f
        private const val MOTION_MS = 150L
        private const val RETRY_MS = 500L
        private const val MAX_RETRY_MS = 5_000L

        /** Two small captures alike (each channel within a few levels: the capture's own dither). */
        private fun same(
            a: Bitmap,
            b: Bitmap,
        ): Boolean {
            if (a.width != b.width || a.height != b.height) return false
            for (y in 0 until a.height) for (x in 0 until a.width) {
                val p = a.getPixel(x, y)
                val q = b.getPixel(x, y)
                for (s in intArrayOf(0, 8, 16)) if (kotlin.math.abs((p shr s and 0xff) - (q shr s and 0xff)) > 3) return false
            }
            return true
        }
    }
}
