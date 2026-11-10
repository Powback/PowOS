package dev.omalauncher.shell

import java.util.concurrent.atomic.AtomicReference

/**
 * A pool of one: an item made ahead of the moment it is needed, refilled in the background after each take. The display
 * helper ([WebWindowsHost]) keeps one virtual display plus its placeholder touch device here, so an Android window's open
 * takes a ready display instead of making one (window-bench p5 11-10: Settings' window 42 waited 409 ms from "new
 * window" to its display before its app could start).
 *
 * - [size] sets the size the spare is kept at (the screen's; sent again on a fold/rotate) and fills it; a spare of
 *   another size is resized in place (taken out while it is, so a take never gets one mid-resize).
 * - [off] drops the spare and stops refilling (web windows off); [take] after it returns null.
 * - [take] hands the spare over (any thread; null when there is none: the caller makes one cold) and refills.
 *
 * Making, resizing and dropping run on [post]'s one thread (the helper's own, never its command loop: a make takes
 * ~400 ms and the loop carries touch lines).
 */
internal class SparePool<T : Any>(
    private val make: (w: Int, h: Int, dpi: Int) -> T?,
    private val resize: (T, w: Int, h: Int, dpi: Int) -> Unit,
    private val drop: (T) -> Unit,
    private val post: (() -> Unit) -> Unit,
) {
    private class Item<T>(val v: T, val w: Int, val h: Int, val dpi: Int)

    private val spare = AtomicReference<Item<T>?>(null)

    @Volatile private var want: IntArray? = null

    /** The spare's size from now on (and a fill if there is none). */
    fun size(
        w: Int,
        h: Int,
        dpi: Int,
    ) {
        want = intArrayOf(w, h, dpi)
        post { fit() }
    }

    /** No spare any more (and none made until the next [size]). */
    fun off() {
        want = null
        post { spare.getAndSet(null)?.let { drop(it.v) } }
    }

    /** The spare, or null; a new one is made in the background either way (while a size is set). */
    fun take(): T? {
        val it = spare.getAndSet(null)
        if (want != null) post { fill() }
        return it?.v
    }

    /** On the pool's thread or at the end: whatever is held, dropped now. */
    fun releaseAll() {
        want = null
        spare.getAndSet(null)?.let { drop(it.v) }
    }

    val ready: Boolean get() = spare.get() != null

    private fun fit() {
        val s = want ?: return
        val cur = spare.get() ?: return fill()
        if (cur.w == s[0] && cur.h == s[1] && cur.dpi == s[2]) return
        if (!spare.compareAndSet(cur, null)) return fill() // taken meanwhile
        resize(cur.v, s[0], s[1], s[2])
        if (want == null || !spare.compareAndSet(null, Item(cur.v, s[0], s[1], s[2]))) drop(cur.v)
    }

    private fun fill() {
        val s = want ?: return
        if (spare.get() != null) return
        val v = make(s[0], s[1], s[2]) ?: return
        // Turned off or filled while this one was being made: not kept.
        if (want == null || !spare.compareAndSet(null, Item(v, s[0], s[1], s[2]))) drop(v)
    }
}
