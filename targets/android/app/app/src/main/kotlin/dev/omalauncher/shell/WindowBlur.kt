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
    private val maxRadiusDp: Float = 28f,
) {
    constructor(window: Window, maxRadiusDp: Float = 28f) : this({ window.decorView }, maxRadiusDp)

    private var radius = -1
    private var broken = false

    fun set(amount: Float) {
        if (broken) return
        val v = view() ?: return
        val r = (amount.coerceIn(0f, 1f) * maxRadiusDp * v.resources.displayMetrics.density).toInt()
        if (r == radius) return
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

    private companion object {
        val setBlur: java.lang.reflect.Method by lazy {
            SurfaceControl.Transaction::class.java.getMethod("setBackgroundBlurRadius", SurfaceControl::class.java, Int::class.javaPrimitiveType)
        }
    }
}
