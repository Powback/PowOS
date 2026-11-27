package dev.omalauncher.livetext

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Live Text (docs/research/live-text.md): text in a picture becomes selectable. Opened from the share sheet ("Copy
 * text", any image) or as "Scan text" (no image: the camera app takes one through ACTION_IMAGE_CAPTURE, then it's read).
 * The picture fills the window, every word read gets a soft box; drag across words to select a run, tap a word for its
 * line, "All" for everything. The bar copies, shares, searches or translates the selection; chips under it open the
 * phone numbers, links, emails and addresses found. Reads on the device first (ML Kit, offline), then asks PowStation's
 * PaddleOCR-VL and swaps in its read when it saw more. No root, no permission (the camera app takes the photo).
 *
 * Verify hook: EXTRA_REPORT logs the read as JSON under the "LiveText" tag (tools/phone/verify/live-text.sh).
 */
class LiveTextActivity : Activity() {
    private lateinit var page: ImageTextView
    private lateinit var status: TextView
    private lateinit var chips: LinearLayout
    private var shot: Uri? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.BLACK) }
        page = ImageTextView(this) { onSelection() }
        status = TextView(this).apply { setTextColor(Color.LTGRAY); setPadding(dp(16), dp(8), dp(16), dp(4)); textSize = 13f }
        chips = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(dp(8), 0, dp(8), 0) }
        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER; setPadding(0, dp(4), 0, dp(12)) }
        for ((label, act) in listOf("All" to ::selectAll, "Copy" to ::copy, "Share" to ::share, "Search" to ::search, "Translate" to ::translate)) {
            bar.addView(button(label) { act() })
        }
        root.addView(page, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(status)
        root.addView(HorizontalScrollView(this).apply { addView(chips) })
        root.addView(bar)
        setContentView(root)
        root.setOnApplyWindowInsetsListener { v, ins ->
            @Suppress("DEPRECATION")
            v.setPadding(0, ins.systemWindowInsetTop, 0, ins.systemWindowInsetBottom)
            ins
        }

        val image = imageUri(intent)
        when {
            image != null -> load(image)
            savedInstanceState?.getString(STATE_SHOT) != null -> shot = Uri.parse(savedInstanceState.getString(STATE_SHOT))
            else -> takePhoto()
        }
    }

    override fun onSaveInstanceState(out: Bundle) {
        super.onSaveInstanceState(out)
        shot?.let { out.putString(STATE_SHOT, it.toString()) }
    }

    private fun imageUri(i: Intent): Uri? =
        when (i.action) {
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") i.getParcelableExtra(Intent.EXTRA_STREAM)
            Intent.ACTION_VIEW -> i.data
            else -> null
        }

    /** The camera app takes the picture into our cache/share/ (FileProvider "share"); onActivityResult reads it. */
    private fun takePhoto() {
        val dir = File(cacheDir, "share/livetext").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val f = File(dir, "scan-${System.currentTimeMillis()}.jpg")
        val uri = FileProvider.getUriForFile(this, "$packageName.files", f)
        shot = uri
        val cam =
            Intent(MediaStore.ACTION_IMAGE_CAPTURE)
                .putExtra(MediaStore.EXTRA_OUTPUT, uri)
                .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        runCatching { startActivityForResult(cam, REQ_CAMERA) }.onFailure {
            toast("No camera app takes photos for other apps")
            finish()
        }
    }

    @Deprecated("Activity result API: this is a plain Activity")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_CAMERA) return
        val uri = shot
        if (resultCode != RESULT_OK || uri == null) return finish()
        load(uri)
    }

    private fun load(uri: Uri) {
        status.text = "Reading text..."
        val report = intent.getBooleanExtra(EXTRA_REPORT, false)
        val remote = intent.getBooleanExtra(EXTRA_POWSTATION, true)
        Thread {
            val bmp = runCatching { decode(uri) }.getOrNull()
            if (bmp == null) {
                runOnUiThread { toast("Can't open that image"); finish() }
                return@Thread
            }
            runOnUiThread { page.setImage(bmp) }
            val t0 = System.nanoTime()
            val local = runCatching { LiveTextOcr.device(bmp) }.onFailure { Log.w(TAG, "device OCR", it) }.getOrNull()
            val localMs = (System.nanoTime() - t0) / 1_000_000
            if (local != null) runOnUiThread { show(local) }
            if (report) log("device", local, localMs)
            if (!remote) {
                if (report) runOnUiThread { finish() }
                return@Thread
            }
            val t1 = System.nanoTime()
            val hq = LiveTextOcr.powstation(bmp)
            val hqMs = (System.nanoTime() - t1) / 1_000_000
            if (report) {
                log("powstation", hq, hqMs)
                runOnUiThread { finish() } // the check is done: leave the phone as it was
                return@Thread
            }
            // The pool's read wins when it saw more text than the device (handwriting, other scripts, small print).
            if (hq != null && hq.text.count { !it.isWhitespace() } > (local?.text?.count { !it.isWhitespace() } ?: 0)) {
                runOnUiThread { show(hq) }
            } else if (local == null || local.words.isEmpty()) {
                runOnUiThread { status.text = if (local == null) "Couldn't read this image" else "No text found" }
            }
        }.start()
    }

    private fun decode(uri: Uri): Bitmap {
        val src = ImageDecoder.createSource(contentResolver, uri)
        return ImageDecoder.decodeBitmap(src) { d, info, _ ->
            d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val m = maxOf(info.size.width, info.size.height)
            if (m > 3000) d.setTargetSampleSize((m + 2999) / 3000)
        }
    }

    private fun log(
        engine: String,
        read: Read?,
        ms: Long,
    ) {
        val o = JSONObject().put("engine", engine).put("ms", ms).put("ok", read != null)
        if (read != null) {
            o.put("text", read.text).put("words", read.words.size)
            o.put("entities", JSONArray(Entities.find(read.text).map { JSONObject().put("kind", it.kind.name).put("text", it.text).put("uri", it.uri) }))
        }
        Log.i(TAG, "result " + o)
    }

    private fun show(read: Read) {
        page.setRead(read)
        status.text =
            if (read.words.isEmpty()) "No text found"
            else "Drag across text to select it" + if (read.engine == "powstation") " (read by PowStation)" else ""
        chips.removeAllViews()
        for (e in Entities.find(read.text)) {
            val icon = when (e.kind) { Entity.Kind.PHONE -> "Call"; Entity.Kind.URL -> "Open"; Entity.Kind.EMAIL -> "Mail"; Entity.Kind.ADDRESS -> "Map" }
            chips.addView(button("$icon ${e.text}") { open(Intent(if (e.kind == Entity.Kind.PHONE) Intent.ACTION_DIAL else Intent.ACTION_VIEW, Uri.parse(e.uri))) })
        }
    }

    private fun onSelection() {
        val s = page.selected()
        status.text = if (s.isEmpty()) "Drag across text to select it" else s.replace('\n', ' ').take(120)
    }

    /** The selection, or everything when nothing is selected. */
    private fun text(): String = page.selected().ifEmpty { page.read?.text.orEmpty() }

    private fun selectAll() = page.selectAll()

    private fun copy() {
        val t = text().ifEmpty { return toast("No text") }
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Text from image", t))
        if (Build.VERSION.SDK_INT < 33) toast("Copied")
    }

    private fun share() {
        val t = text().ifEmpty { return toast("No text") }
        open(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, t), null))
    }

    private fun search() {
        val t = text().ifEmpty { return toast("No text") }
        open(Intent(Intent.ACTION_WEB_SEARCH).putExtra(MediaStore.EXTRA_MEDIA_TITLE, t).putExtra("query", t)) ||
            open(Intent(Intent.ACTION_VIEW, Uri.parse("https://duckduckgo.com/?q=" + Uri.encode(t))))
    }

    /** ACTION_TRANSLATE (Android 13+: the installed translator), else the text selection's "Translate" handlers
     *  (ACTION_PROCESS_TEXT), else the web. */
    private fun translate() {
        val t = text().ifEmpty { return toast("No text") }
        open(Intent(Intent.ACTION_TRANSLATE).putExtra(Intent.EXTRA_TEXT, t)) ||
            open(Intent.createChooser(Intent(Intent.ACTION_PROCESS_TEXT).setType("text/plain").putExtra(Intent.EXTRA_PROCESS_TEXT, t).putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true), "Translate")) ||
            open(Intent(Intent.ACTION_VIEW, Uri.parse("https://translate.google.com/?sl=auto&op=translate&text=" + Uri.encode(t))))
    }

    private fun open(i: Intent): Boolean = runCatching { startActivity(i) }.isSuccess

    private fun button(
        label: String,
        on: () -> Unit,
    ) = TextView(this).apply {
        text = label
        setTextColor(Color.WHITE)
        textSize = 14f
        setPadding(dp(14), dp(8), dp(14), dp(8))
        background = android.graphics.drawable.GradientDrawable().apply { cornerRadius = dp(18).toFloat(); setColor(0x33FFFFFF) }
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(4), dp(4), dp(4), dp(4)) }
        setOnClickListener { on() }
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        const val TAG = "LiveText"
        const val EXTRA_REPORT = "dev.omalauncher.livetext.REPORT"
        const val EXTRA_POWSTATION = "dev.omalauncher.livetext.POWSTATION"
        private const val STATE_SHOT = "shot"
        private const val REQ_CAMERA = 41

        fun scan(ctx: Context) = ctx.startActivity(Intent(ctx, LiveTextActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

/** The picture fitted to the view with a box per word; drag selects a run of words, a tap selects the word's line. */
private class ImageTextView(
    ctx: Context,
    private val changed: () -> Unit,
) : View(ctx) {
    private var bmp: Bitmap? = null
    var read: Read? = null
        private set
    private var from = -1
    private var to = -1
    private val dst = RectF()
    private val box = RectF()
    private val boxPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x26FFFFFF; style = Paint.Style.FILL }
    private val selPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x6633A1FF; style = Paint.Style.FILL }
    private val dim = Paint().apply { color = 0x55000000 }

    fun setImage(b: Bitmap) {
        bmp = b
        invalidate()
    }

    fun setRead(r: Read) {
        read = r
        from = -1
        to = -1
        invalidate()
    }

    fun selected(): String = read?.takeIf { from >= 0 && to >= 0 }?.textOf(from, to).orEmpty()

    fun selectAll() {
        val r = read ?: return
        if (r.words.isEmpty()) return
        from = 0
        to = r.words.size - 1
        invalidate()
        changed()
    }

    override fun onDraw(c: Canvas) {
        val b = bmp ?: return
        val k = minOf(width / b.width.toFloat(), height / b.height.toFloat())
        val w = b.width * k
        val h = b.height * k
        dst.set((width - w) / 2, (height - h) / 2, (width + w) / 2, (height + h) / 2)
        c.drawBitmap(b, null, dst, null)
        val r = read ?: return
        if (r.words.isNotEmpty()) c.drawRect(dst, dim)
        val a = minOf(from, to)
        val z = maxOf(from, to)
        r.words.forEachIndexed { i, wd ->
            box.set(dst.left + wd.l * w, dst.top + wd.t * h, dst.left + wd.r * w, dst.top + wd.b * h)
            box.inset(-3f, -3f)
            c.drawRoundRect(box, 6f, 6f, if (from >= 0 && i in a..z) selPaint else boxPaint)
        }
    }

    private var downAt = -1
    private var moved = false

    override fun onTouchEvent(e: MotionEvent): Boolean {
        val r = read ?: return false
        if (dst.width() <= 0f) return false
        val x = (e.x - dst.left) / dst.width()
        val y = (e.y - dst.top) / dst.height()
        val i = r.wordAt(x, y)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downAt = i
                moved = false
                parent?.requestDisallowInterceptTouchEvent(true)
            }
            MotionEvent.ACTION_MOVE -> if (downAt >= 0 && i >= 0 && (i != downAt || moved)) {
                moved = true
                from = downAt
                to = i
                invalidate()
                changed()
            }
            MotionEvent.ACTION_UP -> {
                if (!moved) {
                    if (downAt >= 0) {
                        val line = r.lineRange(downAt)
                        from = line.first
                        to = line.last
                    } else {
                        from = -1
                        to = -1
                    }
                    invalidate()
                    changed()
                }
                downAt = -1
            }
        }
        return true
    }
}
