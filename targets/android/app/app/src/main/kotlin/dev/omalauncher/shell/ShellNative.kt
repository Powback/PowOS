package dev.omalauncher.shell

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.webkit.WebMessage
import android.webkit.WebMessagePort
import android.webkit.WebView
import android.widget.FrameLayout

/**
 * The shell page's second channel to the app (shell/apps/native.ts), beside the PowosHost bridge: a WebMessagePort
 * the app hands only to the page's top frame at its own origin ([WebView.postWebMessage] with that target origin), so
 * only the page's top frame holds it. Messages are strings, one command each, never answered unless they say so:
 *
 *   open <url>                         an http(s) / mailto / tel / geo / market link to the app that handles it
 *   s.create <id>                      a surface tile: a SurfaceView under the page, drawn by the app ([Tile])
 *   s.place <id> <x> <y> <w> <h> <dpr> where it is (CSS px of the page, its device pixel ratio)
 *   s.show <id> <0|1>                  shown (its last frame stays while it is) or not (its surface goes)
 *   s.draw <id> <w> <h> <ops...>       a frame: a display list in a w x h space ([draw])
 *   s.destroy <id> / s.reset           one tile / every tile (the page reloaded)
 *   n.req <json>                       PowOS apps' network capability ([ShellNet]): answered with n.res / n.ev / n.st
 *   b.hello                            the page's glass asks whether the compositor blurs for it: "b.state 1|0" back
 *                                      (again whenever that changes) - [GlassBlur]; "b.backdrop live": liquid edges
 *                                      bend the live wallpaper ([WallpaperBackdrop])
 *   b.r <dpr> <n> <region...>          the glass surfaces' rounded rectangles, blurred live by the compositor
 *   b.lag <frames>                     test knob: when the regions apply (-1 at once, 0 on the next draw, n later)
 *   b.liquid <dpr> <band> <refraction> <rim> <dispersion>   liquid glass's look (theme.css --liquid-*): [LiquidGlass]
 *
 * Why surfaces: a canvas in the page, however it's drawn (an OffscreenCanvas in a worker included), makes the whole
 * WebView composite again for each frame - in the app's own render threads - which cost ~2% of a core per frame per
 * second for the stickman widget (apps/stickman). A SurfaceView's frames go straight to the display compositor: the
 * page and the app's views draw nothing for them. The SurfaceView sits below the window and the WebView (transparent
 * where the tile shows it) above it, so everything the page draws over the tile - its frame, a launcher, a sheet -
 * stays over it, and touches go to the page as before.
 *
 * The page asks for its port with PowosNative.postMessage("connect") (window.PowosNative, a web message listener that
 * only the top frame at the shell's origin gets and may use: ShellHost.listen, ShellOrigin).
 */
class ShellNative(
    private val context: Context,
    private val web: WebView,
    private val origin: String,
    pageGlass: Boolean = true,
) {
    private val main = Handler(Looper.getMainLooper())
    private val render = HandlerThread("PowosSurface").apply { start() }
    private val renderer = Handler(render.looper)
    private var port: WebMessagePort? = null
    private val tiles = HashMap<Int, Tile>()
    private val net = ShellNet(context) { text -> main.post { port?.postMessage(WebMessage(text)) } }

    /** The glass's live blur (Android 13+: the window's surface control), for a page in a window. */
    internal val glass: GlassBlur? =
        if (pageGlass && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            GlassBlur(web) { text -> port?.postMessage(WebMessage(text)) }.also { g ->
                g.holes = { synchronized(tiles) { tiles.values.mapNotNull { it.shownRect() } } }
            }
        } else {
            null
        }

    fun connect() {
        main.post {
            port?.close()
            net.reset()
            val (mine, theirs) = web.createWebMessageChannel()
            mine.setWebMessageCallback(
                object : WebMessagePort.WebMessageCallback() {
                    override fun onMessage(
                        p: WebMessagePort,
                        m: WebMessage,
                    ) = m.data?.let(::command) ?: Unit
                },
                renderer,
            )
            port = mine
            web.postWebMessage(WebMessage("powos-native", arrayOf(theirs)), Uri.parse(origin))
            // A new page: its glass asks again (b.hello); the last page's regions go with it.
            glass?.reset()
        }
    }

    /** Home's panels over the floating windows: made at home's page's "p.hello". */
    @Volatile private var lift: PanelLift? = null

    fun close() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) main.post { lift?.close() }
        main.post {
            port?.close()
            port = null
            net.reset()
            tiles.values.forEach { it.remove() }
            tiles.clear()
        }
        glass?.close()
        render.quitSafely()
    }

    /** On the render thread: draws there, places and shows on the main thread. */
    private fun command(text: String) {
        val verb = text.substringBefore(' ')
        val rest = text.substringAfter(' ', "")
        try {
            when (verb) {
                "open" -> open(rest.trim())
                "n.req" -> net.command(rest)
                // Home's panels over the floating windows (PanelLift; only home's page sends these).
                "p.hello" -> if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) main.post { (lift ?: PanelLift(web) { t -> main.post { port?.postMessage(WebMessage(t)) } }.also { lift = it }).hello() }
                "p.lift" -> if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) lift?.want(rest.trim() == "1")
                "b.hello" -> if (glass != null) glass.hello() else main.post { port?.postMessage(WebMessage("b.state 0")) }
                "b.r" -> glass?.command(rest)
                "b.lag" -> glass?.let { it.lag = rest.trim().toInt() }
                "b.liquid" -> glass?.liquidCommand(rest)
                "s.draw" -> {
                    val id = rest.substringBefore(' ').toInt()
                    synchronized(tiles) { tiles[id] }?.draw(rest.substringAfter(' '))
                }
                "s.create" -> rest.trim().toInt().let { id -> main.post { create(id) } }
                "s.place" -> {
                    val a = rest.trim().split(' ')
                    val id = a[0].toInt()
                    val n = a.drop(1).map { it.toFloat() }
                    main.post {
                        synchronized(tiles) { tiles[id] }?.place(n[0], n[1], n[2], n[3], n[4])
                        glass?.holesChanged()
                    }
                }
                "s.show" -> {
                    val (id, on) = rest.trim().split(' ')
                    main.post {
                        synchronized(tiles) { tiles[id.toInt()] }?.show(on == "1")
                        glass?.holesChanged()
                    }
                }
                "s.destroy" -> rest.trim().toInt().let { id -> main.post { synchronized(tiles) { tiles.remove(id) }?.remove() } }
                "s.reset" -> main.post { synchronized(tiles) { tiles.values.toList().also { tiles.clear() } }.forEach { it.remove() } }
                else -> Log.w(TAG, "no such command: $verb")
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "$verb: $e")
        }
    }

    private fun open(url: String) {
        val uri = Uri.parse(url)
        if (uri.scheme?.lowercase() !in SCHEMES) {
            Log.w(TAG, "open: not a link it opens: $url")
            return
        }
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), dev.omalauncher.system.AppWindows.bundle(context))
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "open: nothing opens $url")
        }
    }

    private fun create(id: Int) {
        val parent = web.parent as? ViewGroup
        if (parent == null) {
            Log.w(TAG, "s.create: the page has no parent view to put a surface in")
            return
        }
        synchronized(tiles) { tiles.remove(id) }?.remove()
        val tile = Tile(SurfaceView(context), renderer)
        // Below the page in the view order too: the page gets every touch first (it takes them all).
        parent.addView(tile.view, parent.indexOfChild(web), FrameLayout.LayoutParams(1, 1))
        synchronized(tiles) { tiles[id] = tile }
    }

    /** One surface tile: drawn on the render thread, laid out on the main thread. */
    private class Tile(
        val view: SurfaceView,
        private val renderer: Handler,
    ) : SurfaceHolder.Callback {
        @Volatile private var ready = false

        /** The last frame: drawn again when the surface comes (back) - shown again, resized - so it's never blank. */
        @Volatile private var last: String? = null
        @Volatile private var bufW = 1
        @Volatile private var bufH = 1
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
        private val path = Path()

        init {
            view.holder.setFormat(PixelFormat.TRANSLUCENT)
            view.holder.addCallback(this)
            view.visibility = View.INVISIBLE
            view.isClickable = false
            view.isFocusable = false
            view.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        fun place(
            x: Float,
            y: Float,
            w: Float,
            h: Float,
            dpr: Float,
        ) {
            val lp = view.layoutParams
            val pw = (w * dpr).toInt().coerceAtLeast(1)
            val ph = (h * dpr).toInt().coerceAtLeast(1)
            if (lp.width != pw || lp.height != ph) {
                lp.width = pw
                lp.height = ph
                view.layoutParams = lp
            }
            view.x = x * dpr
            view.y = y * dpr
            // The buffer at most 2x the CSS size: strokes look the same, the GPU fills less (the compositor scales it).
            val s = minOf(dpr, 2f)
            bufW = (w * s).toInt().coerceAtLeast(1)
            bufH = (h * s).toInt().coerceAtLeast(1)
            view.holder.setFixedSize(bufW, bufH)
        }

        fun show(on: Boolean) {
            view.visibility = if (on) View.VISIBLE else View.INVISIBLE
        }

        /** Where it shows (the window's px), if it does: the live glass leaves it unblurred ([GlassBlur.holes]). */
        fun shownRect(): android.graphics.RectF? =
            if (view.visibility != View.VISIBLE) {
                null
            } else {
                android.graphics.RectF(view.x, view.y, view.x + view.layoutParams.width, view.y + view.layoutParams.height)
            }

        fun remove() {
            ready = false
            (view.parent as? ViewGroup)?.removeView(view)
        }

        override fun surfaceCreated(holder: SurfaceHolder) {
            ready = true
            redraw()
        }

        private fun redraw() = renderer.post { last?.let(::draw) }

        override fun surfaceChanged(
            holder: SurfaceHolder,
            format: Int,
            width: Int,
            height: Int,
        ) {
            ready = true
            redraw()
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            ready = false
        }

        /**
         * A frame: "<w> <h> <op> ..." in a w x h space, scaled to the buffer. Ops (colours #rrggbb, alpha 0-1):
         *   K                                   clear (every frame starts transparent anyway)
         *   S <color> <alpha> <width> <n> x0 y0 x1 y1 ...   n line segments, round ends
         *   R <color> <alpha> <width> x y w h   a rectangle's outline
         *   C <color> <alpha> <n> x y r ...     n filled circles
         *   P <color> <alpha> <n> x y ...       a filled polygon of n points
         */
        fun draw(frame: String) {
            last = frame
            if (!ready) return
            val surface = view.holder.surface
            if (!surface.isValid) return
            val t = frame.split(' ')
            var i = 0
            val w = t[i++].toFloat()
            val h = t[i++].toFloat()
            val canvas: Canvas =
                try {
                    surface.lockHardwareCanvas()
                } catch (e: IllegalStateException) {
                    return
                } catch (e: IllegalArgumentException) {
                    return
                }
            try {
                canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
                canvas.scale(bufW / w, bufH / h)
                while (i < t.size) {
                    when (t[i++]) {
                        "K" -> canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
                        "S" -> {
                            stroke(t[i++], t[i++], t[i++])
                            val n = t[i++].toInt()
                            for (k in 0 until n) {
                                canvas.drawLine(t[i].toFloat(), t[i + 1].toFloat(), t[i + 2].toFloat(), t[i + 3].toFloat(), paint)
                                i += 4
                            }
                        }
                        "R" -> {
                            stroke(t[i++], t[i++], t[i++])
                            val x = t[i++].toFloat()
                            val y = t[i++].toFloat()
                            canvas.drawRect(x, y, x + t[i++].toFloat(), y + t[i++].toFloat(), paint)
                        }
                        "C" -> {
                            fill(t[i++], t[i++])
                            val n = t[i++].toInt()
                            for (k in 0 until n) {
                                canvas.drawCircle(t[i].toFloat(), t[i + 1].toFloat(), t[i + 2].toFloat(), paint)
                                i += 3
                            }
                        }
                        "P" -> {
                            fill(t[i++], t[i++])
                            val n = t[i++].toInt()
                            path.rewind()
                            for (k in 0 until n) {
                                if (k == 0) path.moveTo(t[i].toFloat(), t[i + 1].toFloat()) else path.lineTo(t[i].toFloat(), t[i + 1].toFloat())
                                i += 2
                            }
                            path.close()
                            canvas.drawPath(path, paint)
                        }
                        else -> break
                    }
                }
            } catch (e: RuntimeException) {
                Log.w(TAG, "s.draw: bad frame ($e)")
            } finally {
                surface.unlockCanvasAndPost(canvas)
            }
        }

        private fun stroke(
            color: String,
            alpha: String,
            width: String,
        ) {
            paint.style = Paint.Style.STROKE
            paint.color = color(color, alpha)
            paint.strokeWidth = width.toFloat()
        }

        private fun fill(
            color: String,
            alpha: String,
        ) {
            paint.style = Paint.Style.FILL
            paint.color = color(color, alpha)
        }

        private fun color(
            c: String,
            alpha: String,
        ): Int {
            val rgb = runCatching { Color.parseColor(c) }.getOrDefault(Color.WHITE)
            val a = (Color.alpha(rgb) * alpha.toFloat().coerceIn(0f, 1f)).toInt()
            return (rgb and 0xFFFFFF) or (a shl 24)
        }
    }

    companion object {
        private const val TAG = "PowosNative"
        private val SCHEMES = setOf("http", "https", "mailto", "tel", "geo", "market")
    }
}
