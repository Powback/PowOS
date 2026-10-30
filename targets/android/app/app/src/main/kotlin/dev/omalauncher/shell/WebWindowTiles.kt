package dev.omalauncher.shell

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.Rect
import android.graphics.RectF
import android.util.Log
import android.view.Surface
import android.view.SurfaceControl

/**
 * PowOS's own split screen, native half (docs/WEB_WINDOWS.md "Tiles"; the model is ui/webwindows.tsx's tilings). The
 * user, 2026-10-30: "lets take full control and replace that too so we can unlock our own splitscreen capabilities
 * maybe with like 3 of 4 apps at once". Android's split (WM Shell) paints a veil in the app's TaskDescription colour
 * while its divider moves (white for most apps) and holds 2 apps; this one moves each app's own last frame and holds 4.
 *
 * Here, under the windows' root layer: the dividers' handles (one layer per divider, above every window), the snap
 * hint (where a window let go at an edge or corner would tile) and the bar's tile menu. [WebWindows] owns the touches
 * and the windows' layers; this draws and hit-tests.
 */
internal class WebWindowTiles(
    context: Context,
    private val cornerRadius: (SurfaceControl.Transaction, SurfaceControl, Float) -> Unit,
) {
    private val dp = context.resources.displayMetrics.density

    /**
     * One divider from the page's "w.f" (window px): [key] "<page>:<x|y>"; a vertical one ("x") is the line at [pos]
     * from [from] for [len]; its ratio is of [lo]..[hi]; [before]/[after] the windows whose right (bottom) and left
     * (top) edges follow it.
     */
    class Divider(
        val key: String,
        val vertical: Boolean,
        val pos: Float,
        val from: Float,
        val len: Float,
        val lo: Float,
        val hi: Float,
        val before: IntArray,
        val after: IntArray,
    ) {
        fun ratio(at: Float) = ((at - lo) / (hi - lo).coerceAtLeast(1f))
    }

    var dividers: List<Divider> = emptyList()
        private set

    private class Handle(
        val sc: SurfaceControl,
        val vertical: Boolean,
        var drawn: String? = null,
    )

    private val handles = HashMap<String, Handle>()
    private var hint: SurfaceControl? = null
    private var hintDrawn: Int? = null
    private var menu: SurfaceControl? = null

    /** The open tile menu: its window, rect (window px) and items, left to right. */
    var menuFor: Int? = null
        private set
    private var menuRect = RectF()
    private var menuItems: List<String> = emptyList()

    /** The dividers into [t] under [root] (a divider being dragged is the caller's: [skip]). */
    fun place(
        t: SurfaceControl.Transaction,
        root: SurfaceControl,
        list: List<Divider>,
        theme: WebWindowChrome.Theme,
        skip: String?,
    ) {
        dividers = list
        val keys = list.map { it.key }.toSet()
        for (k in handles.keys.filter { it !in keys }) handles.remove(k)?.let { h -> if (h.sc.isValid) t.reparent(h.sc, null) }
        for (d in list) {
            if (d.key == skip) continue
            val h = handle(root, d, theme) ?: continue
            at(t, h, d.pos, d)
        }
    }

    /** Divider [d]'s handle at [pos] (its line's middle). */
    fun at(
        t: SurfaceControl.Transaction,
        h: Any,
        pos: Float,
        d: Divider,
    ) {
        val sc = (h as Handle).sc
        if (!sc.isValid) return
        val (w, l) = handleSize()
        if (d.vertical) t.setPosition(sc, pos - w / 2f, d.from + d.len / 2f - l / 2f) else t.setPosition(sc, d.from + d.len / 2f - l / 2f, pos - w / 2f)
        t.setLayer(sc, LAYER_DIVIDER).setVisibility(sc, true)
    }

    /** [d]'s handle layer (made and drawn on first use; redrawn when the theme changes). */
    fun handle(
        root: SurfaceControl,
        d: Divider,
        theme: WebWindowChrome.Theme,
    ): Any? {
        var h = handles[d.key]?.takeIf { it.vertical == d.vertical && it.sc.isValid }
        if (h == null) {
            handles.remove(d.key)?.let { old -> if (old.sc.isValid) SurfaceControl.Transaction().reparent(old.sc, null).apply() }
            val (w, l) = handleSize()
            val sc = layer(root, "powos-ww-divider-${d.key}", if (d.vertical) w else l, if (d.vertical) l else w) ?: return null
            h = Handle(sc, d.vertical)
            handles[d.key] = h
        }
        val key = "${theme.bg} ${theme.fg}"
        if (h.drawn != key) {
            h.drawn = key
            paint(h.sc) { c -> pill(c, h.vertical, theme) }
        }
        return h
    }

    /** The handle's buffer: thick and long (dp-sized; across x along). */
    private fun handleSize() = Pair(Math.round(HANDLE_W_DP * dp), Math.round(HANDLE_L_DP * dp))

    /** A pill in the page's foreground colour with a rim in its surface colour (reads on any wallpaper). */
    private fun pill(
        c: Canvas,
        vertical: Boolean,
        theme: WebWindowChrome.Theme,
    ) {
        c.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        val w = c.width.toFloat()
        val h = c.height.toFloat()
        val thick = PILL_DP * dp
        val r = if (vertical) RectF(w / 2 - thick / 2, 0f, w / 2 + thick / 2, h) else RectF(0f, h / 2 - thick / 2, w, h / 2 + thick / 2)
        val rim = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.bg }
        val o = 1.5f * dp
        c.drawRoundRect(RectF(r.left - o, r.top - o, r.right + o, r.bottom + o), thick, thick, rim)
        c.drawRoundRect(r, thick, thick, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.fg })
    }

    /** The divider whose touch target ([TOUCH_DP] across, its whole length) holds ([x], [y]), or null. */
    fun dividerAt(
        x: Float,
        y: Float,
    ): Divider? {
        val half = TOUCH_DP * dp / 2
        return dividers.firstOrNull { d ->
            val (across, along) = if (d.vertical) x to y else y to x
            Math.abs(across - d.pos) <= half && along >= d.from && along <= d.from + d.len
        }
    }

    // ---- snap hint ------------------------------------------------------------------------------------------------------

    /** Where a window let go now would tile ([r], window px), or nothing (null). */
    fun hint(
        root: SurfaceControl,
        r: Rect?,
        theme: WebWindowChrome.Theme,
    ) {
        val t = SurfaceControl.Transaction()
        if (r == null) {
            hint?.takeIf { it.isValid }?.let { t.setVisibility(it, false) }
            t.apply()
            return
        }
        val sc = hint?.takeIf { it.isValid } ?: layer(root, "powos-ww-snap", HINT, HINT)?.also { hint = it } ?: return
        if (hintDrawn != theme.fg) {
            hintDrawn = theme.fg
            paint(sc) { it.drawColor(Color.argb(72, Color.red(theme.fg), Color.green(theme.fg), Color.blue(theme.fg)), PorterDuff.Mode.SRC) }
        }
        t.setPosition(sc, r.left.toFloat(), r.top.toFloat()).setScale(sc, r.width() / HINT.toFloat(), r.height() / HINT.toFloat())
        t.setLayer(sc, LAYER_HINT).setVisibility(sc, true).apply()
    }

    // ---- the bar's tile menu --------------------------------------------------------------------------------------------

    /**
     * The tile menu under window [id]'s tile button ([anchorX], [top]: window px), kept inside [area]: halves, corners
     * would be too many to read at a glance - left, right, top, bottom, grid (with the page's other windows), and float
     * when it is [tiled].
     */
    fun openMenu(
        root: SurfaceControl,
        id: Int,
        anchorX: Float,
        top: Float,
        area: Rect,
        tiled: Boolean,
        theme: WebWindowChrome.Theme,
    ) {
        menuItems = listOf("left", "right", "top", "bottom", "grid") + if (tiled) listOf("float") else emptyList()
        val cell = CELL_DP * dp
        val pad = 6 * dp
        val w = menuItems.size * cell + 2 * pad
        val h = cell + 2 * pad
        val x = (anchorX - w / 2).coerceIn(area.left.toFloat(), (area.right - w).coerceAtLeast(area.left.toFloat()))
        val y = top.coerceAtMost(area.bottom - h)
        menuRect = RectF(x, y, x + w, y + h)
        menu?.let { if (it.isValid) SurfaceControl.Transaction().reparent(it, null).apply() }
        val sc = layer(root, "powos-ww-tilemenu", w.toInt(), h.toInt()) ?: return
        menu = sc
        menuFor = id
        paint(sc) { c -> drawMenu(c, cell, pad, theme) }
        val t = SurfaceControl.Transaction().setPosition(sc, x, y).setLayer(sc, LAYER_MENU).setVisibility(sc, true)
        cornerRadius(t, sc, 12 * dp)
        t.apply()
        Log.i(TAG, "tile menu for window $id: ${menuItems.joinToString()}")
    }

    fun closeMenu() {
        menuFor = null
        menu?.let { if (it.isValid) SurfaceControl.Transaction().reparent(it, null).apply() }
        menu = null
    }

    /** The menu item at ([x], [y]), "" inside the menu but on no item, null outside it. */
    fun menuAt(
        x: Float,
        y: Float,
    ): String? {
        if (menuFor == null || !menuRect.contains(x, y)) return null
        val i = ((x - menuRect.left - 6 * dp) / (CELL_DP * dp)).toInt()
        return menuItems.getOrNull(i) ?: ""
    }

    private fun drawMenu(
        c: Canvas,
        cell: Float,
        pad: Float,
        theme: WebWindowChrome.Theme,
    ) {
        c.drawColor(theme.bg, PorterDuff.Mode.SRC)
        val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = theme.fg
            style = Paint.Style.STROKE
            strokeWidth = 1.5f * dp
        }
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.fg }
        menuItems.forEachIndexed { i, item ->
            val cx = pad + cell * (i + 0.5f)
            val cy = pad + cell / 2
            val s = 11 * dp
            val box = RectF(cx - s, cy - s * 0.8f, cx + s, cy + s * 0.8f)
            c.drawRoundRect(box, 2 * dp, 2 * dp, line)
            val g = 1.5f * dp
            fun part(l: Float, t: Float, r: Float, b: Float) =
                c.drawRect(box.left + box.width() * l + g, box.top + box.height() * t + g, box.left + box.width() * r - g, box.top + box.height() * b - g, fill)
            when (item) {
                "left" -> part(0f, 0f, 0.5f, 1f)
                "right" -> part(0.5f, 0f, 1f, 1f)
                "top" -> part(0f, 0f, 1f, 0.5f)
                "bottom" -> part(0f, 0.5f, 1f, 1f)
                "grid" -> {
                    part(0f, 0f, 0.5f, 0.5f)
                    part(0.5f, 0.5f, 1f, 1f)
                }
                // Float: a small window off the grid.
                else -> part(0.25f, 0.25f, 0.75f, 0.75f)
            }
        }
    }

    // ---- layers ---------------------------------------------------------------------------------------------------------

    private fun layer(
        root: SurfaceControl,
        name: String,
        w: Int,
        h: Int,
    ): SurfaceControl? =
        runCatching {
            SurfaceControl.Builder().setName(name).setParent(root).setBufferSize(w.coerceAtLeast(1), h.coerceAtLeast(1)).setFormat(PixelFormat.TRANSLUCENT).build()
        }.onFailure { Log.w(TAG, "no $name layer", it) }.getOrNull()

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
            Log.w(TAG, "tiles layer not drawn", e)
        } finally {
            s.release()
        }
    }

    fun release() {
        val t = SurfaceControl.Transaction()
        for (sc in handles.values.map { it.sc } + listOfNotNull(hint, menu)) if (sc.isValid) t.reparent(sc, null)
        t.apply()
        handles.clear()
        hint = null
        menu = null
        menuFor = null
    }

    companion object {
        private const val TAG = "PowosWebWindows"

        /** ui/webwindows.tsx TILE_GAP (CSS px): the gap between tiles, where the handle sits. */
        const val GAP_CSS = 8f

        /** A divider's touch target across (the gap is 8 CSS px; a finger needs ~48). */
        const val TOUCH_DP = 44f
        private const val HANDLE_W_DP = 12f
        private const val HANDLE_L_DP = 56f
        private const val PILL_DP = 5f
        private const val CELL_DP = 44f
        private const val HINT = 8

        /** Above every window's container (their layers are their z, 0..n+1). */
        private const val LAYER_DIVIDER = 10_000
        private const val LAYER_HINT = 10_001
        private const val LAYER_MENU = 10_002

        /** Snap points of a divider let go (a share of its span); within [DROP] of an edge the squeezed side goes. */
        val SNAPS = floatArrayOf(1 / 3f, 1 / 2f, 2 / 3f)
        const val DROP = 0.12f

        fun snap(r: Float): Float = SNAPS.minByOrNull { Math.abs(it - r) } ?: 0.5f

        /**
         * OnePlus's own ways into Android's split, off while web windows are on (PowOS tiles instead), back to what they
         * were when it goes off: Settings.Secure double_finger_split_screen_enable (OxygenOS's swipe-down-with-fingers
         * split gesture) and Settings.System recommender_split_screen_enable (its split suggestions), both 1 on the
         * phone (read 2026-10-30). The switcher's own entry is the page's (ui/recents.tsx). At SystemUI's connect, off
         * the main thread.
         * HACK: OxygenOS's private settings keys, written as root (WRITE_SECURE_SETTINGS); real fix: a device config
         * without those entry points when the shell owns split screen.
         */
        fun splitEntryPoints(context: Context) {
            val app = context.applicationContext
            Thread({
                runCatching {
                    val prefs = app.getSharedPreferences("powos_split_entry_points", Context.MODE_PRIVATE)
                    val on = WebWindows.on(app)
                    for ((ns, key) in OPLUS_SPLIT) {
                        val now = andro.marchy.RootShell.run("settings get $ns $key").output.trim()
                        val saved = prefs.getString("$ns/$key", null)
                        when {
                            on && now != "0" -> {
                                prefs.edit().putString("$ns/$key", now).apply()
                                andro.marchy.RootShell.run("settings put $ns $key 0")
                                Log.i(TAG, "web windows on: OnePlus split entry $ns/$key $now -> 0 (PowOS tiles instead)")
                            }
                            !on && saved != null -> {
                                if (saved != "null") andro.marchy.RootShell.run("settings put $ns $key $saved")
                                prefs.edit().remove("$ns/$key").apply()
                                Log.i(TAG, "web windows off: OnePlus split entry $ns/$key back to $saved")
                            }
                        }
                    }
                }.onFailure { Log.w(TAG, "OnePlus split entry points not changed", it) }
            }, "powos-ww-split-entry").start()
        }

        private val OPLUS_SPLIT = listOf("secure" to "double_finger_split_screen_enable", "system" to "recommender_split_screen_enable")
    }
}
