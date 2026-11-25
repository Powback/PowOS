package dev.omalauncher.system

import android.content.Context
import android.graphics.Path
import android.graphics.Region
import android.graphics.RegionIterator
import android.os.Build
import android.view.Surface

/**
 * The camera's own hole inside its cutout box (display px, current rotation) - what the recording ring hugs
 * (chrome.tsx RecordingRing). The cutout's bounding rect is padded and often a plain rectangle from the top edge
 * (OnePlus Open: the cover's [521,595) x [0,126) round a 71 px hole, the inner's 126 px square round a 76 px one), so a
 * ring sized from it came out twice the camera ("the camera ring is too big compared to the camera size", 11-25).
 * In order: the hole the OEM declares (natural orientation, turned to this rotation) inside the box; else the cutout
 * path's filled shape in the box when it is a real shape (a circle/pill, not the box again); else the circle centred
 * in the box (its shorter side).
 */
object CameraHole {
    /** An OEM hole rect "l,t:r,b" (OPlus ro.oplus.display.*screenhole.position); null when unreadable. */
    fun parse(spec: String?): BarRect? {
        val n = spec?.split(',', ':')?.map { it.trim().toIntOrNull() ?: return null } ?: return null
        if (n.size != 4 || n[2] <= n[0] || n[3] <= n[1]) return null
        return BarRect(n[0], n[1], n[2], n[3])
    }

    /**
     * [hole] (natural orientation of a [natural] = w to h px display) in [rotation] (Surface.ROTATION_*), scaled by
     * [scale] (logical / physical px) - RotationUtils.transformPhysicalToLogicalCoordinates.
     */
    fun turn(
        hole: BarRect,
        rotation: Int,
        natural: Pair<Int, Int>,
        scale: Float = 1f,
    ): BarRect {
        val (w, h) = natural
        fun pt(
            x: Int,
            y: Int,
        ): Pair<Int, Int> =
            when (rotation) {
                Surface.ROTATION_90 -> y to w - x
                Surface.ROTATION_180 -> w - x to h - y
                Surface.ROTATION_270 -> h - y to x
                else -> x to y
            }
        val (ax, ay) = pt(hole.l, hole.t)
        val (bx, by) = pt(hole.r, hole.b)
        fun s(v: Int) = Math.round(v * scale)
        return BarRect(s(minOf(ax, bx)), s(minOf(ay, by)), s(maxOf(ax, bx)), s(maxOf(ay, by)))
    }

    /** The hole in [box]: a [declared] one inside it (2 px slack), else [traced] (the path's shape), else the centred circle. */
    fun inside(
        box: BarRect,
        declared: List<BarRect>,
        traced: BarRect?,
    ): BarRect {
        val slack = 2
        declared.firstOrNull { it.l >= box.l - slack && it.t >= box.t - slack && it.r <= box.r + slack && it.b <= box.b + slack }?.let { return it }
        if (traced != null && traced.r > traced.l && traced.b > traced.t) return traced
        val d = minOf(box.r - box.l, box.b - box.t)
        val x = box.l + (box.r - box.l - d) / 2
        val y = box.t + (box.b - box.t - d) / 2
        return BarRect(x, y, x + d, y + d)
    }

    /** The share of [bounds] a shape fills (area of its rects / its bounds): 1 = a rectangle, ~0.79 = a circle. */
    fun fill(
        rects: List<BarRect>,
        bounds: BarRect,
    ): Float {
        val whole = (bounds.r - bounds.l).toLong() * (bounds.b - bounds.t)
        if (whole <= 0) return 1f
        return rects.sumOf { (it.r - it.l).toLong() * (it.b - it.t) }.toFloat() / whole
    }

    /** OPlus' declared holes: the main (inner) display's and the secondary (cover) one's. */
    private val OEM_PROPS = listOf("ro.oplus.display.screenhole.positon", "ro.oplus.display.screenhole.position", "ro.oplus.display.secondary.screenhole.position")

    private val sysPropGet by lazy {
        runCatching { Class.forName("android.os.SystemProperties").getMethod("get", String::class.java, String::class.java) }.getOrNull()
    }

    private fun prop(name: String): String? = runCatching { sysPropGet?.invoke(null, name, "") as String? }.getOrNull()?.takeIf { it.isNotBlank() }

    /** The camera's hole in [box] on [context]'s display (display px, its current rotation). */
    fun read(
        context: Context,
        box: BarRect,
    ): BarRect = inside(box, declared(context), traced(context, box))

    /** The OEM's declared holes turned to the display's current rotation and resolution. */
    @Suppress("DEPRECATION")
    private fun declared(context: Context): List<BarRect> {
        val display = runCatching { context.display }.getOrNull() ?: return emptyList()
        val holes = OEM_PROPS.mapNotNull { parse(prop(it)) }
        if (holes.isEmpty()) return emptyList()
        val mode = display.mode
        val real = android.graphics.Point().also { display.getRealSize(it) }
        val natural = maxOf(mode.physicalWidth, mode.physicalHeight)
        val scale = if (natural > 0) maxOf(real.x, real.y).toFloat() / natural else 1f
        return holes.map { turn(it, display.rotation, mode.physicalWidth to mode.physicalHeight, scale) }
    }

    /** The cutout path's filled shape inside [box] (API 31+), when it is a real shape rather than the box again. */
    private fun traced(
        context: Context,
        box: BarRect,
    ): BarRect? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        val path: Path = runCatching { context.display?.cutout?.cutoutPath }.getOrNull() ?: return null
        val clip = Region(box.l, box.t, box.r, box.b)
        val region = Region().apply { setPath(path, clip) }
        if (region.isEmpty) return null
        val rects = mutableListOf<BarRect>()
        val r = android.graphics.Rect()
        val it = RegionIterator(region)
        while (it.next(r)) rects += BarRect(r.left, r.top, r.right, r.bottom)
        val b = region.bounds
        val bounds = BarRect(b.left, b.top, b.right, b.bottom)
        // A plain rectangle (the box, or the top-edge strip OEMs draw) says nothing about where the hole is.
        return bounds.takeIf { fill(rects, it) < 0.95f }
    }
}
