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
 * Each region is encoded by the framework itself: a BackgroundBlurDrawable (ViewRootImpl.createBackgroundBlurDrawable)
 * set to the region, then its BlurRegion's toFloatArray() - the very array ViewRootImpl hands setBlurRegions, in this
 * build's layout. That layout is the OEM's: AOSP's is 10 floats, OxygenOS 16's 31 (a blur colour and its own blur
 * parameters after them), and a wrong length aborts the whole app in JNI (seen: home crash-looped on 2026-10-21 with
 * hand-built 10-float regions) - so nothing here ever builds one by hand. Checked once, before the page is told it can
 * have live glass: a test region must come back with its values where they belong, or it's "b.state 0".
 *
 * HACK: Transaction.setBlurRegions, ViewRootImpl.getSurfaceControl / createBackgroundBlurDrawable and
 * BackgroundBlurDrawable's BlurRegion are hidden (SystemUI's own calls), reflected past the checks ([HiddenApi]); where
 * they aren't there, or the check fails, the page is told "b.state 0" and keeps the CSS glass. Real fix: a
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

    /** The framework's region encoder, checked ([check]): null until the view is in its window; false - unusable. */
    private var codec: Codec? = null
    private var checked: Boolean? = null
    private var waitingForWindow = false

    /** What the page was told last. */
    private var told: Boolean? = null

    /** The page's regions, in the window's pixels, as last set. */
    private var regions: List<Region> = emptyList()

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

    val on get() = allowed && compositorBlurs && !broken && checked == true

    fun allow(on: Boolean) {
        allowed = on
        update()
    }

    /** The page asked (again, on its reload): tell it. */
    fun hello() = main.post { told = null; update() }

    private fun update() {
        if (checked == null && !broken) check()
        val now = on
        if (!now && regions.isNotEmpty()) set(emptyList(), -1)
        if (told == now) return
        told = now
        state(now)
    }

    /**
     * Once, in the window: the framework's encoder made, and a test region encoded - its radius, alpha, rect and
     * corners must come back where AOSP's layout has them (the OEM's extra floats after them are its own). Anything
     * else - no such class, another layout, an exception - and the live glass stays off.
     */
    private fun check() {
        if (!view.isAttachedToWindow) {
            if (!waitingForWindow) {
                waitingForWindow = true
                view.addOnAttachStateChangeListener(
                    object : View.OnAttachStateChangeListener {
                        override fun onViewAttachedToWindow(v: View) {
                            v.removeOnAttachStateChangeListener(this)
                            waitingForWindow = false
                            update()
                        }

                        override fun onViewDetachedFromWindow(v: View) = Unit
                    },
                )
            }
            return
        }
        checked =
            try {
                val m = methods ?: error("no hidden calls")
                val c = Codec(m, m.viewRoot.invoke(view) ?: error("no view root"))
                val a = c.encode(Region(10f, 20f, 110f, 220f, 1f, 2f, 3f, 4f, 0.5f, 30f))
                val ok =
                    a.size >= 10 && a[0] == 30f && kotlin.math.abs(a[1] - 0.5f) < 0.01f && a[2] == 10f && a[3] == 20f &&
                        a[4] == 110f && a[5] == 220f && a[6] == 1f && a[7] == 2f && a[8] == 4f && a[9] == 3f
                if (ok) codec = c
                Log.i(TAG, "blur regions ${if (ok) "usable" else "NOT usable"}: ${a.size} floats per region (${a.take(10)})")
                ok
            } catch (e: Throwable) {
                Log.w(TAG, "no blur regions here: the page keeps its own glass", e)
                false
            }
    }

    /**
     * "b.r <dpr> <n> [x y w h tl tr br bl alpha radius] * n" (CSS px of the page; radius: the blur's), on the port's
     * thread: parsed there, set on the main thread.
     */
    fun command(rest: String) {
        val regions =
            try {
                val t = rest.trim().split(' ')
                val dpr = t[0].toFloat()
                val n = t[1].toInt()
                var i = 2
                List(n) {
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
                    Region(x, y, x + w, y + h, tl, tr, br, bl, alpha, radius)
                }
            } catch (e: RuntimeException) {
                Log.w(TAG, "b.r: bad regions ($e)")
                return
            }
        val lag = lag
        main.post { if (on) set(regions, lag) }
    }

    /** Another page (a reload): its regions are its own to set; until then none. */
    fun reset() = main.post {
        told = null
        if (regions.isNotEmpty()) set(emptyList(), -1)
    }

    /** A surface tile came or went: the regions again without what's over it. */
    fun holesChanged() = main.post { if (on && regions.isNotEmpty()) set(regions, -1) }

    fun close() {
        runCatching { windows.removeCrossWindowBlurEnabledListener(blurListener) }
        main.post { if (regions.isNotEmpty()) set(emptyList(), -1) }
    }

    /** On the main thread. Any failure turns the live glass off - it never takes the app down with it. */
    private fun set(
        regions: List<Region>,
        lag: Int,
    ) {
        this.regions = regions
        val m = methods ?: return
        try {
            val root = view.rootSurfaceControl ?: return
            val viewRoot = m.viewRoot.invoke(view) ?: return
            val surface = m.surface.invoke(viewRoot) as SurfaceControl? ?: return
            if (!surface.isValid) return
            // Clearing needs no encoder; anything else only the checked one.
            val c = codec
            if (regions.isNotEmpty() && c == null) return
            // The window's own offset (none for home: full screen) - regions are in the window surface's space.
            val at = IntArray(2).also(view::getLocationInWindow)
            val holes = holes()
            val shown =
                regions
                    .filter { r -> holes.none { h -> RectF.intersects(h, RectF(r.l, r.t, r.r, r.b)) } }
                    .map { r -> c!!.encode(r.moved(at[0].toFloat(), at[1].toFloat())) }
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
                                runCatching { root.applyTransactionOnDraw(t) }.onFailure(::fail)
                                view.invalidate()
                            }
                        }
                    Choreographer.getInstance().postFrameCallback(cb)
                }
            }
        } catch (e: Throwable) {
            fail(e)
        }
    }

    private fun fail(e: Throwable) {
        Log.w(TAG, "blur regions failed: the page goes back to its own glass", e)
        broken = true
        regions = emptyList()
        update()
    }

    /** A region in the window's pixels: its box, corners, how much of the blur shows, the blur's radius. */
    private class Region(
        val l: Float,
        val t: Float,
        val r: Float,
        val b: Float,
        val tl: Float,
        val tr: Float,
        val br: Float,
        val bl: Float,
        val alpha: Float,
        val radius: Float,
    ) {
        fun moved(
            dx: Float,
            dy: Float,
        ) = if (dx == 0f && dy == 0f) this else Region(l + dx, t + dy, r + dx, b + dy, tl, tr, br, bl, alpha, radius)
    }

    /**
     * The framework's own encoding of a blur region: one BackgroundBlurDrawable of the window (never drawn, so never
     * in the window's own blur aggregate), set to each region in turn, and BlurRegion(drawable).toFloatArray().
     */
    private class Codec(
        m: Methods,
        viewRoot: Any,
    ) {
        private val drawable: Any = m.createDrawable.invoke(viewRoot) ?: error("no blur drawable")
        private val cls = drawable.javaClass
        private val setRadius = cls.getMethod("setBlurRadius", Int::class.javaPrimitiveType)
        private val setCorners = cls.getMethod("setCornerRadius", Float::class.javaPrimitiveType, Float::class.javaPrimitiveType, Float::class.javaPrimitiveType, Float::class.javaPrimitiveType)
        private val setAlpha = cls.getMethod("setAlpha", Int::class.javaPrimitiveType)
        private val rect = cls.getDeclaredField("mRect").apply { isAccessible = true }.get(drawable) as android.graphics.Rect
        private val region = Class.forName("${cls.name}\$BlurRegion")
        private val newRegion = region.getDeclaredConstructor(cls).apply { isAccessible = true }
        private val toFloatArray = region.getDeclaredMethod("toFloatArray").apply { isAccessible = true }

        fun encode(r: Region): FloatArray {
            setRadius.invoke(drawable, r.radius.toInt())
            // The framework's order: top-left, top-right, bottom-left, bottom-right.
            setCorners.invoke(drawable, r.tl, r.tr, r.bl, r.br)
            setAlpha.invoke(drawable, (r.alpha.coerceIn(0f, 1f) * 255).toInt())
            rect.set(r.l.toInt(), r.t.toInt(), kotlin.math.ceil(r.r).toInt(), kotlin.math.ceil(r.b).toInt())
            return toFloatArray.invoke(newRegion.newInstance(drawable)) as FloatArray
        }
    }

    private class Methods(
        val viewRoot: java.lang.reflect.Method,
        val surface: java.lang.reflect.Method,
        val createDrawable: java.lang.reflect.Method,
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
                    viewRoot.returnType.getMethod("createBackgroundBlurDrawable"),
                    SurfaceControl.Transaction::class.java.getMethod("setBlurRegions", SurfaceControl::class.java, Array<FloatArray>::class.java),
                )
            }.onFailure { Log.w(TAG, "no blur regions on this Android", it) }.getOrNull()
        }
    }
}
