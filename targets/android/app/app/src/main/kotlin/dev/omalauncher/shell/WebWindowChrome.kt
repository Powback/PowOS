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
 * (icon, title, tile, minimise, full screen, close - the shell's window-control look, ui/chrome.tsx) above the app's
 * mirror, and a background under the mirror (shown where the app hasn't drawn yet: a resize before the app lays out).
 *
 * Why native: the user, 2026-10-30, "nobody asked for the cutoff" - the window sits on home like a card, so it can't be
 * home's DOM (DOM is under or over home's whole buffer, never one window's layer), and "its like its content is
 * lagging behind slightly even when I move windows": bar and content in one layer stack move in one transaction.
 *
 * Layers under the window's container: background (-1, an 8x8 buffer scaled over the body), the mirror (0, the
 * caller's), the bar (1, a buffer the width of the screen's long side, cropped by the container).
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

    /**
     * Which control is at [x] (window px from its left, in a [width]-wide bar): "close", "maximise", "minimise", "tile"
     * (PowOS's split screen: its menu - docs/WEB_WINDOWS.md "Tiles"), or null.
     */
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
            fromRight < 4 * button -> "tile"
            else -> null
        }
    }

    /** [control]'s centre, window px from the left of a [width]-wide bar. */
    fun centerOf(
        control: String,
        width: Int,
    ): Float = width - button * (CONTROLS.indexOf(control).coerceAtLeast(0) + 0.5f)

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
        val key = "$width $maximised ${theme.bg} ${theme.fg}"
        if (key == drawn) return
        drawn = key
        bar?.takeIf { it.isValid }?.let { draw(it, width, maximised, theme) }
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

    private fun draw(
        sc: SurfaceControl,
        width: Int,
        maximised: Boolean,
        theme: Theme,
    ) = paint(sc) { c ->
        c.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        val fill = Paint().apply { color = theme.bg }
        c.drawRect(0f, 0f, width.toFloat(), title.toFloat(), fill)
        var x = 12 * dp
        icon?.let { d ->
            val size = Math.round(20 * dp)
            val top = (title - size) / 2
            d.setBounds(x.toInt(), top, x.toInt() + size, top + size)
            d.draw(c)
            x += size + 8 * dp
        }
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = theme.fg
            textSize = 14 * dp
        }
        val room = width - CONTROLS.size * button - x - 8 * dp
        if (room > 0) {
            val shown = android.text.TextUtils.ellipsize(label, android.text.TextPaint(text), room, android.text.TextUtils.TruncateAt.END)
            c.drawText(shown, 0, shown.length, x, title / 2f - (text.descent() + text.ascent()) / 2, text)
        }
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = theme.fg
            style = Paint.Style.STROKE
            strokeWidth = 1.8f * dp / 2f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        // The middle button is always "full screen app" (WebWindows.fullScreen): a window filling the work area (the bar's
        // double tap) is still a window, so the glyph doesn't turn into restore.
        CONTROLS.forEachIndexed { i, kind ->
            val cx = width - button * (i + 0.5f)
            mark(c, kind, android.graphics.PointF(cx, title / 2f), stroke)
        }
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
            // Two panes side by side: the tile menu.
            "tile" -> {
                box(4f, 5f, 20f, 19f)
                line(12f, 5f, 12f, 19f)
            }
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

    /** The page's colours for the bar ("w.theme"; ARGB). */
    data class Theme(
        val bg: Int,
        val fg: Int,
    ) {
        companion object {
            val DEFAULT = Theme(Color.rgb(32, 33, 36), Color.WHITE)

            /** "r g b a r g b a" (the page's resolved CSS colours); null: unreadable. */
            fun parse(rest: String): Theme? =
                runCatching {
                    val n = rest.trim().split(' ').map { it.toFloat() }
                    fun argb(i: Int) = Color.argb(Math.round(n[i + 3] * 255), n[i].toInt(), n[i + 1].toInt(), n[i + 2].toInt())
                    Theme(argb(0), argb(4))
                }.getOrNull()
        }
    }

    companion object {
        private const val TAG = "PowosWebWindows"
        const val TITLE_DP = 36f
        private const val BUTTON_DP = 40f
        private const val BACK = 8

        /** The bar's buttons, right to left. */
        private val CONTROLS = listOf("close", "maximise", "minimise", "tile")
    }
}
