package dev.omalauncher.shell

import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Choreographer
import android.view.SurfaceControl
import android.view.View
import android.view.WindowManager
import androidx.annotation.RequiresApi
import dev.omalauncher.system.HiddenApi
import java.util.function.Consumer

/**
 * The shell's glass blurred live by the display compositor: the page (shell/ui/nativeglass.ts) says where its glass
 * surfaces are - rounded rectangles in CSS px - and SurfaceFlinger draws, under the window's own pixels, what's
 * behind the window (the wallpaper, under home's transparent page) blurred inside each of them. The page only tints
 * them (theme.css); the WebView renders and composites no blur at all. These are the blur regions SystemUI's
 * BackgroundBlurDrawable gives SurfaceFlinger (one blur pass per frame for every region of a radius, on the GPU, in
 * the compositor), on the window's surface, on the same frame the window draws ([AttachedSurfaceControl.
 * applyTransactionOnDraw]) - so a surface moving with the page has its blur move on the same frame.
 *
 * On only where the compositor blurs at all ([WindowManager.isCrossWindowBlurEnabled]: off in battery saver, with
 * blurs disabled in the developer options, on a device without them) and while the style allows it (Style.LIVE_BLUR);
 * the page is told ("b.state 1|0") and falls back to its pre-blurred picture of the wallpaper (ui/glass.ts) when off.
 *
 * HACK: Transaction.setBlurRegions and ViewRootImpl.getSurfaceControl are hidden (SystemUI's own calls), reflected past
 * the checks ([HiddenApi]); where they aren't there the page is told "b.state 0" and keeps the CSS glass. Real fix: a
 * public blur-region API (Android has none: Window.setBackgroundBlurRadius blurs a whole window's background
 * drawable), or the regions set from the platform-signed side (a SystemUI plugin in the system module).
 */
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
internal class GlassBlur(
    private val view: View,
    /** Tells the page whether the compositor blurs for it now. */
    private val state: (Boolean) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val windows = view.context.getSystemService(WindowManager::class.java)

    /** The style's switch (Style.LIVE_BLUR). */
    private var allowed = true

    /** The compositor blurs (Android's own switch: battery saver, the developer option, thermal). */
    private var compositorBlurs = runCatching { windows.isCrossWindowBlurEnabled }.getOrDefault(false)

    /** The hidden calls aren't there, or failed: off for good. */
    private var broken = methods == null

    /** What the page was told last. */
    private var told: Boolean? = null

    /** The page's regions, in the window's pixels (radius, alpha, l, t, r, b, tl, tr, bl, br each), as last set. */
    private var regions: Array<FloatArray> = emptyArray()

    /** Rectangles (window px) where a surface tile shows under the page: no blur over them ([ShellNative] tiles). */
    var holes: () -> List<RectF> = { emptyList() }

    /**
     * Test knob ("b.lag"): frames the regions wait before riding on a draw (0: the next draw - the default), or -1:
     * applied at once, on no frame of the window's.
     */
    @Volatile var lag = 0

    private val blurListener = Consumer<Boolean> { on -> compositorBlurs = on; update() }

    init {
        runCatching { windows.addCrossWindowBlurEnabledListener({ main.post(it) }, blurListener) }
        main.post { update() }
    }

    val on get() = allowed && compositorBlurs && !broken

    fun allow(on: Boolean) {
        allowed = on
        update()
    }

    /** The page asked (again, on its reload): tell it. */
    fun hello() = main.post { told = null; update() }

    private fun update() {
        val now = on
        if (!now && regions.isNotEmpty()) set(emptyArray(), -1)
        if (told == now) return
        told = now
        state(now)
    }

    /**
     * "b.r <dpr> <n> [x y w h tl tr br bl alpha radius] * n" (CSS px of the page; radius: the blur's), on the port's
     * thread: parsed there, set on the main thread.
     */
    fun command(rest: String) {
        val t = rest.trim().split(' ')
        val dpr = t[0].toFloat()
        val n = t[1].toInt()
        val out = arrayOfNulls<FloatArray>(n)
        var i = 2
        for (k in 0 until n) {
            val x = t[i++].toFloat() * dpr
            val y = t[i++].toFloat() * dpr
            val w = t[i++].toFloat() * dpr
            val h = t[i++].toFloat() * dpr
            val tl = t[i++].toFloat() * dpr
            val tr = t[i++].toFloat() * dpr
            val br = t[i++].toFloat() * dpr
            val bl = t[i++].toFloat() * dpr
            val alpha = t[i++].toFloat()
            val radius = t[i++].toFloat() * dpr
            // BackgroundBlurDrawable.BlurRegion.toFloatArray's order: radius, alpha, the rect, then tl, tr, bl, br.
            out[k] = floatArrayOf(radius, alpha, x, y, x + w, y + h, tl, tr, bl, br)
        }
        @Suppress("UNCHECKED_CAST")
        val regions = out as Array<FloatArray>
        val lag = lag
        main.post { if (on) set(regions, lag) }
    }

    /** Another page (a reload): its regions are its own to set; until then none. */
    fun reset() = main.post {
        told = null
        if (regions.isNotEmpty()) set(emptyArray(), -1)
    }

    /** A surface tile came or went: the regions again without what's over it. */
    fun holesChanged() = main.post { if (on && regions.isNotEmpty()) set(regions, -1) }

    fun close() {
        runCatching { windows.removeCrossWindowBlurEnabledListener(blurListener) }
        main.post { if (regions.isNotEmpty()) set(emptyArray(), -1) }
    }

    private fun set(
        regions: Array<FloatArray>,
        lag: Int,
    ) {
        this.regions = regions
        val m = methods ?: return
        val root = view.rootSurfaceControl ?: return
        try {
            val viewRoot = m.viewRoot.invoke(view) ?: return
            val surface = m.surface.invoke(viewRoot) as SurfaceControl? ?: return
            if (!surface.isValid) return
            // The window's own offset (none for home: full screen) - regions are in the window surface's space.
            val at = IntArray(2).also(view::getLocationInWindow)
            val holes = holes()
            val shown =
                regions
                    .filter { r -> holes.none { h -> RectF.intersects(h, RectF(r[2], r[3], r[4], r[5])) } }
                    .map { r -> if (at[0] == 0 && at[1] == 0) r else r.copyOf().also { it[2] += at[0]; it[4] += at[0]; it[3] += at[1]; it[5] += at[1] } }
                    .toTypedArray()
            val t = SurfaceControl.Transaction()
            m.setBlurRegions.invoke(t, surface, shown)
            when {
                lag < 0 -> t.apply()
                lag == 0 -> {
                    root.applyTransactionOnDraw(t)
                    view.invalidate()
                }
                else -> {
                    var left = lag
                    val cb =
                        object : Choreographer.FrameCallback {
                            override fun doFrame(frameTimeNanos: Long) {
                                if (--left > 0) return Choreographer.getInstance().postFrameCallback(this)
                                root.applyTransactionOnDraw(t)
                                view.invalidate()
                            }
                        }
                    Choreographer.getInstance().postFrameCallback(cb)
                }
            }
        } catch (e: ReflectiveOperationException) {
            fail(e)
        } catch (e: RuntimeException) {
            fail(e)
        }
    }

    private fun fail(e: Exception) {
        Log.w(TAG, "no blur regions on this window: the page keeps its own glass", e)
        broken = true
        regions = emptyArray()
        update()
    }

    private class Methods(
        val viewRoot: java.lang.reflect.Method,
        val surface: java.lang.reflect.Method,
        val setBlurRegions: java.lang.reflect.Method,
    )

    companion object {
        private const val TAG = "PowosGlassBlur"

        private val methods: Methods? by lazy {
            runCatching {
                HiddenApi.allow()
                val viewRoot = View::class.java.getMethod("getViewRootImpl")
                Methods(
                    viewRoot,
                    viewRoot.returnType.getMethod("getSurfaceControl"),
                    SurfaceControl.Transaction::class.java.getMethod("setBlurRegions", SurfaceControl::class.java, Array<FloatArray>::class.java),
                )
            }.onFailure { Log.w(TAG, "no blur regions on this Android", it) }.getOrNull()
        }
    }
}
