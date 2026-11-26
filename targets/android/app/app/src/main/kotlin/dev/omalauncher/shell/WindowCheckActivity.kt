package dev.omalauncher.shell

import android.app.Activity
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The device window check's own app (tools/phone/verify/window-render.sh --hidden, the ship gate): a counter at 0 and a
 * "Tap" button, over a coloured grid (the check's content test wants a picture, not a flat fill). Hidden: no launcher
 * entry, not in recents, not exported (the check starts it as root), its own process (":windowcheck", App.onCreate does
 * nothing there) so home's process and main thread never carry it.
 *
 * Why (11-26, f1dfea35 and 11-23 d38c773e: false "WINDOWS BROKEN" that held every later ship): the check used to tap the
 * user's Calculator and judge its formula text, which had piled up ~130 chars of earlier checks' residue and became
 * unreadable after the tap. Now the state is the check's own and fresh each run: every launch is a new document task
 * (a new instance, the counter at 0, nothing persisted); a tap reaching the app makes the counter read 1. The check reads
 * both through `uiautomator dump --windows` by content description (window-render.py wcplan/wcjudge), never resource
 * ids (resource names may be shrunk in release builds).
 */
class WindowCheckActivity : Activity() {
    private var taps = 0
    private lateinit var count: TextView

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        val dp = { v: Float -> TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics) }
        count = TextView(this).apply {
            contentDescription = DESC_COUNT
            text = "0"
            setTextColor(Color.BLACK)
            setBackgroundColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 48f)
            gravity = Gravity.CENTER
            setPadding(dp(24f).toInt(), dp(8f).toInt(), dp(24f).toInt(), dp(8f).toInt())
        }
        val tap = Button(this).apply {
            contentDescription = DESC_TAP
            text = "Tap"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
            minWidth = dp(200f).toInt()
            minHeight = dp(120f).toInt()
            setOnClickListener { taps++; count.text = taps.toString() }
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            addView(count, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(tap, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(24f).toInt() })
        }
        setContentView(FrameLayout(this).apply {
            addView(Grid(this@WindowCheckActivity))
            addView(column, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        })
    }

    /** 8 x 12 cells, each its own hue: many colours and clear edges at any display size. */
    private class Grid(c: Context) : View(c) {
        private val paint = Paint()
        override fun onDraw(canvas: Canvas) {
            val cols = 8; val rows = 12
            val cw = width / cols.toFloat(); val rh = height / rows.toFloat()
            for (r in 0 until rows) for (k in 0 until cols) {
                paint.color = Color.HSVToColor(floatArrayOf(((r * cols + k) * 360f / (cols * rows) * 7) % 360f, 0.35f + 0.1f * (k % 3), 0.95f - 0.1f * (r % 2)))
                canvas.drawRect(k * cw, r * rh, (k + 1) * cw, (r + 1) * rh, paint)
            }
        }
    }

    companion object {
        /** window-render.py reads these content descriptions (wcplan/wcjudge). */
        const val DESC_COUNT = "powos-window-check-count"
        const val DESC_TAP = "powos-window-check-tap"
        const val PROCESS_SUFFIX = ":windowcheck"
    }
}
