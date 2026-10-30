package dev.omalauncher.shell

import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Trace
import android.provider.Settings
import android.util.Log
import android.view.Choreographer
import android.view.SurfaceControl
import android.view.View
import android.view.WindowManager
import android.webkit.WebView
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

    /**
     * What the window's surface was last given (the encoded regions, the whole-window one included) and that surface's
     * generation: the same set again is no transaction and no draw. Each applied set invalidates the WebView, and a
     * WebView draw is a synchronous draw of the page on this (the UI) thread - an idle home must cost it nothing.
     * Forgotten whenever the window may have lost its regions (focus or window gone and back, a new surface, a reload,
     * the state said again), so the page's own resend after a resume (nativeglass.ts resend) still lands.
     */
    private var lastShown: Array<FloatArray>? = null
    private var lastUnder: Array<FloatArray>? = null

    /**
     * The glass of surfaces a web window overlaps (Region.under): a container layer on this window's surface BELOW
     * every child of it - under the web windows' root (WebWindows.root, layer -1) and home's own buffer - holding their
     * blur regions. SurfaceFlinger blurs what's drawn before a layer, so a region on home's surface blurred the windows
     * under home's buffer too (the app's pixels in the widget's glass); the page cut such regions around the window
     * and dropped them when the rest wasn't one rounded rect ("if they're above some of the widgets the widget stops
     * having like blur", 2026-10-30). Here they blur the wallpaper alone, whole, and the window's layer draws over
     * them: the uncovered part keeps its blur up to the window's edge, the covered part is simply under the window
     * (the page masks its tint there: .page-under). Surfaces above every window (the dock, menus) stay on the window's
     * surface and blur the app under them.
     */
    private var under: SurfaceControl? = null
    private var underGeneration = Int.MIN_VALUE
    private var lastGeneration = -1

    /** Each region's encoding, from the last set: a set where most surfaces stayed put encodes only the moved ones. */
    private var encoded = HashMap<Region, FloatArray>()

    /** The newest "b.r" received (port thread): an older one still queued on the main thread is skipped, not applied. */
    @Volatile private var latestR = 0L
    private var rSeq = 0L

    init {
        runCatching { windows.addCrossWindowBlurEnabledListener({ main.post(it) }, blurListener) }
        main.post { update() }
        view.viewTreeObserver.addOnWindowFocusChangeListener { forget() }
        view.viewTreeObserver.addOnWindowAttachListener(
            object : android.view.ViewTreeObserver.OnWindowAttachListener {
                override fun onWindowAttached() = forget()

                override fun onWindowDetached() = forget()
            },
        )
    }

    /** The next set goes to the window whatever it was given before. */
    private fun forget() {
        lastShown = null
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
        l.neverFocus()
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

    /**
     * Home's glass at rest ([RestGlass]): the compositor's blur rendered once and drawn under the page while nothing
     * moves, the window's blur regions off - home DEVICE-composited instead of GPU-composited every frame.
     */
    private var rest: RestGlass? = null

    /** The page is still ("b.rest 1") and wants the rest glass. */
    private var restWanted = false

    /** The rest glass is up and the window's surface has no blur regions of its own. */
    private var resting = false

    /**
     * "b.rest 1|0" (home's page, ui/nativeglass.ts): still - the live regions swapped for the rest glass once it's
     * rendered; moving - the live regions back on the window's next draw, the picture off on that same draw.
     */
    fun restCommand(arg: String) {
        val still = arg.trim() == "1"
        main.post { if (still) enterRest() else leaveRest() }
    }

    /** Whether the regions on the window now can go still: nothing over or under them but the wallpaper. */
    private fun restable(): Boolean =
        on && whole < 1f && regions.isNotEmpty() && regions.none { it.under } && !(liquidOn && liquid != null) && holes().isEmpty() &&
            rest?.dead != true &&
            runCatching { Settings.Global.getInt(view.context.contentResolver, "powos_glass_rest", 1) == 1 }.getOrDefault(true)

    private fun restGlass(): RestGlass? {
        rest?.let { return it }
        val m = methods ?: return null
        val parent = view.parent as? android.view.ViewGroup ?: return null
        val r = RestGlass(view.context) { t, sc, shown -> m.setBlurRegions.invoke(t, sc, shown) }
        // Under the page (and under the liquid layer, if any): the page's tint draws over it as over the live blur.
        parent.addView(r.view, parent.indexOfChild(view), android.view.ViewGroup.LayoutParams(android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT))
        rest = r
        return r
    }

    private fun enterRest() {
        restWanted = true
        if (resting || !restable()) return
        val shown = lastShown ?: return
        val r = restGlass() ?: return
        val regionsNow = regions
        r.render(view.display?.displayId ?: 0, Rect(0, 0, view.rootView.width.coerceAtLeast(1), view.rootView.height.coerceAtLeast(1)), shown) { pic ->
            // Moved (or changed) while it rendered: the live glass stays.
            if (stillAs(regionsNow, shown)) showRest(r, pic)
        }
    }

    /** Still wanted, and the window's regions still the ones rendered. */
    private fun stillAs(
        regionsNow: List<Region>,
        shown: Array<FloatArray>,
    ) = restWanted && !resting && regions === regionsNow && lastShown?.contentDeepEquals(shown) == true && restable()

    /** [pic] under the page and the window's live regions off, on one draw. */
    private fun showRest(
        r: RestGlass,
        pic: android.graphics.Bitmap,
    ) {
        val m = methods ?: return
        try {
            val root = view.rootSurfaceControl ?: return
            val surface = m.surface.invoke(m.viewRoot.invoke(view) ?: return) as SurfaceControl? ?: return
            if (!surface.isValid) return
            val at = IntArray(2).also(view::getLocationInWindow)
            // Each region's box, 2 px out: its rounded corners come with the picture (the wallpaper's own pixels past them).
            r.show(pic, regions.map { RectF(it.l + at[0] - 2f, it.t + at[1] - 2f, it.r + at[0] + 2f, it.b + at[1] + 2f) })
            // The live regions off on the draw that first shows the picture: both on for that frame look the same.
            val t = SurfaceControl.Transaction()
            m.setBlurRegions.invoke(t, surface, emptyArray<FloatArray>())
            root.applyTransactionOnDraw(t)
            resting = true
            Log.d(TAG, "at rest: ${regions.size} regions drawn still, none on the window")
        } catch (e: Throwable) {
            Log.w(TAG, "no rest glass", e)
            r.hide()
        }
    }

    /** A set while at rest (the page moving, a hole, the switcher's depth, a clear): live again, the picture off. */
    private fun dropRest(next: List<Region>) {
        if (!resting && !(restWanted && next != regions)) return
        restWanted = false
        rest?.cancel()
        if (!resting) return
        resting = false
        rest?.hide()
        forget()
    }

    /** Moving again (or anything else set on the window): the live regions back, the picture off - the same draw. */
    private fun leaveRest() {
        restWanted = false
        rest?.cancel()
        if (!resting) return
        resting = false
        rest?.hide()
        forget()
        set(regions, 0)
    }

    /** The page asked (again, on its reload): tell it. */
    fun hello() =
        main.post {
            told = null
            forget()
            update()
            // This host bends the live wallpaper (WallpaperBackdrop), never a stale picture of it: the page may ask
            // for liquid edges.
            state("b.backdrop live")
            // This host binds "b.f" regions to the draw showing their page frame: the page may send them. Only with
            // Settings.Global powos_glass_sync = 1 (default 0, the page then never sends "b.f" and keeps "b.r" as
            // before): it ships off until the coordinator turns it on on the phone for the device acceptance (a 60 fps
            // recording of a folder morph, a widget drag and a shade open with the blur exact), then flips the default.
            if (frameSyncOn()) state("b.sync 1")
        }

    private fun frameSyncOn() =
        runCatching { Settings.Global.getInt(view.context.contentResolver, "powos_glass_sync", 0) == 1 }.getOrDefault(false)

    private fun update() {
        if (checked == null && !broken) check()
        val now = on
        if (!now && regions.isNotEmpty()) set(emptyList(), -1)
        if (told == now) return
        forget()
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
     * "b.r <dpr> <n> [x y w h tl tr br bl alpha radius] * n [u <k>]" (CSS px of the page; radius: the blur's; the first
     * k under web windows, [under]), on the port's
     * thread: parsed there, set on the main thread on the window's next draw - not tied to the page frame it was
     * measured on (pages without "b.f", and the page's clear). Any frame-synced set still in flight is dropped.
     */
    fun command(rest: String) {
        val regions = parse(rest, "b.r") ?: return
        val lag = lag
        val seq = ++rSeq
        latestR = seq
        main.post {
            // A newer set is already queued behind this one (the UI thread was busy): only the newest goes on a draw.
            if (seq != latestR) return@post
            sync?.let { it.applied = maxOf(it.applied, it.received) }
            if (on) set(regions, lag)
        }
    }

    /** "b.r"'s and "b.f"'s regions, in the window's px; null (logged) when malformed. */
    private fun parse(
        rest: String,
        verb: String,
    ): List<Region>? =
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
            }.let { list -> markUnder(list, t, i) }
        } catch (e: RuntimeException) {
            Log.w(TAG, "$verb: bad regions ($e)")
            null
        }

    /** "u <k>" at [i] of [t] (after the regions): the first k of [list] are under web windows; a page from before sends none. */
    private fun markUnder(
        list: List<Region>,
        t: List<String>,
        i: Int,
    ): List<Region> {
        val k = if (t.getOrNull(i) == "u") t[i + 1].toInt() else 0
        return if (k == 0) list else list.mapIndexed { j, r -> if (j < k) r.under() else r }
    }

    /** "b.f"'s binding to the page's frames (newest received / applied): shared with the web windows' "w.f" ([FrameSync]). */
    private val sync = (view as? WebView)?.let { FrameSync(it, "glass") }

    /**
     * "b.f <id> <regions as b.r>": the regions the page measured for its frame <id>. They go on the window's draw
     * that first shows that page state: [WebView.postVisualStateCallback] fires once the WebView's next draw holds
     * the renderer's content as of now (frame <id> or later), and the regions ride that draw
     * ([android.view.AttachedSurfaceControl.applyTransactionOnDraw]). Before, they rode whichever draw came next,
     * racing the page's pixels by a frame either way (docs/NATIVE-GLASS.md). A callback older than one already
     * applied is dropped: only the newest set goes on. Trace: async section "glass f<id>", receipt to apply.
     */
    fun frameCommand(rest: String) {
        val s = rest.trimStart()
        val sp = s.indexOf(' ')
        val id: Long? = (if (sp > 0) s.substring(0, sp).toLongOrNull() else null) 
        if (id == null) {
            Log.w(TAG, "b.f: no frame id")
            return
        }
        val regions = parse(s.substring(sp + 1), "b.f") ?: return
        val cookie = sync?.receive(id) ?: id.toInt()
        val lag = lag
        main.post { bindToDraw(id, cookie, regions, lag) }
    }

    /** On the main thread: [regions] onto the window draw that shows page frame [id] (or the old path, see frameCommand). */
    private fun bindToDraw(
        id: Long,
        cookie: Int,
        regions: List<Region>,
        lag: Int,
    ) {
        val sync = sync
        // The lag knob is a test override; no WebView (never here today): the old next-draw path.
        if (!on || lag != 0 || sync == null) {
            Trace.endAsyncSection("glass f$id", cookie)
            if (on) set(regions, lag)
            return
        }
        sync.bind(id, cookie) { if (on) set(regions, 0) }
    }

    /** Another page (a reload): its regions are its own to set; until then none. */
    fun reset() = main.post {
        told = null
        forget()
        // Its frame ids start again at 1.
        sync?.reset()
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
        rest?.close()
        runCatching { windows.removeCrossWindowBlurEnabledListener(blurListener) }
        main.post {
            if (regions.isNotEmpty()) set(emptyList(), -1)
            under?.let { if (it.isValid) SurfaceControl.Transaction().reparent(it, null).apply() }
            under = null
        }
    }

    /** On the main thread. Any failure turns the live glass off - it never takes the app down with it. */
    private fun set(
        regions: List<Region>,
        lag: Int,
    ) {
        dropRest(regions)
        this.regions = regions
        // The whole window's blur goes with the switcher: any set (a page's regions, a new surface) after it closed
        // drops it - the guard in [wholeWindow] only refused new ones, nothing cleared the one already on, and home sat
        // full-screen blurred at 386 px, every layer under the shade GPU-composited (SurfaceFlinger dump, 2026-10-30).
        if (whole >= 1f && !dev.omalauncher.system.Switcher.open) {
            Log.w(TAG, "whole-window blur ${whole.toInt()} px dropped: the switcher isn't up")
            whole = 0f
        }
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
            val next = HashMap<Region, FloatArray>()
            val enc = { r: Region -> next.getOrPut(r) { encoded[r] ?: c!!.encode(r) } }
            val clear = regions.filter { r -> holes.none { h -> RectF.intersects(h, RectF(r.l, r.t, r.r, r.b)) } }
            val shownUnder = clear.filter { it.under }.map { r -> enc(r.moved(at[0].toFloat(), at[1].toFloat())) }.toTypedArray()
            val shown =
                clear
                    .filter { !it.under }
                    .map { r -> enc(r.moved(at[0].toFloat(), at[1].toFloat())) }
                    .let { list ->
                        if (whole < 1f) list else listOf(enc(Region(0f, 0f, view.rootView.width.toFloat(), view.rootView.height.toFloat(), 0f, 0f, 0f, 0f, 1f, whole))) + list
                    }.toTypedArray()
            encoded = next
            // The liquid rims, drawn by a view in this window: on the same frame as the blur's transaction. Not those
            // under windows: the rims draw in this window's buffer, over the windows.
            setRims(clear.filter { !it.under })
            // The same regions on the same surface: nothing to apply, no draw asked for (the page re-sending what it sent).
            val generation = generationOf(viewRoot)
            val prev = lastShown
            val prevUnder = lastUnder
            if (prev != null && prevUnder != null && generation == lastGeneration && lag <= 0 && prev.contentDeepEquals(shown) && prevUnder.contentDeepEquals(shownUnder)) return
            val t = SurfaceControl.Transaction()
            m.setBlurRegions.invoke(t, surface, shown)
            setUnder(t, surface, shownUnder, generation)
            lastShown = shown
            lastUnder = shownUnder
            lastGeneration = generation
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

    /** The liquid rims of [kept] (the regions on this window's surface), drawn by a view in this window. */
    private fun setRims(kept: List<Region>) {
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
    }

    /**
     * [shown] onto the [under] layer in [t]: hung on the window's [surface] again whenever WM gave it a new one (the
     * old one's children go with it), made the first time a region wants it.
     */
    private fun setUnder(
        t: SurfaceControl.Transaction,
        surface: SurfaceControl,
        shown: Array<FloatArray>,
        generation: Int,
    ) {
        val m = methods ?: return
        val u = under?.takeIf { it.isValid } ?: if (shown.isNotEmpty()) SurfaceControl.Builder().setName("powos-glass-under").build().also { under = it } else return
        if (generation != underGeneration || generation == -1 || lastShown == null) {
            t.reparent(u, surface).setLayer(u, UNDER_LAYER).setVisibility(u, true)
            underGeneration = generation
        }
        m.setBlurRegions.invoke(t, u, shown)
    }

    private fun fail(e: Throwable) {
        Log.w(TAG, "blur regions failed: the page goes back to its own glass", e)
        broken = true
        forget()
        regions = emptyList()
        update()
    }

    /**
     * The window's Surface's generation (Surface.getGenerationId: bumped each time WM gives the window a new surface,
     * which carries none of the old one's blur regions), or -1 where ViewRootImpl.mSurface can't be read.
     * HACK: ViewRootImpl.mSurface is hidden, reflected past the checks ([HiddenApi], as the calls above); without it
     * the window focus/attach listeners alone forget the last set. Real fix: the regions set from the platform side
     * (see the class's HACK).
     */
    private fun generationOf(viewRoot: Any): Int {
        if (surfaceField == null && !noSurfaceField) {
            surfaceField = runCatching { viewRoot.javaClass.getDeclaredField("mSurface").apply { isAccessible = true } }.getOrNull()
            noSurfaceField = surfaceField == null
        }
        val surface = runCatching { surfaceField?.get(viewRoot) }.getOrNull() ?: return -1
        // Surface.getGenerationId() is hidden too (not in the SDK stubs): reflected, like mSurface above.
        if (generationMethod == null && !noGenerationMethod) {
            generationMethod = runCatching { surface.javaClass.getMethod("getGenerationId") }.getOrNull()
            noGenerationMethod = generationMethod == null
        }
        return runCatching { generationMethod?.invoke(surface) as Int? }.getOrNull() ?: -1
    }

    private var generationMethod: java.lang.reflect.Method? = null
    private var noGenerationMethod = false

    private var surfaceField: java.lang.reflect.Field? = null
    private var noSurfaceField = false

    /**
     * A region in the window's pixels: its box, corners, how much of the blur shows, the blur's radius; [under]: a web
     * window above it overlaps it, so it's blurred on the [under] layer, below the windows, not on the window's surface.
     */
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
        var under = false
            private set

        fun moved(
            dx: Float,
            dy: Float,
        ) = if (dx == 0f && dy == 0f) this else Region(l + dx, t + dy, r + dx, b + dy, tl, tr, br, bl, alpha, radius).also { it.under = under }

        fun under() = Region(l, t, r, b, tl, tr, br, bl, alpha, radius).also { it.under = true }

        /** Its values, for [GlassBlur.encoded]'s key: a region equal to one encoded before reuses that encoding. */
        private val key get() = floatArrayOf(l, t, r, b, tl, tr, br, bl, alpha, radius)

        override fun equals(other: Any?) = other is Region && key.contentEquals(other.key)

        override fun hashCode() = key.contentHashCode()
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

        /** [under]'s z on the window's surface: below the web windows' root (-1) and anything else hung there. */
        private const val UNDER_LAYER = -(1 shl 20)

        /** [view]'s window surface (ViewRootImpl.getSurfaceControl: WM's surface of the window), valid, or null. */
        fun surfaceOf(view: View): SurfaceControl? =
            methods?.let { m -> runCatching { m.viewRoot.invoke(view)?.let { m.surface.invoke(it) as SurfaceControl? } }.getOrNull() }?.takeIf { it.isValid }

        /** A test region must come back with its values where AOSP's layout has them (the OEM's extras after them). */
        private fun valid(c: Codec): Boolean {
            val a = c.encode(Region(10f, 20f, 110f, 220f, 1f, 2f, 3f, 4f, 0.5f, 30f))
            val ok =
                a.size >= 10 && a[0] == 30f && kotlin.math.abs(a[1] - 0.5f) < 0.01f && a[2] == 10f && a[3] == 20f &&
                    a[4] == 110f && a[5] == 220f && a[6] == 1f && a[7] == 2f && a[8] == 4f && a[9] == 3f
            // The encoder retains its drawable. Leave it empty after probing: Android 16 can include it in a
            // later window aggregate despite mVisible=false (a 100x200 test rectangle beside a hidden grip).
            c.encode(Region(0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f))
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
            /** Its corners' radii, px (top left, top right, bottom right, bottom left): a rounded window's glass. */
            corners: FloatArray = FloatArray(4),
            /** Unblurred at its top, px (a window bar's touch strip above the glass). */
            topPx: Float = 0f,
        ): Boolean? {
            val m = methods ?: return false
            return try {
                // Not in its window yet, its surface not made, not laid out (a window just shown): null - again later.
                val viewRoot = m.viewRoot.invoke(view) ?: return null
                if (viewRoot in badWindows) return false
                val surface = m.surface.invoke(viewRoot) as SurfaceControl? ?: return null
                if (!surface.isValid || view.rootView.width <= 0 || view.rootView.height <= 0) return null
                val c = codecOf(m, viewRoot) ?: return false
                val root = view.rootView
                val regions = wholeRegion(c, android.graphics.RectF(0f, topPx, root.width.toFloat(), root.height.toFloat()), radiusPx, corners)
                val t = SurfaceControl.Transaction()
                m.setBlurRegions.invoke(t, surface, regions)
                applyWhole(view, t)
                true
            } catch (e: Throwable) {
                Log.w(TAG, "no blur region over the window", e)
                false
            }
        }

        /**
         * Set (main thread only) while a [wholeWindowOf] is for the frame its window's page draws now (WindowBlur.setOnDraw):
         * the regions ride on the window's next draw ([AttachedSurfaceControl.applyTransactionOnDraw]), not at once.
         */
        internal var onNextDraw = false

        private fun applyWhole(
            view: View,
            t: SurfaceControl.Transaction,
        ) {
            val attached = if (onNextDraw && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) view.rootSurfaceControl else null
            if (attached == null) return t.apply()
            attached.applyTransactionOnDraw(t)
            // A draw comes even when the page has nothing new (its last frame already drawn).
            view.invalidate()
        }

        /** The window's region codec, made once; null (and the window remembered as bad) where it can't be. */
        private fun codecOf(
            m: Methods,
            viewRoot: Any,
        ): Codec? =
            windowCodecs[viewRoot] ?: Codec(m, viewRoot).takeIf(::valid)?.also { windowCodecs[viewRoot] = it } ?: run {
                badWindows.add(viewRoot)
                null
            }

        /** One region over [r] of the window (all of it but a strip at its top, if any), its corners rounded; none at a radius under 1 px. */
        private fun wholeRegion(
            c: Codec,
            r: android.graphics.RectF,
            radiusPx: Float,
            corners: FloatArray,
        ): Array<FloatArray> =
            if (radiusPx < 1f) emptyArray() else arrayOf(c.encode(Region(r.left, r.top, r.right, r.bottom, corners[0], corners[1], corners[2], corners[3], 1f, radiusPx)))

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
