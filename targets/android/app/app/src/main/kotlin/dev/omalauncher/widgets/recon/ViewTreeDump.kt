package dev.omalauncher.widgets.recon

import android.graphics.Outline
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import android.widget.AdapterView
import android.widget.AnalogClock
import android.widget.Chronometer
import android.widget.CompoundButton
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextClock
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.roundToInt

/**
 * The widget as Android inflated it: every view with its class, id, bounds (dp, relative to the widget), and what
 * it shows - text with size, color and weight, images as PNGs, backgrounds, corner radii - plus `actions`, the
 * RemoteViews actions that target it ([RemoteViewsDump.byView]) and `owl`, the OWL node to recreate it with.
 * Public View APIs only. Main thread, after layout.
 */
internal class ViewTreeDump(
    private val images: Images,
    private val actions: Map<String, List<String>>,
) {
    private var density = 1f
    private val rootLoc = IntArray(2)
    private val loc = IntArray(2)

    fun dump(root: View): JSONObject {
        density = root.resources.displayMetrics.density
        root.getLocationInWindow(rootLoc)
        return node(root, 0)
    }

    private fun node(
        v: View,
        depth: Int,
    ): JSONObject {
        val o = JSONObject()
        o.put("class", if (v is ReconHostView) "AppWidgetHostView" else v.javaClass.name.removePrefix("android.widget.").removePrefix("android.view."))
        val id = idName(v)
        id?.let { o.put("id", it) }
        v.getLocationInWindow(loc)
        o.put("bounds", JSONArray(listOf(dp(loc[0] - rootLoc[0]), dp(loc[1] - rootLoc[1]), dp(v.width), dp(v.height))))
        when (v.visibility) {
            View.GONE -> return o.put("visibility", "gone")
            View.INVISIBLE -> o.put("visibility", "invisible")
        }
        if (v.alpha < 1f) o.put("alpha", round(v.alpha))
        v.contentDescription?.let { o.put("description", it.toString()) }
        if (v.hasOnClickListeners()) o.put("onClick", true)
        if (!v.isEnabled) o.put("enabled", false)
        if (v.paddingLeft or v.paddingTop or v.paddingRight or v.paddingBottom != 0) {
            o.put("padding", JSONArray(listOf(dp(v.paddingLeft), dp(v.paddingTop), dp(v.paddingRight), dp(v.paddingBottom))))
        }
        layoutParams(v, o)
        background(v.background, v, o)
        v.backgroundTintList?.let { o.put("backgroundTint", hex(it.defaultColor)) }
        if (v.clipToOutline) {
            val out = Outline()
            v.outlineProvider?.getOutline(v, out)
            o.put("cornerRadius", dp(out.radius))
        }
        id?.let { actions[it] }?.let { o.put("actions", JSONArray(it)) }
        when (v) {
            is TextView -> text(v, o)
            is ImageView -> image(v, o)
            is ProgressBar -> o.put("progress", v.progress).put("max", v.max).put("indeterminate", v.isIndeterminate).also { v.progressTintList?.let { t -> o.put("color", hex(t.defaultColor)) } }
        }
        o.put("owl", owl(v))
        if (v is AdapterView<*>) {
            o.put("items", v.adapter?.count ?: 0)
            if (v is AbsListView) o.put("firstVisible", v.firstVisiblePosition)
        }
        if (v is ViewGroup && depth < MAX_DEPTH) {
            (v as? LinearLayout)?.let { o.put("orientation", if (it.orientation == LinearLayout.VERTICAL) "vertical" else "horizontal").put("gravity", gravity(it.gravity)) }
            if (v.childCount > 0) o.put("children", JSONArray((0 until v.childCount).map { node(v.getChildAt(it), depth + 1) }))
        }
        return o
    }

    private fun text(
        v: TextView,
        o: JSONObject,
    ) {
        o.put("text", v.text?.toString() ?: "")
        o.put("textSizeSp", round(v.textSize / v.resources.displayMetrics.scaledDensity))
        o.put("color", hex(v.currentTextColor))
        v.typeface?.let { t ->
            o.put("weight", t.weight)
            if (t.isItalic) o.put("italic", true)
            if (t == Typeface.MONOSPACE) o.put("font", "mono")
            if (t == Typeface.SERIF) o.put("font", "serif")
        }
        o.put("align", gravity(v.gravity))
        if (v.maxLines in 1 until Int.MAX_VALUE) o.put("maxLines", v.maxLines)
        v.ellipsize?.let { o.put("ellipsize", it.name.lowercase()) }
        if (v.letterSpacing != 0f) o.put("letterSpacing", round(v.letterSpacing))
        if (v.isAllCaps) o.put("allCaps", true)
        if (v.shadowRadius > 0f) o.put("shadow", JSONObject().put("color", hex(v.shadowColor)).put("radius", dp(v.shadowRadius)))
        val compound = v.compoundDrawablesRelative
        listOf("start", "top", "end", "bottom").forEachIndexed { i, side ->
            compound[i]?.let { o.put("drawable_$side", images.drawable(it, 48, 48)) }
        }
        when (v) {
            is TextClock ->
                o.put("format12", v.format12Hour?.toString()).put("format24", v.format24Hour?.toString()).put("is24h", v.is24HourModeEnabled)
                    .also { v.timeZone?.let { tz -> o.put("timeZone", tz) } }
            is Chronometer -> o.put("chronometerBase", v.base).put("format", v.format).put("countDown", v.isCountDown)
            is CompoundButton -> o.put("checked", v.isChecked)
        }
    }

    private fun image(
        v: ImageView,
        o: JSONObject,
    ) {
        o.put("image", images.drawable(v.drawable, v.width, v.height) ?: JSONObject.NULL)
        o.put("scaleType", v.scaleType.name.lowercase())
        v.imageTintList?.let { o.put("tint", hex(it.defaultColor)) }
        if (v.colorFilter != null) o.put("colorFilter", true)
        if (v.imageAlpha < 255) o.put("imageAlpha", v.imageAlpha)
    }

    private fun background(
        d: Drawable?,
        v: View,
        o: JSONObject,
    ) {
        when (d) {
            null -> {}
            is ColorDrawable -> o.put("background", hex(d.color))
            is GradientDrawable -> {
                val g = JSONObject().put("kind", "shape")
                d.color?.let { g.put("color", hex(it.defaultColor)) }
                d.colors?.let { cs -> g.put("gradient", JSONArray(cs.map(::hex))) }
                g.put("cornerRadius", dp(d.cornerRadius))
                runCatching { d.cornerRadii }.getOrNull()?.let { r -> g.put("cornerRadii", JSONArray(r.map { dp(it) })) }
                g.put("shape", if (d.shape == GradientDrawable.OVAL) "oval" else "rect")
                o.put("background", g)
            }
            else -> o.put("background", JSONObject().put("kind", d.javaClass.simpleName).put("image", images.drawable(d, v.width, v.height)))
        }
    }

    private fun layoutParams(
        v: View,
        o: JSONObject,
    ) {
        val lp = v.layoutParams ?: return
        fun size(s: Int) =
            when (s) {
                ViewGroup.LayoutParams.MATCH_PARENT -> "match"
                ViewGroup.LayoutParams.WRAP_CONTENT -> "wrap"
                else -> dp(s)
            }
        o.put("layout", JSONArray(listOf(size(lp.width), size(lp.height))))
        if (lp is LinearLayout.LayoutParams && lp.weight > 0f) o.put("weight", round(lp.weight))
        if (lp is FrameLayout.LayoutParams && lp.gravity != -1) o.put("layoutGravity", gravity(lp.gravity))
        if (lp is ViewGroup.MarginLayoutParams && (lp.leftMargin or lp.topMargin or lp.rightMargin or lp.bottomMargin) != 0) {
            o.put("margin", JSONArray(listOf(dp(lp.leftMargin), dp(lp.topMargin), dp(lp.rightMargin), dp(lp.bottomMargin))))
        }
    }

    /** The OWL node that recreates [v] (README: Recreating an Android widget). */
    private fun owl(v: View): String =
        when (v) {
            is TextClock -> "Text + source now = clock (fmtTime)"
            is Chronometer -> "Text + source now = clock"
            is CompoundButton -> "Button (toggle)"
            is android.widget.Button -> "Button"
            is TextView -> "Text"
            is ImageView -> "Image"
            is ProgressBar -> "Progress"
            is AnalogClock -> "Canvas"
            is AdapterView<*> -> "for item in list (Column/Grid)"
            is LinearLayout -> if (v.orientation == LinearLayout.VERTICAL) "Column" else "Row"
            is ViewGroup -> "Box"
            else -> if (v.background != null) "Box (background)" else "Spacer"
        }

    private fun gravity(g: Int): String {
        val h =
            when (g and Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK) {
                Gravity.CENTER_HORIZONTAL -> "center"
                Gravity.END, Gravity.RIGHT -> "end"
                else -> "start"
            }
        val vert =
            when (g and Gravity.VERTICAL_GRAVITY_MASK) {
                Gravity.CENTER_VERTICAL -> "center"
                Gravity.BOTTOM -> "bottom"
                else -> "top"
            }
        return "$h $vert"
    }

    private fun idName(v: View): String? = if (v.id == View.NO_ID) null else runCatching { v.resources.getResourceEntryName(v.id) }.getOrNull()

    private fun dp(px: Int): Double = round(px / density)

    private fun dp(px: Float): Double = round(px / density)

    private fun round(x: Float): Double = if (x.isFinite()) (x * 10).roundToInt() / 10.0 else 0.0

    private companion object {
        const val MAX_DEPTH = 40
    }
}
