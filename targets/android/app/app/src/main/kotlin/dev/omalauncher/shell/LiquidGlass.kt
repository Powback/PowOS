package dev.omalauncher.shell

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import androidx.annotation.RequiresApi
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Liquid glass: the rim of each glass surface on home bends what's behind it, as a lens's edge does - the wallpaper
 * pulled in towards the surface's edge, its colours split a little (dispersion) - with a bright specular line along the
 * shape, lit from the top left. One AGSL shader (RuntimeShader), drawn by a plain view under the transparent WebView,
 * only over a band along each surface's edge; the inside stays clear, so the compositor's live blur ([GlassBlur]'s
 * regions) shows there, and the band fades into it.
 *
 * What it bends is the wallpaper's picture ([ShellWallpaper]: the still one, or OxygenOS's screenshot of a live one) -
 * the backdrop of home's window, which an app can't read live. Blurred once, two ways (lightly for the very edge, as
 * hard as the compositor's for where the band meets the inside), off the main thread when the picture changes.
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

    private val main = Handler(Looper.getMainLooper())
    private var rims: List<Rim> = emptyList()
    private var look = Look(0f, 0f, 0f, 0f)
    private val shader = RuntimeShader(AGSL)
    private val paint = Paint().apply { shader = this@LiquidGlass.shader }

    /** The two blurred copies of the wallpaper, as made for [madeFor] (picture bytes, view size). */
    private var light: Bitmap? = null
    private var heavy: Bitmap? = null
    private var madeFor = ""

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

    /** The wallpaper's picture (JPEG bytes, a revision): blurred for this view's size off the main thread. */
    fun picture(
        rev: String,
        jpeg: ByteArray?,
    ) {
        val w = width
        val h = height
        if (jpeg == null || w <= 0 || h <= 0) return
        val key = "$rev|${w}x$h"
        if (key == madeFor) return
        madeFor = key
        worker.execute {
            val made =
                runCatching {
                    val src = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: error("not a picture")
                    // The picture as the screen shows it: centered, covering it (what CSS glass did), at 1/4 and 1/24.
                    val a = cover(src, w / 4, h / 4).also { boxBlur(it, 1, 2) }
                    val b = cover(src, w / 24, h / 24).also { boxBlur(it, 2, 3) }
                    src.recycle()
                    a to b
                }.onFailure { Log.w(TAG, "no picture to bend", it) }.getOrNull() ?: return@execute
            main.post {
                if (madeFor != key) return@post
                light = made.first
                heavy = made.second
                shader.setInputShader("light", scaled(made.first, w, h))
                shader.setInputShader("heavy", scaled(made.second, w, h))
                invalidate()
            }
        }
    }

    override fun onSizeChanged(
        w: Int,
        h: Int,
        oldw: Int,
        oldh: Int,
    ) {
        // Another screen (fold, unfold): the copies again for its size.
        madeFor = ""
        light = null
        heavy = null
        onResize?.invoke()
    }

    /** Asked again for the picture (a new size). */
    var onResize: (() -> Unit)? = null

    /** The shader failed once (a driver that won't take it): never drawn again - the plain blur stays. */
    private var broken = false

    override fun onDraw(canvas: Canvas) {
        if (broken || look.off || light == null || heavy == null || rims.isEmpty()) return
        try {
            draw(canvas)
        } catch (e: RuntimeException) {
            Log.w(TAG, "liquid glass failed: the plain blur stays", e)
            broken = true
        }
    }

    private fun draw(canvas: Canvas) {
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
        private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "liquid-glass").apply { isDaemon = true } }

        /** [src] scaled to cover w x h (centered), as a w x h bitmap. */
        private fun cover(
            src: Bitmap,
            w: Int,
            h: Int,
        ): Bitmap {
            val ww = w.coerceAtLeast(1)
            val hh = h.coerceAtLeast(1)
            val out = Bitmap.createBitmap(ww, hh, Bitmap.Config.ARGB_8888)
            val s = max(ww.toFloat() / src.width, hh.toFloat() / src.height)
            val m = Matrix().apply {
                setScale(s, s)
                postTranslate((ww - src.width * s) / 2, (hh - src.height * s) / 2)
            }
            Canvas(out).drawBitmap(src, m, Paint(Paint.FILTER_BITMAP_FLAG))
            return out
        }

        /** In place: [passes] box blurs of [radius] px each way (three of them come close to a Gaussian). */
        private fun boxBlur(
            b: Bitmap,
            radius: Int,
            passes: Int,
        ) {
            val w = b.width
            val h = b.height
            val px = IntArray(w * h).also { b.getPixels(it, 0, w, 0, 0, w, h) }
            val tmp = IntArray(w * h)
            repeat(passes) {
                blur1(px, tmp, w, h, radius, true)
                blur1(tmp, px, w, h, radius, false)
            }
            b.setPixels(px, 0, w, 0, 0, w, h)
        }

        private fun blur1(
            src: IntArray,
            dst: IntArray,
            w: Int,
            h: Int,
            r: Int,
            horizontal: Boolean,
        ) {
            val n = if (horizontal) w else h
            val lines = if (horizontal) h else w
            for (line in 0 until lines) {
                for (i in 0 until n) {
                    var a = 0
                    var rr = 0
                    var g = 0
                    var bb = 0
                    for (k in -r..r) {
                        val j = (i + k).coerceIn(0, n - 1)
                        val c = if (horizontal) src[line * w + j] else src[j * w + line]
                        a += c ushr 24
                        rr += (c shr 16) and 0xff
                        g += (c shr 8) and 0xff
                        bb += c and 0xff
                    }
                    val d = 2 * r + 1
                    val out = ((a / d) shl 24) or ((rr / d) shl 16) or ((g / d) shl 8) or (bb / d)
                    if (horizontal) dst[line * w + i] = out else dst[i * w + line] = out
                }
            }
        }

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
