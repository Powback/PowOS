package dev.omalauncher.assist

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import dev.omalauncher.R
import java.io.File
import kotlin.math.abs

/**
 * PowOS AI's live mode (the assistant, assist.tsx): the screen, a frame a second, while it's on. PowOS AI answers turn
 * by turn, not to a video, so what goes with a question is a filmstrip - the last moments that differ, downscaled and
 * tiled into one image, oldest first - which [filmstrip] saves where PowOS sees it.
 *
 * Android's own screen capture (MediaProjection): it asks the user once per live session ([LiveConsentActivity]); the
 * capture runs in a foreground service ([LiveCaptureService]), as Android requires.
 */
object LiveCapture {
    private const val TAG = "PowosLive"

    /** Frames kept: the filmstrip's cells. */
    const val FRAMES = 8

    /** A frame's width in the filmstrip (px; height follows the screen's shape). */
    private const val FRAME_W = 320

    /** How different (mean absolute difference of a 32x32 gray thumbnail, 0-255) a frame must be from the last kept. */
    private const val CHANGED = 6.0

    private class Frame(
        val bitmap: Bitmap,
        val sig: IntArray,
        val time: Long,
    )

    private val frames = ArrayDeque<Frame>()

    @Volatile
    var running = false
        private set

    /** Live mode's state changed (the bridge tells the page). */
    var onChange: ((Boolean) -> Unit)? = null

    fun start(context: Context) {
        if (running) return
        context.startActivity(Intent(context, LiveConsentActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun stop(context: Context) {
        context.stopService(Intent(context, LiveCaptureService::class.java))
    }

    internal fun setRunning(on: Boolean) {
        running = on
        if (!on) synchronized(frames) { frames.clear() }
        onChange?.invoke(on)
    }

    /** A captured screen: kept if it differs from the last one kept (a still screen isn't 8 copies of itself). */
    internal fun add(screen: Bitmap) {
        val h = FRAME_W * screen.height / screen.width
        val small = Bitmap.createScaledBitmap(screen, FRAME_W, h, true)
        val sig = signature(small)
        synchronized(frames) {
            val last = frames.lastOrNull()
            if (last != null && difference(last.sig, sig) < CHANGED) {
                small.recycle()
                return
            }
            frames.addLast(Frame(small, sig, System.currentTimeMillis()))
            while (frames.size > FRAMES) frames.removeFirst().bitmap.recycle()
        }
    }

    /**
     * The frames kept so far as one image (4 across, oldest top-left, each with its age), saved in PowOS's sight (the
     * run dir, /run/powos-app); its path in PowOS, or null with nothing captured yet.
     */
    fun filmstrip(context: Context): String? {
        val list = synchronized(frames) { frames.map { it } }
        if (list.isEmpty()) return null
        val w = list[0].bitmap.width
        val h = list[0].bitmap.height
        val cols = minOf(4, list.size)
        val rows = (list.size + cols - 1) / cols
        val gap = 4
        val out = Bitmap.createBitmap(cols * w + (cols - 1) * gap, rows * h + (rows - 1) * gap, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawColor(Color.BLACK)
        val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textSize = 22f; setShadowLayer(3f, 0f, 0f, Color.BLACK) }
        val now = System.currentTimeMillis()
        list.forEachIndexed { i, f ->
            val x = (i % cols) * (w + gap).toFloat()
            val y = (i / cols) * (h + gap).toFloat()
            canvas.drawBitmap(f.bitmap, x, y, null)
            canvas.drawText("${i + 1} · -${(now - f.time) / 1000}s", x + 8, y + 28, label)
        }
        val dir = File(context.filesDir, "run/powos-ai-shared").apply { mkdirs() }
        val name = "live-$now.jpg"
        File(dir, name).outputStream().use { out.compress(Bitmap.CompressFormat.JPEG, 80, it) }
        out.recycle()
        return "/run/powos-app/powos-ai-shared/$name"
    }

    /** How many frames are kept now (the page shows it). */
    fun count() = synchronized(frames) { frames.size }

    private fun signature(b: Bitmap): IntArray {
        val t = Bitmap.createScaledBitmap(b, 32, 32, true)
        val px = IntArray(32 * 32)
        t.getPixels(px, 0, 32, 0, 0, 32, 32)
        t.recycle()
        return IntArray(px.size) { val c = px[it]; ((c shr 16 and 0xff) * 3 + (c shr 8 and 0xff) * 6 + (c and 0xff)) / 10 }
    }

    private fun difference(
        a: IntArray,
        b: IntArray,
    ) = a.indices.sumOf { abs(a[it] - b[it]) }.toDouble() / a.size

    internal fun log(msg: String) = Log.i(TAG, msg)
}

/** Asks Android for the screen (its own consent dialog), then starts the capture with the answer. Invisible. */
class LiveConsentActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pm = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(pm.createScreenCaptureIntent(), REQUEST)
    }

    @Deprecated("startActivityForResult's answer", ReplaceWith(""))
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST && resultCode == RESULT_OK && data != null) {
            startForegroundService(Intent(this, LiveCaptureService::class.java).putExtra(LiveCaptureService.EXTRA_RESULT, data))
        } else {
            LiveCapture.setRunning(false)
        }
        finish()
    }

    private companion object {
        const val REQUEST = 1
    }
}

/** The capture itself: a virtual display mirroring the screen into an image reader, read once a second. */
class LiveCaptureService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private val thread = HandlerThread("powos-live").apply { start() }
    private val handler = Handler(thread.looper)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "PowOS AI live", NotificationManager.IMPORTANCE_LOW))
        val note =
            Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("PowOS AI sees your screen")
                .setContentText("Live mode: a frame a second, for your questions")
                .setOngoing(true)
                .build()
        startForeground(1, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        @Suppress("DEPRECATION")
        val data = intent?.getParcelableExtra<Intent>(EXTRA_RESULT) ?: return START_NOT_STICKY.also { stopSelf() }
        val pm = getSystemService(MediaProjectionManager::class.java)
        val p = pm.getMediaProjection(Activity.RESULT_OK, data) ?: return START_NOT_STICKY.also { stopSelf() }
        projection = p
        p.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() = stopSelf()
            },
            handler,
        )
        val metrics = resources.displayMetrics
        // A third of the screen's size: plenty for a 320-px frame, a ninth of the pixels to read.
        val w = metrics.widthPixels / 3
        val h = metrics.heightPixels / 3
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        reader = r
        display = p.createVirtualDisplay("powos-live", w, h, metrics.densityDpi / 3, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, handler)
        LiveCapture.setRunning(true)
        LiveCapture.log("live: capturing ${w}x$h")
        handler.post(object : Runnable {
            override fun run() {
                grab()
                handler.postDelayed(this, INTERVAL_MS)
            }
        })
        return START_NOT_STICKY
    }

    private fun grab() {
        val image = reader?.acquireLatestImage() ?: return
        image.use {
            val plane = it.planes[0]
            val rowPixels = plane.rowStride / plane.pixelStride
            val full = Bitmap.createBitmap(rowPixels, it.height, Bitmap.Config.ARGB_8888)
            full.copyPixelsFromBuffer(plane.buffer)
            val screen = Bitmap.createBitmap(full, 0, 0, it.width, it.height)
            LiveCapture.add(screen)
            if (screen !== full) screen.recycle()
            full.recycle()
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        display?.release()
        reader?.close()
        projection?.stop()
        thread.quitSafely()
        LiveCapture.setRunning(false)
        super.onDestroy()
    }

    companion object {
        const val EXTRA_RESULT = "result"
        private const val CHANNEL = "powos-live"
        private const val INTERVAL_MS = 1000L
    }
}
