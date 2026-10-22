package dev.omalauncher.shell

import android.util.Log
import android.view.SurfaceControl
import android.view.View
import android.view.Window
import dev.omalauncher.system.HiddenApi

/**
 * What's behind a window (the wallpaper, under home's transparent page) blurred by [set] (0..1 of [maxRadiusDp]), as
 * Quickstep's DepthController blurs it under its overview: the window's own surface's background blur radius, set
 * on the frame it's asked for. Cheap per frame (one transaction), so a swipe can drive it.
 *
 * HACK: ViewRootImpl.getSurfaceControl and Transaction.setBackgroundBlurRadius are hidden (they're what Quickstep
 * calls); reflected past the checks ([HiddenApi]), and nothing happens where they aren't there. Real fix: none for an
 * app - the public Window.setBackgroundBlurRadius only blurs behind a window's own background drawable, and changing
 * it relayouts the window (not per frame).
 */
internal class WindowBlur(
    /** A view of the window (its root): the window's surface is its view root's. */
    private val view: () -> View?,
    private var maxRadiusDp: Float = MAX_RADIUS_DP,
    /** The window's page glass (home's GlassBlur.wholeWindow), which keeps its surfaces' regions beside this one. */
    private val glass: ((Float) -> Boolean)? = null,
    /** The window's corners' radii, dp (top left, top right, bottom right, bottom left): square by default. */
    private val cornersDp: FloatArray = FloatArray(4),
) {
    constructor(window: Window, maxRadiusDp: Float = MAX_RADIUS_DP, glass: ((Float) -> Boolean)? = null) : this({ window.decorView }, maxRadiusDp, glass)

    private var radius = -1
    private var broken = false

    /** Frames waited for the window to be ready. */
    private var retries = 0

    /** The openness last set (0..1): applied again when the radius changes. */
    private var amount = 0f

    /**
     * The radius at full openness, dp - the page's to tune (its material: "shade.blur"), 0..[MAX_TUNED_DP]; the
     * current openness again at the new radius.
     */
    fun radius(dp: Float) {
        val d = dp.coerceIn(0f, MAX_TUNED_DP)
        if (d == maxRadiusDp) return
        maxRadiusDp = d
        radius = -1
        set(amount)
    }

    fun set(amount: Float) {
        this.amount = amount
        if (broken) return
        val v = view() ?: return
        // Android's own switch (battery saver, the developer option): no blur while it says so - never forced.
        val allowed =
            android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S ||
                runCatching { v.context.getSystemService(android.view.WindowManager::class.java).isCrossWindowBlurEnabled }.getOrDefault(true)
        val r = if (allowed) (amount.coerceIn(0f, 1f) * maxRadiusDp * v.resources.displayMetrics.density).toInt() else 0
        if (r == radius) return
        // A blur region over the window: the way this compositor blurs (the background
        // blur radius left home's widgets sharp under the shade, 2026-10-21). The page's own glass, on home, merges it.
        val handled: Boolean? =
            runCatching {
                glass?.invoke(r.toFloat())
                    ?: if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) GlassBlur.wholeWindowOf(v, r.toFloat(), FloatArray(4) { cornersDp[it] * v.resources.displayMetrics.density }) else false
            }.getOrDefault(false)
        if (handled == null) {
            // The window isn't ready (just shown: no surface, not laid out): again on its next frame, not cached -
            // the shade opened by a tap got no blur at all (2026-10-22).
            if (retries++ < 30) v.postOnAnimation { set(this.amount) }
            return
        }
        retries = 0
        if (handled) {
            radius = r
            return
        }
        runCatching {
            HiddenApi.allow()
            val root = View::class.java.getMethod("getViewRootImpl").invoke(v) ?: return
            val surface = root.javaClass.getMethod("getSurfaceControl").invoke(root) as SurfaceControl
            if (!surface.isValid) return
            val t = SurfaceControl.Transaction()
            setBlur.invoke(t, surface, r)
            t.apply()
            radius = r
        }.onFailure {
            Log.w("PowosBlur", "no blur behind the window", it)
            broken = true
        }
    }

    companion object {
        /**
         * The compositor's radius at full openness, dp: the same as home's glass (theme.css --glass-blur-native,
         * 140). Its blur is only ~0.15-0.3 of the radius it's given (measured on the phone, 2026-10-21): at the old
         * 28 dp, home's widgets under the shade stayed readable - "sharp straight through".
         */
        const val MAX_RADIUS_DP = 140f

        /** The most a page may ask for (the compositor blurs only a fraction of its radius: text needs a lot). */
        const val MAX_TUNED_DP = 600f

        private val setBlur: java.lang.reflect.Method by lazy {
            SurfaceControl.Transaction::class.java.getMethod("setBackgroundBlurRadius", SurfaceControl::class.java, Int::class.javaPrimitiveType)
        }
    }
}
