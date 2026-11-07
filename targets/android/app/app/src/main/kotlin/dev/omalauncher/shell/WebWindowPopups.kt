package dev.omalauncher.shell

import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Handler
import android.os.SystemClock
import android.view.AttachedSurfaceControl
import android.view.Surface
import android.view.SurfaceControl
import andro.marchy.WebWindowSource

/**
 * N3b of docs/WEB_WINDOWS.md "Native-glued windows": a Linux web window's popups (Steam's menus, xdg_popups, X11
 * override-redirect windows) shown as layers of their own, kwin 0063 mode 2 + 0064 ("popup-area", "dismiss").
 *
 * Each popup KWin exports ("popup <window> <popup> x y w h") is a buffer layer on home's surface ABOVE home's buffer
 * ([LAYER]): a window's container is cropped to its body and hangs under home's buffer (the page paints around the
 * body), so a popup there would be cut at the window's edge and hidden by the page outside it. Its place is the window's
 * body + (x, y) x the body's scale, set in the SAME transaction as the window's own geometry ([place], called from
 * WebWindows.place / fillScreen): it moves with its window and its page on the frame that moves them (N2's binding).
 * Cropped to the screen only. Its buffers come from KWin on the daemon's surface <popup> through the same consumer a
 * window's do. Touches on it are its window's (WebWindows.onTouch -> [at]): KWin's task finds the popup under the
 * finger. A tap on home outside the window and its popups says "dismiss" (KWin closes them, as a click outside would).
 * Main thread, except the consumers' starts and stops (each popup's own [ConsumerLane]).
 */
internal class WebWindowPopups(
    private val context: android.content.Context,
    private val home: () -> AttachedSurfaceControl?,
    private val main: Handler,
) {
    /** Where a window's task px land on screen: its body's top left (home's window px) and scale; hidden = not shown. */
    data class Origin(
        val left: Float,
        val top: Float,
        val scale: Float,
        val shown: Boolean,
    )

    private class Layer(
        val parent: Int,
        val id: Int,
        val bw: Int,
        val bh: Int,
        val sc: SurfaceControl,
        val surface: Surface,
    ) {
        val lane = ConsumerLane("powos-popup-$id")
        var geo = PopupGeo(0, 0, bw, bh)
        var screen = PopupBox.EMPTY
        var shown = false

        @Volatile var handle = 0L

        @Volatile var gone = false
    }

    private val layers = LinkedHashMap<Int, Layer>()
    private val origins = HashMap<Int, Origin>()
    private val book = PopupBook()
    private val areas = PopupAreas(main)

    /** KWin's "popup": made (or re-made when it grew past its buffers), placed at its window's origin now. */
    fun popup(
        parent: Int,
        id: Int,
        geo: PopupGeo,
    ) {
        WindowLog.i(PopupLog.TAG, book.popup(parent, id, geo, SystemClock.uptimeMillis()))
        book.insane(id, screenSize())?.let { WindowLog.w(PopupLog.TAG, "popup $id insane: $it") }
        var l = layers[id]
        if (l != null && (geo.w > l.bw || geo.h > l.bh)) {
            WindowLog.i(PopupLog.TAG, "popup $id grew to ${geo.w}x${geo.h} past its ${l.bw}x${l.bh} buffers: re-made")
            drop(l)
            l = null
        }
        val t = SurfaceControl.Transaction()
        val layer = l ?: make(t, parent, id, geo) ?: return
        layer.geo = geo
        place(t, layer, origins[parent])
        t.apply()
    }

    /** KWin's "popup-gone". */
    fun gone(
        parent: Int,
        id: Int,
    ) {
        WindowLog.i(PopupLog.TAG, book.gone(parent, id, SystemClock.uptimeMillis()))
        layers.remove(id)?.let { drop(it) }
    }

    /** Window [parent]'s place this frame ([o], null = not shown) into [t]: every popup of it with it, and its popup area. */
    fun place(
        t: SurfaceControl.Transaction,
        parent: Int,
        o: Origin?,
    ) {
        if (o == null) origins.remove(parent) else origins[parent] = o
        for (l in layers.values) if (l.parent == parent) place(t, l, o)
        if (o != null) areas.offer(parent, PopupPlace.area(o, screenSize()), SystemClock.uptimeMillis()) { p, box ->
            WebWindowSource.popupArea(p, box.l, box.t, box.r, box.b)
        }
    }

    /** The window (KWin id) whose shown popup is under home's window px ([x], [y]), topmost first; else null. */
    fun at(
        x: Float,
        y: Float,
    ): Int? = layers.values.reversed().firstOrNull { it.shown && it.screen.contains(x, y) }?.parent

    /** Windows (KWin ids) with a popup shown now. */
    fun parents(): Set<Int> = layers.values.filter { it.shown }.mapTo(HashSet()) { it.parent }

    /** Window [parent] went: its popups with it (KWin's "popup-gone" may never come after its close). */
    fun closed(parent: Int) {
        origins.remove(parent)
        areas.forget(parent)
        layers.values.filter { it.parent == parent }.forEach {
            layers.remove(it.id)
            drop(it)
        }
    }

    /** Home's surface made again: every popup onto the new one ([re], WebWindows.fullAgain's transaction). */
    fun reattach(re: SurfaceControl.Transaction) {
        val h = home() ?: return
        for (l in layers.values) {
            if (!l.sc.isValid) continue
            h.buildReparentTransaction(l.sc)?.let { re.merge(it) }
            re.setLayer(l.sc, LAYER)
        }
    }

    private fun make(
        t: SurfaceControl.Transaction,
        parent: Int,
        id: Int,
        geo: PopupGeo,
    ): Layer? {
        val h = home() ?: return null.also { WindowLog.w(PopupLog.TAG, "popup $id: home's window has no surface") }
        if (geo.w <= 0 || geo.h <= 0) return null
        val sc =
            SurfaceControl.Builder().setName("powos-ww-popup-$id").setBufferSize(geo.w, geo.h)
                .setFormat(PixelFormat.TRANSLUCENT).setHidden(true).build()
        val move = h.buildReparentTransaction(sc) ?: return null.also { sc.release() }
        t.merge(move)
        t.setLayer(sc, LAYER)
        val l = Layer(parent, id, geo.w, geo.h, sc, Surface(sc))
        layers[id] = l
        start(l)
        return l
    }

    /** [l]'s consumer on its own lane: KWin's popup surface <id> draws into its layer's buffers. */
    private fun start(l: Layer) {
        val id = l.id
        l.lane.run {
            WebWindowSource.configure(context)
            val handle = WebWindowSource.start(l.surface, id, l.bw, l.bh)
            when {
                handle == 0L -> WindowLog.w(PopupLog.TAG, "popup $id: consumer did not start")
                l.gone -> WebWindowSource.stop(handle)
                else -> {
                    l.handle = handle
                    WindowLog.i(PopupLog.TAG, "popup $id layer up, buffers ${l.bw}x${l.bh}")
                }
            }
        }
    }

    private fun place(
        t: SurfaceControl.Transaction,
        l: Layer,
        o: Origin?,
    ) {
        if (!l.sc.isValid) return
        val p = o?.let { PopupPlace.of(it, l.geo, screenSize()) }
        l.shown = p != null && !p.crop.isEmpty()
        l.screen = if (l.shown && p != null) p.screen else PopupBox.EMPTY
        if (p != null) {
            t.setPosition(l.sc, p.x, p.y)
            t.setScale(l.sc, p.scale, p.scale)
            t.setCrop(l.sc, Rect(p.crop.l, p.crop.t, p.crop.r, p.crop.b))
        }
        t.setVisibility(l.sc, l.shown)
    }

    private fun drop(l: Layer) {
        l.gone = true
        if (l.sc.isValid) SurfaceControl.Transaction().reparent(l.sc, null).apply()
        l.lane.stop {
            val h = l.handle
            l.handle = 0
            WebWindowSource.stop(h)
            main.post {
                l.surface.release()
                l.sc.release()
            }
        }
    }

    private fun screenSize(): Pair<Int, Int> {
        val b = context.getSystemService(android.view.WindowManager::class.java).maximumWindowMetrics.bounds
        return b.width() to b.height()
    }

    companion object {
        /** Over home's buffer and over a full-screen window (WebWindows.FULL_LAYER = 1 shl 20): a menu is on top. */
        const val LAYER = (1 shl 20) + 1
    }
}

/** A box in px (left, top, right, bottom exclusive): android.graphics.Rect-free, for the JVM tests. */
internal data class PopupBox(
    val l: Int,
    val t: Int,
    val r: Int,
    val b: Int,
) {
    fun isEmpty() = r <= l || b <= t

    fun contains(
        x: Float,
        y: Float,
    ) = !isEmpty() && x >= l && x < r && y >= t && y < b

    companion object {
        val EMPTY = PopupBox(0, 0, 0, 0)
    }
}

/** Where a popup's layer goes for its window's [WebWindowPopups.Origin]: pure, JVM-tested (WebWindowPopupsTest). */
internal object PopupPlace {
    /** Its layer's position and scale, its crop (layer px: the screen only, never the window) and its box on screen. */
    class Placement(
        val x: Float,
        val y: Float,
        val scale: Float,
        val crop: PopupBox,
        val screen: PopupBox,
    )

    /** Null when its window isn't shown. */
    fun of(
        o: WebWindowPopups.Origin,
        g: PopupGeo,
        screen: Pair<Int, Int>,
    ): Placement? {
        if (!o.shown || o.scale <= 0f) return null
        val s = o.scale
        val x = o.left + g.x * s
        val y = o.top + g.y * s
        val local = { v: Float, at: Float -> (v - at) / s }
        val crop =
            PopupBox(
                maxOf(0, Math.floor(local(0f, x).toDouble()).toInt()),
                maxOf(0, Math.floor(local(0f, y).toDouble()).toInt()),
                minOf(g.w, Math.ceil(local(screen.first.toFloat(), x).toDouble()).toInt()),
                minOf(g.h, Math.ceil(local(screen.second.toFloat(), y).toDouble()).toInt()),
            )
        val box =
            PopupBox(
                Math.round(x + crop.l * s),
                Math.round(y + crop.t * s),
                Math.round(x + crop.r * s),
                Math.round(y + crop.b * s),
            )
        return Placement(x, y, s, if (crop.isEmpty()) PopupBox.EMPTY else crop, box)
    }

    /** The screen in its window's task px (against the body's top left, unscaled): KWin's "popup-area" (0064). */
    fun area(
        o: WebWindowPopups.Origin,
        screen: Pair<Int, Int>,
    ): PopupBox {
        val s = if (o.scale > 0f) o.scale else 1f
        return PopupBox(
            Math.round((0f - o.left) / s),
            Math.round((0f - o.top) / s),
            Math.round((screen.first - o.left) / s),
            Math.round((screen.second - o.top) / s),
        )
    }
}

/**
 * Each window's popup area to KWin ("popup-area", 0064) only when it changed, at most every [GAP_MS] while its window
 * moves (a page slide moves it every frame): the last one always goes, [GAP_MS] after the one before. Main thread.
 */
internal class PopupAreas(
    private val main: Handler?,
) {
    private val sent = HashMap<Int, PopupBox>()
    private val pending = HashMap<Int, PopupBox>()
    private val at = HashMap<Int, Long>()

    fun offer(
        parent: Int,
        box: PopupBox,
        now: Long,
        send: (Int, PopupBox) -> Unit,
    ) {
        if (sent[parent] == box) {
            pending.remove(parent)
            return
        }
        val last = at[parent] ?: Long.MIN_VALUE / 2
        if (now - last >= GAP_MS) {
            sent[parent] = box
            at[parent] = now
            pending.remove(parent)
            send(parent, box)
            return
        }
        val scheduled = pending.containsKey(parent)
        pending[parent] = box
        if (!scheduled) main?.postDelayed({ flush(parent, SystemClock.uptimeMillis(), send) }, GAP_MS - (now - last))
    }

    /** The trailing area of [parent], if one waits. */
    fun flush(
        parent: Int,
        now: Long,
        send: (Int, PopupBox) -> Unit,
    ) {
        val box = pending.remove(parent) ?: return
        if (sent[parent] == box) return
        sent[parent] = box
        at[parent] = now
        send(parent, box)
    }

    fun forget(parent: Int) {
        sent.remove(parent)
        pending.remove(parent)
        at.remove(parent)
    }

    companion object {
        const val GAP_MS = 100L
    }
}
