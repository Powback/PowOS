package dev.omalauncher.shell

import android.content.Context
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import andro.marchy.WebWindowSource

/**
 * N3a of docs/WEB_WINDOWS.md "Native-glued windows": a Linux web window's popups (Steam's menus, xdg_popups, X11
 * override-redirect windows) as surfaces of their own, kwin 0063. The host says "web <id> 1" for each Linux web window
 * ([WebWindowSource.webPopups]); KWin then sends "popup <id> <popup-id> x y w h" / "popup-gone" and offers each popup's
 * buffers on the daemon's surface <popup-id>.
 *
 * This is the log-only consumer N3b builds on: every message and every buffer arrival is recorded ([PopupBook]); the
 * buffers go to an offscreen [ImageReader] (as [LinuxSelftest]'s), never on screen - KWin still draws the popup into its
 * window in mode 1, so nothing the user sees changes. Logcat tag [TAG] (tools/phone/verify/ww-popups.sh reads it):
 *   "popup P N at X,Y WxH (#k)"          each "popup" line (k = how many for N so far)
 *   "popup N buffer #b WxH +T ms"         the first buffer (T after its first "popup"), then every 60th
 *   "popup-gone P N: B buffers, M msgs, T ms"
 *   "popup N insane: ..."                 geometry no menu can have ([PopupBook.insane])
 *
 * HACK: N3a - buffers are read and dropped (offscreen reader) and a popup that grows past its first size keeps its first
 * buffers (KWin draws its top left into them). Real fix: N3b, a child layer per popup under the window's container
 * (not its crop), its consumer on that layer's Surface, re-made at a new size, input on it (docs/REMOTE-POWOS.md §4).
 */
internal class PopupLog(
    private val context: Context,
) {
    private val book = PopupBook()
    private val consumers = HashMap<Int, Consumer>()
    private val thread by lazy { HandlerThread("powos-popups-frames").apply { start() } }

    private class Consumer(
        val id: Int,
        val reader: ImageReader,
        val lane: ConsumerLane,
    ) {
        @Volatile var handle = 0L

        @Volatile var gone = false
    }

    /** Control channel's thread: KWin's "popup". The first one for an id starts its offscreen consumer. */
    fun popup(
        parent: Int,
        id: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
    ) {
        val now = SystemClock.uptimeMillis()
        val line = synchronized(book) { book.popup(parent, id, x, y, w, h, now) }
        WindowLog.i(TAG, line)
        synchronized(book) { book.insane(id, screen()) }?.let { WindowLog.w(TAG, "popup $id insane: $it") }
        synchronized(consumers) {
            if (consumers.containsKey(id) || w <= 0 || h <= 0) return
            val usage = HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
            val reader = runCatching { ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, MAX_IMAGES, usage) }.getOrElse {
                WindowLog.w(TAG, "popup $id: no reader ${w}x$h: $it")
                return
            }
            val c = Consumer(id, reader, ConsumerLane("powos-popup-$id"))
            consumers[id] = c
            reader.setOnImageAvailableListener({ onImage(c, it) }, Handler(thread.looper))
            c.lane.run {
                WebWindowSource.configure(context)
                val handle = WebWindowSource.start(reader.surface, id, w, h)
                if (handle == 0L) {
                    WindowLog.w(TAG, "popup $id: consumer did not start")
                } else if (c.gone) {
                    WebWindowSource.stop(handle)
                } else {
                    c.handle = handle
                    WindowLog.i(TAG, "popup $id: consumer up, buffers ${w}x$h")
                }
            }
        }
    }

    /** Control channel's thread: KWin's "popup-gone": the record logged, its consumer stopped. */
    fun popupGone(
        parent: Int,
        id: Int,
    ) {
        val line = synchronized(book) { book.gone(parent, id, SystemClock.uptimeMillis()) }
        WindowLog.i(TAG, line)
        val c = synchronized(consumers) { consumers.remove(id) } ?: return
        c.gone = true
        c.lane.stop {
            val h = c.handle
            c.handle = 0
            WebWindowSource.stop(h)
            runCatching { c.reader.close() }
        }
    }

    /** Frames thread: one buffer of popup [c] arrived (dropped, counted). */
    private fun onImage(
        c: Consumer,
        r: ImageReader,
    ) {
        val img = runCatching { r.acquireNextImage() }.getOrNull() ?: return
        val w = img.width
        val h = img.height
        img.close()
        val line = synchronized(book) { book.buffer(c.id, w, h, SystemClock.uptimeMillis()) }
        line?.let { WindowLog.i(TAG, it) }
    }

    private fun screen(): Pair<Int, Int> {
        val m = context.resources.displayMetrics
        return m.widthPixels to m.heightPixels
    }

    companion object {
        const val TAG = "PowosPopups"
        private const val MAX_IMAGES = 3
    }
}

/**
 * What [PopupLog] records per popup surface: its parent, its last geometry, how many "popup" lines and buffers came and
 * when. Pure (JVM-tested, PopupBookTest); every call returns the log line it is worth.
 */
internal class PopupBook {
    class Rec(
        val parent: Int,
        val id: Int,
        val firstAt: Long,
    ) {
        var x = 0
        var y = 0
        var w = 0
        var h = 0
        var msgs = 0
        var buffers = 0
        var firstBufferMs = -1L
    }

    private val recs = LinkedHashMap<Int, Rec>()

    /** Popups that went, newest last (the last [KEEP_GONE]): what a check reads after the menu closed. */
    val gone = ArrayDeque<Rec>()

    fun live(): Collection<Rec> = recs.values

    fun popup(
        parent: Int,
        id: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        now: Long,
    ): String {
        val r = recs.getOrPut(id) { Rec(parent, id, now) }
        r.x = x
        r.y = y
        r.w = w
        r.h = h
        r.msgs++
        val reparent = if (r.parent != parent) " (was of ${r.parent})" else ""
        return "popup $parent $id at $x,$y ${w}x$h (#${r.msgs})$reparent"
    }

    /** A buffer of [id]: the line for the first one and every [EVERY]th, else null. */
    fun buffer(
        id: Int,
        w: Int,
        h: Int,
        now: Long,
    ): String? {
        val r = recs[id] ?: return "popup $id buffer ${w}x$h after its popup-gone (or before its popup)"
        r.buffers++
        if (r.firstBufferMs < 0) r.firstBufferMs = now - r.firstAt
        return if (r.buffers == 1 || r.buffers % EVERY == 0) "popup $id buffer #${r.buffers} ${w}x$h +${now - r.firstAt} ms" else null
    }

    fun gone(
        parent: Int,
        id: Int,
        now: Long,
    ): String {
        val r = recs.remove(id) ?: return "popup-gone $parent $id: never announced"
        gone.addLast(r)
        while (gone.size > KEEP_GONE) gone.removeFirst()
        val first = if (r.firstBufferMs >= 0) ", first buffer +${r.firstBufferMs} ms" else ", no buffer"
        return "popup-gone $parent $id: ${r.buffers} buffers, ${r.msgs} msgs, ${now - r.firstAt} ms$first"
    }

    /**
     * Why popup [id]'s geometry can't be a real popup's on a [screen] (w, h) px screen, or null: an empty or
     * larger-than-the-screen size, or a place a whole screen away from its window (the coordinates in the wrong space).
     */
    fun insane(
        id: Int,
        screen: Pair<Int, Int>,
    ): String? {
        val r = recs[id] ?: return null
        val (sw, sh) = screen
        val big = maxOf(sw, sh)
        return when {
            r.w <= 0 || r.h <= 0 -> "empty ${r.w}x${r.h}"
            r.w > big || r.h > big -> "${r.w}x${r.h} larger than the screen ${sw}x$sh"
            r.x < -big || r.y < -big || r.x > big || r.y > big -> "at ${r.x},${r.y}: a screen away from its window"
            else -> null
        }
    }

    companion object {
        const val EVERY = 60
        const val KEEP_GONE = 32
    }
}
