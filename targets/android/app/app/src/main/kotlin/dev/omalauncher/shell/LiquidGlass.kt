package dev.omalauncher.shell

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import android.util.Log
import android.view.View
import androidx.annotation.RequiresApi

/**
 * Liquid glass: the rim of each glass surface on home bends what's behind it, as a lens's edge does - the wallpaper
 * pulled in towards the surface's edge, its colours split a little (dispersion) - with a bright specular line along the
 * shape, lit from the top left. One AGSL shader (RuntimeShader), drawn by a plain view under the transparent WebView,
 * only over a band along each surface's edge; the inside stays clear, so the compositor's live blur ([GlassBlur]'s
 * regions) shows there, and the band fades into it.
 *
 * What it bends is the wallpaper as it is on screen, live ([WallpaperBackdrop]: the compositor's capture of a mirror of
 * the wallpaper's own surface - a still picture, or OxygenOS's video wallpaper at the frame it shows), two ways: a
 * quarter-size copy for the very edge, a tiny one (as soft as the compositor's blur) where the band meets the inside.
 *
 * Driven by the same rectangles as the blur, on the same frame: [set] invalidates this view, which draws in the frame
 * the blur's transaction rides on. Nothing is drawn while nothing moves (a view isn't drawn again unless invalidated).
 * Tuned by the theme (theme.css --liquid-*: band, refraction, rim, dispersion; the page sends them, "b.liquid"), off
 * with Style glass.liquid or a refraction and rim of 0.
 */
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
internal class LiquidGlass(
    context: Context,
) : View(context) {
    /** A surface, in this view's pixels. */
    class Rim(
        val l: Float,
        val t: Float,
        val r: Float,
        val b: Float,
        val tl: Float,
        val tr: Float,
        val br: Float,
        val bl: Float,
        val alpha: Float,
    )

    /** In px: how wide the bent band is, how far the edge pulls the picture; rim: the line's brightness; dispersion. */
    class Look(
        val band: Float,
        val refraction: Float,
        val rim: Float,
        val dispersion: Float,
    ) {
        val off get() = band <= 0f || (refraction <= 0f && rim <= 0f)
    }

    private var rims: List<Rim> = emptyList()
    private var look = Look(0f, 0f, 0f, 0f)
    private val shader = RuntimeShader(AGSL)
    private val paint = Paint().apply { shader = this@LiquidGlass.shader }

    /** The wallpaper as it is now, two ways (the edge's sharper copy, the inside's soft one). */
    private var light: Bitmap? = null
    private var heavy: Bitmap? = null

    init {
        setWillNotDraw(false)
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun set(rims: List<Rim>) {
        if (rims.isEmpty() && this.rims.isEmpty()) return
        this.rims = rims
        invalidate()
    }

    fun look(look: Look) {
        this.look = look
        invalidate()
    }

    /** A live frame of the wallpaper ([WallpaperBackdrop]): bent from now on, stretched over this view. */
    fun frame(
        sharp: Bitmap,
        soft: Bitmap,
    ) {
        val w = width
        val h = height
        if (w <= 0 || h <= 0) return
        light = sharp
        heavy = soft
        shader.setInputShader("light", scaled(sharp, w, h))
        shader.setInputShader("heavy", scaled(soft, w, h))
        invalidate()
    }

    /** Home shown again, or another screen (an unlock, a fold): the wallpaper may have changed - [WallpaperBackdrop]. */
    var onShown: (() -> Unit)? = null

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility == VISIBLE) onShown?.invoke()
    }

    override fun onScreenStateChanged(screenState: Int) {
        super.onScreenStateChanged(screenState)
        if (screenState == SCREEN_STATE_ON) onShown?.invoke()
    }

    override fun onSizeChanged(
        w: Int,
        h: Int,
        oldw: Int,
        oldh: Int,
    ) {
        onShown?.invoke()
    }

    /** The shader failed once (a driver that won't take it): never drawn again - the plain blur stays. */
    private var broken = false

    override fun onDraw(canvas: Canvas) {
        if (broken || look.off || light == null || heavy == null || rims.isEmpty()) return
        try {
            drawRims(canvas)
        } catch (e: RuntimeException) {
            Log.w(TAG, "liquid glass failed: the plain blur stays", e)
            broken = true
        }
    }

    private fun drawRims(canvas: Canvas) {
        val band = look.band
        shader.setFloatUniform("look", band, look.refraction, look.rim, look.dispersion)
        for (r in rims) {
            if (r.alpha < 0.01f) continue
            shader.setFloatUniform("box", r.l, r.t, r.r, r.b)
            shader.setFloatUniform("radii", r.tl, r.tr, r.br, r.bl)
            shader.setFloatUniform("alpha", r.alpha)
            // Only the band along the edge: four strips (the shader shapes the corners), not the whole surface.
            val bw = minOf(band, (r.r - r.l) / 2, (r.b - r.t) / 2)
            canvas.drawRect(r.l, r.t, r.r, r.t + bw, paint)
            canvas.drawRect(r.l, r.b - bw, r.r, r.b, paint)
            canvas.drawRect(r.l, r.t + bw, r.l + bw, r.b - bw, paint)
            canvas.drawRect(r.r - bw, r.t + bw, r.r, r.b - bw, paint)
        }
    }

    companion object {
        private const val TAG = "PowosLiquidGlass"

        /** [b] stretched over w x h, smoothly. */
        private fun scaled(
            b: Bitmap,
            w: Int,
            h: Int,
        ): Shader =
            BitmapShader(b, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply {
                filterMode = BitmapShader.FILTER_MODE_LINEAR
                setLocalMatrix(Matrix().apply { setScale(w.toFloat() / b.width, h.toFloat() / b.height) })
            }

        /**
         * Per pixel of the band: the rounded box's signed distance (negative inside), its normal; the picture sampled
         * pulled inwards by more the nearer the edge (a convex lens's rim), red and blue a little apart; lightly
         * blurred at the edge, as blurred as the inside further in; a thin bright line along the edge, brightest where
         * it faces the light (top left); faded out towards the inside, where the compositor's blur shows.
         */
        private const val AGSL = """
uniform shader light;
uniform shader heavy;
uniform float4 box;    // l, t, r, b
uniform float4 radii;  // tl, tr, br, bl
uniform float4 look;   // band, refraction, rim, dispersion
uniform float alpha;

float sdBox(float2 p) {
    float2 c = (box.xy + box.zw) * 0.5;
    float2 h = (box.zw - box.xy) * 0.5;
    float2 q = p - c;
    float r = q.x < 0.0 ? (q.y < 0.0 ? radii.x : radii.w) : (q.y < 0.0 ? radii.y : radii.z);
    r = min(r, min(h.x, h.y));
    float2 d = abs(q) - h + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

half4 main(float2 p) {
    float d = sdBox(p);
    if (d > 0.5) return half4(0.0);
    float band = look.x;
    float depth = clamp(-d / band, 0.0, 1.0);
    float2 n = normalize(float2(sdBox(p + float2(1.0, 0.0)) - sdBox(p - float2(1.0, 0.0)),
                                sdBox(p + float2(0.0, 1.0)) - sdBox(p - float2(0.0, 1.0))) + 1e-5);
    float k = (1.0 - depth);
    k = k * k;
    float2 off = -n * k * look.y;
    float s = look.w;
    half3 sharp = half3(light.eval(p + off * (1.0 + s)).r, light.eval(p + off).g, light.eval(p + off * (1.0 - s)).b);
    half3 soft = half3(heavy.eval(p + off * (1.0 + s)).r, heavy.eval(p + off).g, heavy.eval(p + off * (1.0 - s)).b);
    half3 col = mix(sharp, soft, half(smoothstep(0.0, 0.85, depth)));
    float facing = clamp(dot(n, normalize(float2(-0.55, -0.85))), 0.0, 1.0);
    float line = exp(-max(-d, 0.0) / 1.6);
    float glow = exp(-max(-d, 0.0) / (band * 0.35)) * 0.25;
    col += half(look.z * (line + glow) * (0.35 + 0.65 * facing * facing));
    float a = (1.0 - smoothstep(0.55, 1.0, depth)) * (1.0 - smoothstep(-0.5, 0.5, d)) * alpha;
    return half4(col * half(a), half(a));
}
"""
    }
}
