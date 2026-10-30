package dev.omalauncher.shell

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.drawable.Drawable
import android.util.Log
import android.view.Surface
import android.view.SurfaceControl

/**
 * A web window's own frame, drawn natively in its layer stack (docs/WEB_WINDOWS.md "Native frame"): the title bar
 * (icon, title, minimise, full screen/restore, close - the shell's window-control look, ui/chrome.tsx) above the app's
 * mirror, and a background under the mirror (shown where the app hasn't drawn yet: a resize before the app lays out).
 *
 * Why native: the user, 2026-10-30, "nobody asked for the cutoff" - the window sits on home like a card, so it can't be
 * home's DOM (DOM is under or over home's whole buffer, never one window's layer), and "its like its content is
 * lagging behind slightly even when I move windows": bar and content in one layer stack move in one transaction.
 *
 * Layers under the window's container: background (-1, an 8x8 buffer scaled over the body), the mirror (0, the
 * caller's), the bar (1, a buffer the width of the screen's long side, cropped by the container).
 *
 * The bar is home's widget glass (the user, 2026-10-30: "I feel like the title bar should have the same blur effect as
 * the widget"): the page sends its widget surface's own values with the theme ("w.theme": --glass-fill over
 * --glass-veil, the --line edge --frame wide, --glass-blur-native and --radius, device px), and the compositor blurs
 * what's under the bar by that radius ([blurBehind]) - the same material as a .tile, no values copied here. Without the
 * compositor's blur (battery saver) the tints go over the opaque surface colour, as the page's own fallback is solid.
 *
 * Maximised (filling the work area, under the status bar), the bar and the status bar are one bar (TB1-TB3): the
 * title is kept short and its row centred on the status bar's ([ShadeHost.barHeight]), so the clock follows the title
 * and the status icons sit before the controls ([parts]: what the status bar leaves to the window).
 */
internal class WebWindowChrome(
    context: Context,
    private val container: SurfaceControl,
    private val label: String,
    private val icon: Drawable?,
) {
    private val dp = context.resources.displayMetrics.density
    private val barWidth = context.resources.displayMetrics.let { maxOf(it.widthPixels, it.heightPixels) }
    val title = Math.round(TITLE_DP * dp)
    private val button = Math.round(BUTTON_DP * dp)

    private val bar: SurfaceControl? = layer("bar", barWidth, title, 1)
    private val back: SurfaceControl? = layer("back", BACK, BACK, -1)

    /** The compositor blurs behind layers now (off in battery saver, with blurs disabled in the developer options). */
    private val windows = context.getSystemService(android.view.WindowManager::class.java)

    private fun compositorBlurs() = runCatching { windows.isCrossWindowBlurEnabled }.getOrDefault(false)

    /** What the bar shows now: redrawn only when one of these changes. */
    private var drawn: String? = null

    private fun layer(
        name: String,
        w: Int,
        h: Int,
        z: Int,
    ): SurfaceControl? =
        runCatching {
            SurfaceControl.Builder().setName("${nameOf(container)}-$name").setParent(container).setBufferSize(w, h)
                .setFormat(PixelFormat.TRANSLUCENT).build().also { SurfaceControl.Transaction().setLayer(it, z).setVisibility(it, true).apply() }
        }.onFailure { Log.w(TAG, "no $name layer", it) }.getOrNull()

    private fun nameOf(sc: SurfaceControl) = sc.toString().substringAfter("{").substringBefore(" ").ifEmpty { "powos-ww" }

    /** Which control is at [x] (window px from its left, in a [width]-wide bar): "close", "maximise", "minimise", or null. */
    fun control(
        x: Float,
        width: Int,
    ): String? {
        val fromRight = width - x
        return when {
            fromRight < 0 -> null
            fromRight < button -> "close"
            fromRight < 2 * button -> "maximise"
            fromRight < 3 * button -> "minimise"
            else -> null
        }
    }

    /** The frame for a [width] x [height] window (px, unscaled) into [t]; the bar redrawn when it changed. */
    fun layout(
        t: SurfaceControl.Transaction,
        size: android.util.Size,
        maximised: Boolean,
        theme: Theme,
    ) {
        val width = size.width
        val height = size.height
        back?.takeIf { it.isValid }?.let { b ->
            val bodyH = (height - title).coerceAtLeast(1)
            t.setPosition(b, 0f, title.toFloat())
            t.setScale(b, width / BACK.toFloat(), bodyH / BACK.toFloat())
        }
        val blurs = theme.glass != null && setBackgroundBlurRadius != null && compositorBlurs()
        val key = "$width $maximised $theme $blurs ${rowCentre(maximised)}"
        if (key == drawn) return
        drawn = key
        bar?.takeIf { it.isValid }?.let {
            blurBehind(t, it, if (blurs) theme.glass!!.blur else 0)
            draw(it, Look(width, maximised, theme, blurs))
        }
        back?.takeIf { it.isValid }?.let { fill(it, theme.bg) }
    }

    private fun fill(
        sc: SurfaceControl,
        color: Int,
    ) = paint(sc) { it.drawColor(color, PorterDuff.Mode.SRC) }

    private fun paint(
        sc: SurfaceControl,
        block: (Canvas) -> Unit,
    ) {
        val s = Surface(sc)
        try {
            val c = s.lockHardwareCanvas()
            try {
                block(c)
            } finally {
                s.unlockCanvasAndPost(c)
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "window frame not drawn", e)
        } finally {
            s.release()
        }
    }

    /** The title's paint (its width decides where a maximised bar's title ends: [parts]). */
    private val text = android.text.TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 14 * dp }

    /** Where the title starts (after the icon), window px. */
    private val textX = 12 * dp + (if (icon != null) 28 * dp else 0f)

    /** The title's room in a [width]-wide bar: maximised, at most [MERGED_TITLE] of it - the clock comes next. */
    private fun titleRoom(
        width: Int,
        maximised: Boolean,
    ): Float {
        val room = width - 3 * button - textX - 8 * dp
        return if (maximised) minOf(room, width * MERGED_TITLE) else room
    }

    private fun shownTitle(
        width: Int,
        maximised: Boolean,
    ): CharSequence {
        val room = titleRoom(width, maximised)
        return if (room > 0) android.text.TextUtils.ellipsize(label, text, room, android.text.TextUtils.TruncateAt.END) else ""
    }

    /**
     * What of a [width]-wide maximised bar is the window's on a merged bar (TB1): its title's right end and its controls'
     * left, window px. Everything between is the status bar's (the clock, the meter, the status icons).
     */
    fun parts(width: Int): IntArray {
        val shown = shownTitle(width, true)
        return intArrayOf(Math.round(textX + text.measureText(shown, 0, shown.length) + 12 * dp), width - 3 * button)
    }

    /** The row's centre (px from the bar's top): maximised, the status bar's, so the title and the clock share a line. */
    private fun rowCentre(maximised: Boolean): Float {
        val bar = dev.omalauncher.system.ShadeHost.current?.barHeight ?: 0
        return if (maximised && bar > 0) (bar / 2f).coerceIn(title / 2f, title - 10 * dp) else title / 2f
    }

    /** What a bar is drawn for: its width (px), maximised, the page's theme, and whether the compositor blurs under it. */
    private data class Look(
        val width: Int,
        val maximised: Boolean,
        val theme: Theme,
        val blurs: Boolean,
    )

    private fun draw(
        sc: SurfaceControl,
        look: Look,
    ) = paint(sc) { c ->
        val (width, maximised, theme) = look
        c.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        glass(c, look)
        val cy = rowCentre(maximised)
        var x = 12 * dp
        icon?.let { d ->
            val size = Math.round(20 * dp)
            val top = Math.round(cy - size / 2f)
            d.setBounds(x.toInt(), top, x.toInt() + size, top + size)
            d.draw(c)
            x += size + 8 * dp
        }
        text.color = theme.fg
        val shown = shownTitle(width, maximised)
        if (shown.isNotEmpty()) c.drawText(shown, 0, shown.length, x, cy - (text.descent() + text.ascent()) / 2, text)
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = theme.fg
            style = Paint.Style.STROKE
            strokeWidth = 1.8f * dp / 2f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        // The middle button is always "full screen app" (WebWindows.fullScreen): a window filling the work area (the bar's
        // double tap) is still a window, so the glyph doesn't turn into restore.
        listOf("close", "maximise", "minimise").forEachIndexed { i, kind ->
            val cx = width - button * (i + 0.5f)
            mark(c, kind, android.graphics.PointF(cx, cy), stroke)
        }
    }

    /**
     * The bar's material: a home widget's glass when the page sent it ([Theme.glass]: the veil, then the fill over it -
     * a .tile's two backgrounds - and its edge), over the solid surface colour when the compositor doesn't blur; the
     * old solid bar without it (an older page). Maximised it is a full-width bar: only its bottom edge.
     */
    private fun glass(
        c: Canvas,
        look: Look,
    ) {
        val (width, maximised, theme, blurs) = look
        val w = width.toFloat()
        val h = title.toFloat()
        val g = theme.glass
        if (g == null || !blurs) c.drawRect(0f, 0f, w, h, Paint().apply { color = theme.bg })
        if (g == null) return
        c.drawRect(0f, 0f, w, h, Paint().apply { color = g.veil })
        c.drawRect(0f, 0f, w, h, Paint().apply { color = g.fill })
        if (g.frame <= 0f) return
        val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = g.edge
            style = Paint.Style.STROKE
            strokeWidth = g.frame
        }
        val half = g.frame / 2
        if (maximised) {
            c.drawLine(0f, h - half, w, h - half, edge)
        } else {
            // The window's top and sides (its corners rounded as a widget's): the body below carries on without one.
            c.drawRoundRect(half, half, w - half, h + g.radius + g.frame, g.radius, g.radius, edge)
        }
    }

    /** What's under the bar blurred by the compositor by [radius] px (0: none) - a widget's blur, on this layer. */
    private fun blurBehind(
        t: SurfaceControl.Transaction,
        sc: SurfaceControl,
        radius: Int,
    ) {
        runCatching { setBackgroundBlurRadius?.invoke(t, sc, radius) }.onFailure { Log.w(TAG, "bar not blurred", it) }
    }

    /** ui/chrome.tsx's Mark paths (a 24-unit box), drawn 12 dp wide at ([cx], [cy]). */
    private fun mark(
        c: Canvas,
        kind: String,
        at: android.graphics.PointF,
        p: Paint,
    ) {
        val cx = at.x
        val cy = at.y
        val u = 12 * dp / 24f
        fun pt(v: Float, o: Float) = o + (v - 12f) * u
        val path = Path()
        fun line(x1: Float, y1: Float, x2: Float, y2: Float) {
            path.moveTo(pt(x1, cx), pt(y1, cy))
            path.lineTo(pt(x2, cx), pt(y2, cy))
        }
        fun box(l: Float, t: Float, r: Float, b: Float) = path.addRect(pt(l, cx), pt(t, cy), pt(r, cx), pt(b, cy), Path.Direction.CW)
        when (kind) {
            "minimise" -> line(4f, 12f, 20f, 12f)
            "maximise" -> box(5f, 5f, 19f, 19f)
            "restore" -> {
                box(5f, 9f, 15f, 19f)
                line(9f, 5f, 19f, 5f)
                line(19f, 5f, 19f, 15f)
            }
            else -> {
                line(5f, 5f, 19f, 19f)
                line(5f, 19f, 19f, 5f)
            }
        }
        c.drawPath(path, p)
    }

    fun release(t: SurfaceControl.Transaction) {
        for (sc in listOfNotNull(bar, back)) {
            if (sc.isValid) t.reparent(sc, null)
        }
    }

    fun releaseNow() {
        bar?.release()
        back?.release()
    }

    /** A home widget's glass, as the page resolves it (device px): its tints, edge, blur and corner radius. */
    data class Glass(
        val fill: Int,
        val veil: Int,
        val edge: Int,
        val frame: Float,
        val blur: Int,
        val radius: Float,
    )

    /** The page's colours for the bar ("w.theme"; ARGB) and its widget glass (null: an older page, a solid bar). */
    data class Theme(
        val bg: Int,
        val fg: Int,
        val glass: Glass? = null,
    ) {
        companion object {
            val DEFAULT = Theme(Color.rgb(32, 33, 36), Color.WHITE)

            /**
             * "<bg r g b a> <fg r g b a> [<fill r g b a> <veil r g b a> <edge r g b a> <frame> <blur> <radius>]" (the
             * page's resolved CSS colours; lengths device px); null: unreadable.
             */
            fun parse(rest: String): Theme? =
                runCatching {
                    val n = rest.trim().split(' ').map { it.toFloat() }
                    fun argb(i: Int) = Color.argb(Math.round(n[i + 3] * 255), n[i].toInt(), n[i + 1].toInt(), n[i + 2].toInt())
                    val glass = if (n.size >= 23) Glass(argb(8), argb(12), argb(16), n[20], Math.round(n[21]), n[22]) else null
                    Theme(argb(0), argb(4), glass)
                }.getOrNull()
        }
    }

    companion object {
        private const val TAG = "PowosWebWindows"
        const val TITLE_DP = 36f
        private const val BUTTON_DP = 40f
        private const val BACK = 8

        /** A maximised bar's title takes at most this share of its width: the status bar's clock follows it. */
        private const val MERGED_TITLE = 0.3f

        /** HACK: Transaction.setBackgroundBlurRadius is hidden (WindowBlur's too), reflected. Real fix: none public for a layer. */
        private val setBackgroundBlurRadius: java.lang.reflect.Method? by lazy {
            runCatching {
                dev.omalauncher.system.HiddenApi.allow()
                SurfaceControl.Transaction::class.java.getMethod("setBackgroundBlurRadius", SurfaceControl::class.java, Int::class.javaPrimitiveType)
            }.onFailure { Log.w(TAG, "no setBackgroundBlurRadius: a solid bar", it) }.getOrNull()
        }
    }
}
