package dev.omalauncher.system

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import android.view.WindowManager
import dev.omalauncher.R
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The keyboard AI button's screen share: the no-setting way in on a phone without root ([KeyboardAccess]). The keyboard
 * asks for it from its own panel; [KeyboardShareConsentActivity] (invisible) shows only Android's consent dialog;
 * [KeyboardShareService] holds the projection (a mediaProjection foreground service, as Android requires) with its
 * virtual display paused - no surface, nothing composited - until [grab] attaches an ImageReader for one frame.
 * Once: stopped after that frame (or [KeyboardAccess.ONCE_TTL_MS] without one). Session: kept until the notification's
 * Stop, Android stopping it (screen lock on newer releases), or PowOS's process going.
 */
object KeyboardShare {
    private const val TAG = "PowosKbShare"

    @Volatile var mode = KeyboardAccess.ShareMode.ONCE
        internal set

    /** The consent was given and the service is starting (the keyboard's re-probe may beat it). */
    @Volatile internal var pendingSince = 0L

    @Volatile internal var service: KeyboardShareService? = null

    /** Whether a capture can use the share now (running, or just granted and starting). */
    fun available(now: Long = System.currentTimeMillis()): Boolean = service != null || (pendingSince > 0 && now - pendingSince < 5_000)

    /** One frame of the screen (full resolution), or null; waits up to ~2 s for a just-granted share to come up. */
    fun grab(): Bitmap? {
        val deadline = System.currentTimeMillis() + 2_000
        var s = service
        while (s == null && pendingSince > 0 && System.currentTimeMillis() < deadline) {
            Thread.sleep(50)
            s = service
        }
        s ?: return null
        val b = s.frame()
        if (KeyboardAccess.stopAfterGrab(mode)) s.stopSelf()
        return b
    }

    fun stop(context: Context) {
        pendingSince = 0
        context.stopService(Intent(context, KeyboardShareService::class.java))
    }

    internal fun log(msg: String) = Log.i(TAG, msg)
}

/** Android's screen-capture consent and nothing else (no window of its own): the answer starts [KeyboardShareService]. */
class KeyboardShareConsentActivity : Activity() {
    private var mode = KeyboardAccess.ShareMode.ONCE

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        mode = KeyboardAccess.mode(intent?.getStringExtra(KeyboardAccess.EXTRA_MODE))
        if (savedInstanceState != null) return
        val pm = getSystemService(MediaProjectionManager::class.java)
        // Android 14+: the entire screen only - a single shared app wouldn't be the one being typed into.
        val ask = if (Build.VERSION.SDK_INT >= 34) pm.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay()) else pm.createScreenCaptureIntent()
        @Suppress("DEPRECATION")
        startActivityForResult(ask, REQUEST)
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
            KeyboardShare.mode = mode
            KeyboardShare.pendingSince = System.currentTimeMillis()
            startForegroundService(Intent(this, KeyboardShareService::class.java).putExtra(KeyboardShareService.EXTRA_RESULT, data))
            KeyboardShare.log("share granted ($mode)")
        } else {
            KeyboardShare.log("share declined")
        }
        finish()
        overridePendingTransition(0, 0)
    }

    private companion object {
        const val REQUEST = 1
    }
}

/** Holds the projection; the virtual display has no surface between grabs. */
class KeyboardShareService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private val thread = HandlerThread("powos-kb-share").apply { start() }
    private val handler = Handler(thread.looper)
    private val expire = Runnable { if (KeyboardShare.mode == KeyboardAccess.ShareMode.ONCE) stopSelf() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Keyboard screen share", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 0, Intent(this, KeyboardShareService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val session = KeyboardShare.mode == KeyboardAccess.ShareMode.SESSION
        val note =
            Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(if (session) "Keyboard AI can see the screen" else "Keyboard AI: one screenshot")
                .setContentText(if (session) "Only when you tap ✨ - for this session" else "Taken on your ✨ tap, then stopped")
                .setOngoing(true)
                .addAction(Notification.Action.Builder(null, "Stop", stop).build())
                .build()
        startForeground(NOTE_ID, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        @Suppress("DEPRECATION")
        val data = intent?.getParcelableExtra<Intent>(EXTRA_RESULT)
        val p = data?.let { runCatching { getSystemService(MediaProjectionManager::class.java).getMediaProjection(Activity.RESULT_OK, it) }.getOrNull() }
        if (p == null) {
            KeyboardShare.pendingSince = 0
            stopSelf()
            return START_NOT_STICKY
        }
        projection?.stop()
        display?.release()
        reader?.close()
        projection = p
        p.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() = stopSelf()
            },
            handler,
        )
        val bounds = getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds
        val r = ImageReader.newInstance(bounds.width(), bounds.height(), PixelFormat.RGBA_8888, 2)
        reader = r
        // Paused (null surface): nothing is mirrored until a grab attaches the reader.
        display = p.createVirtualDisplay("powos-kb-share", bounds.width(), bounds.height(), resources.displayMetrics.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, null, null, handler)
        KeyboardShare.service = this
        KeyboardShare.pendingSince = 0
        handler.removeCallbacks(expire)
        handler.postDelayed(expire, KeyboardAccess.ONCE_TTL_MS)
        KeyboardShare.log("share up ${bounds.width()}x${bounds.height()} (${KeyboardShare.mode})")
        return START_NOT_STICKY
    }

    /** One frame: the reader attached, the first image it gets (a fresh composition), detached again. */
    fun frame(): Bitmap? {
        val r = reader ?: return null
        val d = display ?: return null
        val got = CountDownLatch(1)
        var shot: Bitmap? = null
        r.setOnImageAvailableListener({ ir ->
            if (got.count == 0L) return@setOnImageAvailableListener
            val image = runCatching { ir.acquireLatestImage() }.getOrNull() ?: return@setOnImageAvailableListener
            image.use {
                val plane = it.planes[0]
                val full = Bitmap.createBitmap(plane.rowStride / plane.pixelStride, it.height, Bitmap.Config.ARGB_8888)
                full.copyPixelsFromBuffer(plane.buffer)
                shot = if (full.width == it.width) full else Bitmap.createBitmap(full, 0, 0, it.width, it.height).also { full.recycle() }
            }
            got.countDown()
        }, handler)
        handler.post { d.surface = r.surface }
        got.await(1_500, TimeUnit.MILLISECONDS)
        handler.post {
            d.surface = null
            r.setOnImageAvailableListener(null, null)
        }
        if (shot == null) KeyboardShare.log("share: no frame within 1.5 s")
        return shot
    }

    override fun onDestroy() {
        if (KeyboardShare.service === this) KeyboardShare.service = null
        handler.removeCallbacksAndMessages(null)
        display?.release()
        reader?.close()
        projection?.stop()
        thread.quitSafely()
        KeyboardShare.log("share stopped")
        super.onDestroy()
    }

    companion object {
        const val EXTRA_RESULT = "result"
        private const val ACTION_STOP = "com.powos.app.action.KEYBOARD_SHARE_STOP"
        private const val CHANNEL = "powos-kb-share"
        private const val NOTE_ID = 0x6b62
    }
}
