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
    /** To the page: "b.state 1|0" (the compositor blurs for it now), "b.backdrop live". */
    private val state: (String) -> Unit,
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

    /** Liquid glass on top ([LiquidGlass]): the style's switch, the theme's look, the view (made when first needed). */
    private var liquidAllowed = true
    private var look = LiquidGlass.Look(0f, 0f, 0f, 0f)
    private var liquid: LiquidGlass? = null
    /** The wallpaper live, for the liquid layer to bend: made with it. */
    private var backdrop: WallpaperBackdrop? = null

    /** Android's wallpaper changed: what's behind home is something else - captured again. */
    private val pictureChanged: () -> Unit = { if (liquidOn) backdrop?.burst() }

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

    fun allowLiquid(on: Boolean) =
        main.post {
            liquidAllowed = on
            if (on && regions.isNotEmpty()) set(regions, -1) else liquid?.set(emptyList())
        }

    /** "b.liquid <dpr> <band> <refraction> <rim> <dispersion>" (CSS px; rim and dispersion as they are). */
    fun liquidCommand(rest: String) {
        val t = rest.trim().split(' ').map { it.toFloat() }
        val l = LiquidGlass.Look(t[1] * t[0], t[2] * t[0], t[3], t[4])
        main.post {
            look = l
            liquid?.look(l)
            // On again: the wallpaper may have changed while it was off.
            if (liquidOn) backdrop?.burst()
            if (regions.isNotEmpty()) set(regions, -1)
        }
    }

    private val liquidOn get() = liquidAllowed && !look.off

    /** The liquid layer: under the page, the page's size, made the first time it's wanted. */
    private fun liquidView(): LiquidGlass? {
        liquid?.let { return it }
        val parent = view.parent as? android.view.ViewGroup ?: return null
        // Its shader is compiled here: a driver that won't take it leaves the plain blur, never the app down.
        val l =
            try {
                LiquidGlass(view.context)
            } catch (e: RuntimeException) {
                Log.w(TAG, "no liquid glass here", e)
                liquidAllowed = false
                return null
            }
        parent.addView(l, parent.indexOfChild(view), android.view.ViewGroup.LayoutParams(android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT))
        l.look(look)
        val b =
            WallpaperBackdrop(
                display = { view.display?.displayId ?: 0 },
                window = { methods?.let { m -> runCatching { m.viewRoot.invoke(view)?.let { m.surface.invoke(it) as SurfaceControl? } }.getOrNull() } },
                size = { android.graphics.Rect(0, 0, view.rootView.width.coerceAtLeast(1), view.rootView.height.coerceAtLeast(1)) },
                frame = { sharp, soft -> l.frame(sharp, soft) },
                // No live wallpaper to bend: no liquid glass (never a stale picture of it) - the plain blur stays.
                failed = {
                    liquidAllowed = false
                    l.set(emptyList())
                },
            )
        // Only while liquid edges are on: off (the style, the theme, the page), nothing is captured at all.
        l.onShown = { if (liquidOn) b.burst() }
        ShellWallpaper.onChange.add(pictureChanged)
        liquid = l
        backdrop = b
        b.burst()
        return l
    }

    /** The page asked (again, on its reload): tell it. */
    fun hello() =
        main.post {
            told = null
            update()
            // This host bends the live wallpaper (WallpaperBackdrop), never a stale picture of it: the page may ask
            // for liquid edges.
            state("b.backdrop live")
        }

    private fun update() {
        if (checked == null && !broken) check()
        val now = on
        if (!now && regions.isNotEmpty()) set(emptyList(), -1)
        if (told == now) return
        told = now
        state("b.state ${if (now) 1 else 0}")
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
                val ok = valid(c)
                if (ok) codec = c
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

    /** The window's own surface (home's: left out of WallpaperBackdrop's display captures). */
    fun windowSurface(): SurfaceControl? = methods?.let { m -> runCatching { m.viewRoot.invoke(view)?.let { m.surface.invoke(it) as SurfaceControl? } }.getOrNull() }

    /** The whole window's blur (the switcher's depth over home), px; added to the surfaces' regions. */
    private var whole = 0f

    /**
     * What's behind the whole window blurred by [radiusPx] (0: none), as a blur region over the window beside the
     * surfaces' own - the blur this compositor draws for PowOS (blur regions; the shade's background blur radius showed home
     * sharp, 2026-10-21). False where blur regions can't be used here: the caller's fallback then.
     */
    fun wholeWindow(radiusPx: Float): Boolean {
        if (checked == null && !broken) check()
        if (broken || checked != true) return false
        // The guard: home's whole window is blurred only while the switcher is up (its depth) - never left on over home
        // by a lost settle or a stale animation ("home wallpaper randomly fully blurred", 2026-10-21).
        val r = if (radiusPx >= 1f && !dev.omalauncher.system.Switcher.open) 0f.also {
            Log.w(TAG, "whole-window blur ${radiusPx.toInt()} px refused: the switcher isn't up")
        } else radiusPx
        if (whole == r) return true
        whole = r
        set(regions, -1)
        return true
    }

    /** A surface tile came or went: the regions again without what's over it. */
    fun holesChanged() = main.post { if (on && regions.isNotEmpty()) set(regions, -1) }

    fun close() {
        ShellWallpaper.onChange.remove(pictureChanged)
        backdrop?.close()
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
            if ((regions.isNotEmpty() || whole >= 1f) && c == null) return
            // The window's own offset (none for home: full screen) - regions are in the window surface's space.
            val at = IntArray(2).also(view::getLocationInWindow)
            val holes = holes()
            val shown =
                regions
                    .filter { r -> holes.none { h -> RectF.intersects(h, RectF(r.l, r.t, r.r, r.b)) } }
                    .map { r -> c!!.encode(r.moved(at[0].toFloat(), at[1].toFloat())) }
                    .let { list ->
                        if (whole < 1f) list else listOf(c!!.encode(Region(0f, 0f, view.rootView.width.toFloat(), view.rootView.height.toFloat(), 0f, 0f, 0f, 0f, 1f, whole))) + list
                    }.toTypedArray()
            // The liquid rims, drawn by a view in this window: on the same frame as the blur's transaction.
            val kept = regions.filter { r -> holes.none { h -> RectF.intersects(h, RectF(r.l, r.t, r.r, r.b)) } }
            // Not over the system bars: the backdrop may be the display's capture (WallpaperBackdrop DISPLAY), the bars
            // in it - a rim there would bend the status icons or the gesture bar into the glass.
            val bars = view.rootWindowInsets?.getInsets(android.view.WindowInsets.Type.systemBars())
            val top = (bars?.top ?: 0).toFloat()
            val bottom = view.height - (bars?.bottom ?: 0).toFloat()
            val rims = if (backdrop?.barsInFrames == true) kept.filter { it.t >= top && it.b <= bottom + 0.5f } else kept
            if (liquidOn && rims.isNotEmpty()) {
                liquidView()?.set(rims.map { LiquidGlass.Rim(it.l, it.t, it.r, it.b, it.tl, it.tr, it.br, it.bl, it.alpha) })
            } else {
                liquid?.set(emptyList())
            }
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
    /**
     * The framework's own encoding of a blur region: one BackgroundBlurDrawable of the window, its fields set to each
     * region in turn - written directly, never through its setters: a setter tells the window's own blur aggregator,
     * which then sends the drawable as a region of the window's every frame (seen 2026-10-22: the test region on the
     * pull-up panel's layer, and the shade's whole-window region overwritten - no blur under it) - and
     * BlurRegion(drawable).toFloatArray().
     */
    private class Codec(
        m: Methods,
        viewRoot: Any,
    ) {
        private val drawable: Any = m.createDrawable.invoke(viewRoot) ?: error("no blur drawable")
        private val cls = drawable.javaClass
        private fun field(name: String) = cls.getDeclaredField(name).apply { isAccessible = true }
        private val radius = field("mBlurRadius")
        private val alpha = field("mAlpha")
        private val tl = field("mCornerRadiusTL")
        private val tr = field("mCornerRadiusTR")
        private val bl = field("mCornerRadiusBL")
        private val br = field("mCornerRadiusBR")
        private val rect = field("mRect").get(drawable) as android.graphics.Rect
        private val region = Class.forName("${cls.name}\$BlurRegion")
        private val newRegion = region.getDeclaredConstructor(cls).apply { isAccessible = true }
        private val toFloatArray = region.getDeclaredMethod("toFloatArray").apply { isAccessible = true }

        init {
            // Never one of the window's own drawn blur drawables, whatever touches it.
            runCatching { field("mVisible").setBoolean(drawable, false) }
        }

        fun encode(r: Region): FloatArray {
            radius.setInt(drawable, r.radius.toInt())
            alpha.setFloat(drawable, r.alpha.coerceIn(0f, 1f))
            tl.setFloat(drawable, r.tl)
            tr.setFloat(drawable, r.tr)
            bl.setFloat(drawable, r.bl)
            br.setFloat(drawable, r.br)
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

        /** A test region must come back with its values where AOSP's layout has them (the OEM's extras after them). */
        private fun valid(c: Codec): Boolean {
            val a = c.encode(Region(10f, 20f, 110f, 220f, 1f, 2f, 3f, 4f, 0.5f, 30f))
            val ok =
                a.size >= 10 && a[0] == 30f && kotlin.math.abs(a[1] - 0.5f) < 0.01f && a[2] == 10f && a[3] == 20f &&
                    a[4] == 110f && a[5] == 220f && a[6] == 1f && a[7] == 2f && a[8] == 4f && a[9] == 3f
            Log.i(TAG, "blur regions ${if (ok) "usable" else "NOT usable"}: ${a.size} floats per region (${a.take(10)})")
            return ok
        }

        /** Checked encoders of windows without a page glass of their own (the shade's, the switcher activity's). */
        private val windowCodecs = java.util.WeakHashMap<Any, Codec>()
        private val badWindows = java.util.Collections.newSetFromMap(java.util.WeakHashMap<Any, Boolean>())

        /**
         * [view]'s whole window: what's behind it blurred by [radiusPx] (0: none), as one blur region (WindowBlur's
         * way where it works). False: blur regions can't be used here.
         */
        fun wholeWindowOf(
            view: View,
            radiusPx: Float,
        ): Boolean? {
            val m = methods ?: return false
            return try {
                // Not in its window yet, its surface not made, not laid out (a window just shown): null - again later.
                val viewRoot = m.viewRoot.invoke(view) ?: return null
                if (viewRoot in badWindows) return false
                val surface = m.surface.invoke(viewRoot) as SurfaceControl? ?: return null
                if (!surface.isValid || view.rootView.width <= 0 || view.rootView.height <= 0) return null
                val c =
                    windowCodecs[viewRoot] ?: Codec(m, viewRoot).takeIf(::valid)?.also { windowCodecs[viewRoot] = it } ?: run {
                        badWindows.add(viewRoot)
                        return false
                    }
                val r = view.rootView
                val regions = if (radiusPx < 1f) emptyArray() else arrayOf(c.encode(Region(0f, 0f, r.width.toFloat(), r.height.toFloat(), 0f, 0f, 0f, 0f, 1f, radiusPx)))
                val t = SurfaceControl.Transaction()
                m.setBlurRegions.invoke(t, surface, regions)
                t.apply()
                true
            } catch (e: Throwable) {
                Log.w(TAG, "no blur region over the window", e)
                false
            }
        }

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
