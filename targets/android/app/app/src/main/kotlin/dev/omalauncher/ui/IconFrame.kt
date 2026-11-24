package dev.omalauncher.ui

import kotlin.math.abs
import kotlin.math.max

/**
 * Finds an icon that already wears a frame of its own inside the frame the system gave it - a "tile in a tile". PowOS
 * draws every app icon in ONE shape (IconMask.drawShapedIcon); a picture that is a plain plate with a complete,
 * rounded-square icon sitting in its middle would show two rounded edges, one inside the other (the S25 "double
 * border", 2026-11-23). Two ways such a picture arrives, both generic (no vendor check):
 *
 * - an adaptive icon whose foreground is a whole legacy icon (its own rounded square, opaque) on a plain background
 *   layer: how a system wraps a pre-Android-8 icon into the adaptive format for every caller (One UI does; OxygenOS
 *   returns the legacy icon as it is);
 * - a plain picture that is already a tile (a squircle with a plain rim) with a second, distinct tile inside it.
 *
 * Either way the inner tile is the app's real icon: [wrappedLayer]/[framedPicture] return its box so the caller draws
 * just it, scaled to fill PowOS's one shape. Pure pixel logic on ARGB arrays (n x n), so JVM tests run it.
 */
object IconFrame {
    /** A box in analysis pixels. */
    data class Box(val x: Int, val y: Int, val w: Int, val h: Int) {
        val side get() = max(w, h)
        val cx get() = x + w / 2f
        val cy get() = y + h / 2f
    }

    /** How solid (row-span filled) a box must be to be a tile of its own: a squircle ~0.96, a rounded square more, a circle ~0.79. */
    private const val SOLID = 0.88f

    /** How far from square a tile may be, as a share of its longer side. */
    private const val SQUARE = 0.06f

    /** The inner tile's side, as a share of the frame around it: smaller is a glyph, larger shows no second edge. */
    private const val MIN_INNER = 0.45f
    private const val MAX_INNER = 0.94f

    /** Colour distance (largest channel difference) under which two pixels are the same plate. */
    private const val SAME = 28

    /** Share of a plate's pixels that must be its one colour (anti-aliasing, a faint gradient). */
    private const val PLAIN = 0.95f

    /**
     * An adaptive icon drawn [n] px square (its shown part, the layers' outer 1/6 cut off): [foreground] and
     * [background] (null: no layer) as ARGB. The foreground's box when it is a whole tile of its own on a plain (or
     * no) background - draw just that box, filling the shape -; null when the icon is a real adaptive one.
     */
    fun wrappedLayer(
        foreground: IntArray,
        background: IntArray?,
        n: Int,
    ): Box? {
        if (background != null && !plain(background, n, Box(0, 0, n, n))) return null
        val content = BooleanArray(n * n) { (foreground[it] ushr 24) > 128 }
        val inner = tile(content, n) ?: return null
        return inner.takeIf { it.side in (MIN_INNER * n).toInt()..(MAX_INNER * n).toInt() }
    }

    /**
     * A plain picture drawn [n] px square as ARGB: the box of the tile inside its tile, or null. The outer tile is the
     * picture's opaque box (square, solid); its rim (a band inside its edge) must be one plain colour; the inner tile
     * is what differs from that colour, itself square and solid.
     */
    fun framedPicture(
        argb: IntArray,
        n: Int,
    ): Box? {
        val outer = tile(BooleanArray(n * n) { (argb[it] ushr 24) > 200 }, n) ?: return null
        val rim = rimColour(argb, n, outer) ?: return null
        val content = BooleanArray(n * n) { i ->
            val x = i % n
            val y = i / n
            x in outer.x until outer.x + outer.w && y in outer.y until outer.y + outer.h &&
                (argb[i] ushr 24) > 200 && distance(argb[i], rim) > SAME
        }
        val inner = tile(content, n) ?: return null
        val share = inner.side.toFloat() / outer.side
        return inner.takeIf { share in MIN_INNER..MAX_INNER }
    }

    /** The box of [content] when it is a tile: about square and its rows filled edge to edge (holes inside don't count). */
    internal fun tile(
        content: BooleanArray,
        n: Int,
    ): Box? {
        val spans = (0 until n).mapNotNull { y -> span(content, n, y)?.let { (first, last) -> Triple(y, first, last) } }
        if (spans.isEmpty()) return null
        val x0 = spans.minOf { it.second }
        val x1 = spans.maxOf { it.third }
        val box = Box(x0, spans.first().first, x1 - x0 + 1, spans.last().first - spans.first().first + 1)
        val filled = spans.sumOf { (it.third - it.second + 1).toLong() }
        if (abs(box.w - box.h) > SQUARE * box.side) return null
        return box.takeIf { filled >= SOLID * box.w * box.h }
    }

    /** Row [y]'s first and last content pixel, or null when it has none. */
    private fun span(
        content: BooleanArray,
        n: Int,
        y: Int,
    ): Pair<Int, Int>? {
        val row = y * n
        val first = (0 until n).firstOrNull { content[row + it] } ?: return null
        return first to (n - 1 downTo first).first { content[row + it] }
    }

    /** The one colour of the band just inside [box]'s edge (corners skipped: they are the shape's curve), or null. */
    private fun rimColour(
        argb: IntArray,
        n: Int,
        box: Box,
    ): Int? {
        val band = max(1, box.side / 16)
        val skip = box.side / 4
        val samples = ArrayList<Int>()
        for (i in skip until box.side - skip) {
            for (d in band until 2 * band) {
                samples += argb[(box.y + d) * n + box.x + i]
                samples += argb[(box.y + box.h - 1 - d) * n + box.x + i]
                samples += argb[(box.y + i) * n + box.x + d]
                samples += argb[(box.y + i) * n + box.x + box.w - 1 - d]
            }
        }
        if (samples.isEmpty()) return null
        val c = mean(samples)
        return c.takeIf { samples.count { distance(it, c) <= SAME } >= PLAIN * samples.size }
    }

    /** Whether [box] of [argb] is one opaque colour (or fully clear: no plate at all). */
    private fun plain(
        argb: IntArray,
        n: Int,
        box: Box,
    ): Boolean {
        val px = ArrayList<Int>(box.w * box.h)
        for (y in box.y until box.y + box.h) for (x in box.x until box.x + box.w) px += argb[y * n + x]
        if (px.all { (it ushr 24) < 16 }) return true
        if (px.count { (it ushr 24) > 240 } < PLAIN * px.size) return false
        val c = mean(px)
        return px.count { distance(it, c) <= SAME } >= PLAIN * px.size
    }

    private fun mean(px: List<Int>): Int {
        var r = 0L
        var g = 0L
        var b = 0L
        for (p in px) {
            r += (p shr 16) and 0xff
            g += (p shr 8) and 0xff
            b += p and 0xff
        }
        val k = px.size
        return (0xff shl 24) or ((r / k).toInt() shl 16) or ((g / k).toInt() shl 8) or (b / k).toInt()
    }

    private fun distance(
        a: Int,
        b: Int,
    ) = maxOf(
        abs(((a shr 16) and 0xff) - ((b shr 16) and 0xff)),
        abs(((a shr 8) and 0xff) - ((b shr 8) and 0xff)),
        abs((a and 0xff) - (b and 0xff)),
    )
}
