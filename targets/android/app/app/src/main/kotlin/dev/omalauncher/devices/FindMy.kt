package dev.omalauncher.devices

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import dev.omalauncher.R
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Find my device (docs/DEVICES.md "Ring and locate", board find-my-devices-ring-and-locate), no root:
 *
 *  - ring: the alarm sound, looping, on the alarm stream turned to its maximum (so it sounds on silent and vibrate),
 *    until it's stopped - on this phone (the notification's Stop, a tap or swipe on it, the power button, an unlock)
 *    or by the caller (`ring_stop`) - and at most [RING_MAX_S]. The alarm volume the person had comes back after.
 *    args.volume < 1 (0..1) plays that quietly and leaves the alarm volume alone (a check that shouldn't be loud).
 *  - locate: the phone's location on request - a fresh fix from the fused provider (up to [FIX_MS]), else the newest
 *    last-known one - as {lat, lon, accuracy_m, at, age_s, provider, fresh}. Nothing is tracked or sent otherwise.
 *
 * The no-root agent (DeviceAgentHost) calls this directly; the rooted phone's powos-deviced reaches the same code
 * through [Command] (`am broadcast`, held to DUMP = adb shell or root), so both kinds of phone ring and locate alike.
 */
object FindMy {
    const val RING_MAX_S = 300
    private const val FIX_MS = 10_000L
    private const val CHANNEL = "find-my"
    private const val NOTE_ID = 0x46_4D_59 // "FMY"

    /** A press in the first moment after ringing starts is the person's last tap, not "found it". */
    private const val SETTLE_MS = 1_500L
    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var restore: Int? = null
    private var screen: BroadcastReceiver? = null
    private var since = 0L
    private val timeout = Runnable { appCtx?.let { stop(it) } }
    private var appCtx: Context? = null

    @get:Synchronized
    val ringing: Boolean get() = player != null

    @Synchronized
    fun ring(
        context: Context,
        volume: Double = 1.0,
        seconds: Int = RING_MAX_S,
    ): JSONObject {
        val ctx = context.applicationContext
        appCtx = ctx
        stopLocked(ctx, quiet = true)
        val am = ctx.getSystemService(AudioManager::class.java)
        val loud = volume >= 1.0
        if (loud) {
            // Max alarm volume; DND's "total silence" can still refuse it (then it plays at what the person set).
            restore = am.getStreamVolume(AudioManager.STREAM_ALARM)
            runCatching { am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0) }
        }
        val uri =
            RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val mp =
            runCatching {
                MediaPlayer().apply {
                    setAudioAttributes(
                        AudioAttributes
                            .Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    setDataSource(ctx, uri)
                    isLooping = true
                    if (!loud) volume.coerceIn(0.0, 1.0).toFloat().let { setVolume(it, it) }
                    prepare()
                    start()
                }
            }.getOrElse {
                restoreVolume(ctx)
                throw DeviceActionError("no sound to ring with: ${it.message}", "failed")
            }
        player = mp
        since = SystemClock.elapsedRealtime()
        val s = seconds.coerceIn(1, RING_MAX_S)
        main.removeCallbacks(timeout)
        main.postDelayed(timeout, s * 1000L)
        watchScreen(ctx)
        notifyRinging(ctx)
        return JSONObject().put("ringing", true).put("seconds", s).put("volume", if (loud) "max" else volume)
    }

    @Synchronized
    fun stop(context: Context): JSONObject {
        val was = player != null
        stopLocked(context.applicationContext, quiet = false)
        return JSONObject().put("ringing", false).put("was", was)
    }

    private fun stopLocked(
        ctx: Context,
        quiet: Boolean,
    ) {
        main.removeCallbacks(timeout)
        player?.let { runCatching { it.stop() }; it.release() }
        player = null
        restoreVolume(ctx)
        screen?.let { runCatching { ctx.unregisterReceiver(it) } }
        screen = null
        if (!quiet) ctx.getSystemService(NotificationManager::class.java).cancel(NOTE_ID)
    }

    private fun restoreVolume(ctx: Context) {
        val v = restore ?: return
        restore = null
        runCatching { ctx.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, v, 0) }
    }

    /** The power button or an unlock means the phone is in someone's hand: stop, like stock Find My Device. */
    private fun watchScreen(ctx: Context) {
        val r =
            object : BroadcastReceiver() {
                override fun onReceive(
                    c: Context,
                    i: Intent,
                ) {
                    if (SystemClock.elapsedRealtime() - since > SETTLE_MS) stop(c)
                }
            }
        val f = IntentFilter().apply { listOf(Intent.ACTION_SCREEN_ON, Intent.ACTION_SCREEN_OFF, Intent.ACTION_USER_PRESENT).forEach(::addAction) }
        ctx.registerReceiver(r, f)
        screen = r
    }

    private fun notifyRinging(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Find my device", NotificationManager.IMPORTANCE_HIGH).apply { setSound(null, null) })
        val stop =
            PendingIntent.getBroadcast(
                ctx,
                0,
                Intent(ctx, Stop::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        nm.notify(
            NOTE_ID,
            android.app.Notification
                .Builder(ctx, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Ringing this phone")
                .setContentText("Someone is looking for it from another of your devices. Tap to stop.")
                .setCategory(android.app.Notification.CATEGORY_ALARM)
                .setOngoing(true)
                .setContentIntent(stop)
                .setDeleteIntent(stop)
                .addAction(android.app.Notification.Action.Builder(null, "Stop", stop).build())
                .build(),
        )
    }

    fun canLocate(ctx: Context): Boolean =
        listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION).any {
            ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }

    const val LOCATE_REFUSAL = "PowOS may not use location here - allow it in Settings > Apps > PowOS > Location (all the time)"

    /** Blocking (up to [FIX_MS]): call it off the main thread. */
    @Suppress("MissingPermission")
    fun locate(context: Context): JSONObject {
        val ctx = context.applicationContext
        if (!canLocate(ctx)) throw DeviceActionError(LOCATE_REFUSAL, "unsupported")
        val lm = ctx.getSystemService(LocationManager::class.java)
        if (!lm.isLocationEnabled) throw DeviceActionError("location is turned off on this phone", "failed")
        val providers = lm.getProviders(true)
        val provider = listOf("fused", LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).firstOrNull { it in providers }
        val fresh = provider?.let { runCatching { current(lm, it) }.getOrNull() }
        val loc =
            fresh ?: providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }.maxByOrNull { it.time }
                ?: throw DeviceActionError("no location yet - this phone hasn't had a fix", "failed")
        return place(loc, fresh != null, System.currentTimeMillis())
    }

    fun place(
        loc: Location,
        fresh: Boolean,
        now: Long,
    ): JSONObject =
        JSONObject()
            .put("lat", loc.latitude)
            .put("lon", loc.longitude)
            .put("accuracy_m", if (loc.hasAccuracy()) loc.accuracy.toDouble() else JSONObject.NULL)
            .put("at", loc.time / 1000)
            .put("age_s", ((now - loc.time) / 1000).coerceAtLeast(0))
            .put("provider", loc.provider ?: "")
            .put("fresh", fresh)

    @Suppress("MissingPermission")
    private fun current(
        lm: LocationManager,
        provider: String,
    ): Location? {
        val done = CountDownLatch(1)
        var got: Location? = null
        val cancel = CancellationSignal()
        lm.getCurrentLocation(provider, cancel, { it.run() }) {
            got = it
            done.countDown()
        }
        if (!done.await(FIX_MS, TimeUnit.MILLISECONDS)) cancel.cancel()
        return got
    }

    /** The notification's Stop (and a tap or swipe on it): this app's own PendingIntent, never exported. */
    class Stop : BroadcastReceiver() {
        override fun onReceive(
            context: Context,
            intent: Intent,
        ) {
            stop(context)
        }
    }

    /**
     * The rooted phone's powos-deviced (adb shell, as shell or root): `am broadcast -n com.powos.app/
     * dev.omalauncher.devices.FindMy\$Command --es op ring|ring_stop|locate [--es volume 0.1] [--es seconds 3]`; the
     * answer is the broadcast's result data (JSON). Guarded by DUMP in the manifest, so no ordinary app can send it.
     */
    class Command : BroadcastReceiver() {
        override fun onReceive(
            context: Context,
            intent: Intent,
        ) {
            val op = intent.getStringExtra("op")
            val result = goAsync()
            Thread {
                val out =
                    try {
                        JSONObject().put("ok", true).put("result", run(context, op, intent))
                    } catch (e: DeviceActionError) {
                        JSONObject().put("ok", false).put("error", e.message).put("code", e.code)
                    } catch (e: Exception) {
                        JSONObject().put("ok", false).put("error", e.message ?: "failed").put("code", "failed")
                    }
                result.resultData = out.toString()
                result.finish()
            }.start()
        }

        private fun run(
            ctx: Context,
            op: String?,
            i: Intent,
        ): JSONObject =
            when (op) {
                "ring" -> ring(ctx, i.getStringExtra("volume")?.toDoubleOrNull() ?: 1.0, i.getStringExtra("seconds")?.toIntOrNull() ?: RING_MAX_S)
                "ring_stop" -> stop(ctx)
                "locate" -> locate(ctx)
                else -> throw DeviceActionError("no op '${op?.take(24)}'", "bad-request")
            }
    }
}
