package dev.omalauncher.devices

import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.BatteryManager
import android.os.PowerManager
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import dev.omalauncher.R
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.math.BigInteger
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.util.Calendar
import java.util.concurrent.Executors
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.security.auth.x500.X500Principal

/**
 * The device agent served by the PowOS app itself, for a phone WITHOUT root (docs/DEVICES.md "Phone without root",
 * docs/research/device-ecosystem.md D5): HTTPS on :3416 with a key that never leaves Android Keystore (self-signed,
 * pinned by each client at pairing, like powos-deviced's), the v1 protocol from DeviceAgentCore, and Android's own
 * APIs as the backend - no adb, no root. A rooted phone runs lib/devices/powos-deviced in its system tier instead
 * (the same port), so this starts only when RootedGuest is off.
 *
 * Caps: status (battery, plugged, screen, locked), screen_on (a wake lock that turns the screen on; it stays locked),
 * ring (the alarm sound for 10 s, for a phone lost in the bed). lock/screen_off need a device admin or an
 * accessibility service, which the app doesn't hold yet, so they aren't advertised here (the rooted backend has them).
 */
object DeviceAgentHost {
    private const val TAG = "PowosDeviced"
    private const val ALIAS = "powos-deviced-tls"
    private const val CHANNEL = "devices"
    private const val BODY_MAX = 16 * 1024
    private var started = false

    @Synchronized
    fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        Thread({ runCatching { serve(app) }.onFailure { Log.w(TAG, "agent not started: $it") } }, "powos-deviced").start()
    }

    private fun serve(ctx: Context) {
        val core =
            DeviceAgentCore(
                dir = File(ctx.filesDir, "deviced"),
                name = { Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME) ?: "Phone" },
                backend = AndroidBackend(ctx),
                showCode = { from, code -> notifyCode(ctx, from, code) },
            )
        core.log = { Log.i(TAG, it) }
        val ssl = SSLContext.getInstance("TLS")
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(keyStore(core.id), null)
        ssl.init(kmf.keyManagers, null, null)
        val server = ssl.serverSocketFactory.createServerSocket() as SSLServerSocket
        server.reuseAddress = true
        server.bind(InetSocketAddress(DeviceAgentCore.PORT))
        Log.i(TAG, "${core.info()} on :${DeviceAgentCore.PORT}")
        val pool = Executors.newFixedThreadPool(4)
        while (true) {
            val s = server.accept()
            pool.execute { runCatching { s.use { one(core, it) } } }
        }
    }

    /** One HTTP/1.1 request per connection (Connection: close): the request line, headers, a bounded body. */
    private fun one(
        core: DeviceAgentCore,
        s: Socket,
    ) {
        s.soTimeout = 15_000
        val inp = BufferedInputStream(s.getInputStream())
        val lines = readHead(inp)?.split("\r\n") ?: return
        val parts = lines[0].split(" ")
        val method = parts.getOrNull(0) ?: ""
        val path = parts.getOrNull(1) ?: "/"
        val headers = lines.drop(1).filter { ':' in it }.associate { it.substringBefore(':').trim().lowercase() to it.substringAfter(':').trim() }
        val n = headers["content-length"]?.toIntOrNull() ?: 0
        val reply =
            if (n > BODY_MAX) {
                DeviceAgentCore.Reply(400, JSONObject().put("ok", false).put("error", "request too large").put("code", "bad-request"))
            } else {
                core.handle(method, path, headers["authorization"], readBody(inp, n))
            }
        // One line per request, never a header (tokens live in headers).
        Log.i(TAG, "${s.inetAddress.hostAddress} $method ${path.substringBefore('?')} ${reply.status}")
        write(s, reply)
    }

    private fun readHead(inp: BufferedInputStream): String? {
        val head = StringBuilder()
        while (!head.endsWith("\r\n\r\n")) {
            val c = inp.read()
            if (c < 0 || head.length > 8192) return null
            head.append(c.toChar())
        }
        return head.toString()
    }

    private fun readBody(
        inp: BufferedInputStream,
        n: Int,
    ): String {
        if (n <= 0) return ""
        val b = ByteArray(n)
        var off = 0
        while (off < n) {
            val r = inp.read(b, off, n - off)
            if (r < 0) break
            off += r
        }
        return String(b, 0, off)
    }

    private fun write(
        s: Socket,
        reply: DeviceAgentCore.Reply,
    ) {
        val out = reply.body.toString().toByteArray()
        val w = s.getOutputStream()
        w.write(
            ("HTTP/1.1 ${reply.status} ${if (reply.status == 200) "OK" else "Error"}\r\nContent-Type: application/json\r\n" +
                "Content-Length: ${out.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray(),
        )
        w.write(out)
        w.flush()
    }

    /** The agent's TLS key in Android Keystore (made once: P-256, self-signed, CN = powos-<device id>). */
    private fun keyStore(id: String): KeyStore {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(ALIAS)) {
            val from = Calendar.getInstance()
            val to = Calendar.getInstance().apply { add(Calendar.YEAR, 10) }
            val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            gen.initialize(
                KeyGenParameterSpec
                    .Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                    .setCertificateSubject(X500Principal("CN=powos-$id"))
                    .setCertificateSerialNumber(BigInteger.ONE)
                    .setCertificateNotBefore(from.time)
                    .setCertificateNotAfter(to.time)
                    .build(),
            )
            gen.generateKeyPair()
        }
        return ks
    }

    private fun notifyCode(
        ctx: Context,
        from: String,
        code: String,
    ) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Devices", NotificationManager.IMPORTANCE_HIGH))
        nm.notify(
            CHANNEL.hashCode(),
            android.app.Notification
                .Builder(ctx, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("$from wants to control this phone")
                .setContentText("Pairing code $code - type it there. Ignore this if it wasn't you.")
                .setTimeoutAfter(DeviceAgentCore.TTL_MS)
                .setAutoCancel(true)
                .build(),
        )
    }

    /** Android's own APIs: no root, no adb. */
    private class AndroidBackend(
        private val ctx: Context,
    ) : DeviceBackend {
        override fun caps() = listOf("status", "screen_on", "ring")

        override fun status(): JSONObject {
            val b = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = b?.let { it.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) * 100 / it.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1) }
            val plugged = (b?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
            val charging = b?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) == BatteryManager.BATTERY_STATUS_CHARGING
            val pm = ctx.getSystemService(PowerManager::class.java)
            val km = ctx.getSystemService(KeyguardManager::class.java)
            return JSONObject()
                .put("online", true)
                .put("at", System.currentTimeMillis() / 1000)
                .put(
                    "power",
                    JSONObject()
                        .put("source", if (plugged) "ac" else "battery")
                        .put("battery", level?.takeIf { it >= 0 } ?: JSONObject.NULL)
                        .put("charging", charging)
                        .put("accessories", org.json.JSONArray()),
                ).put("screen", if (pm.isInteractive) "on" else "off")
                .put("locked", km.isKeyguardLocked)
                .put("busy", org.json.JSONArray())
        }

        override fun act(
            action: String,
            args: JSONObject,
            force: Boolean,
        ): JSONObject {
            when (action) {
                "screen_on" -> {
                    // HACK: FULL_WAKE_LOCK|ACQUIRE_CAUSES_WAKEUP is deprecated but is the one no-root way to light the
                    // screen from a background service. Real fix: a full-screen-intent activity with setTurnScreenOn.
                    @Suppress("DEPRECATION")
                    val wl =
                        ctx
                            .getSystemService(PowerManager::class.java)
                            .newWakeLock(PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP, "powos:deviced-screen-on")
                    wl.acquire(3_000)
                }
                "ring" -> {
                    val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    val r = RingtoneManager.getRingtone(ctx, uri) ?: throw DeviceActionError("no sound to ring with", "failed")
                    r.audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
                    r.play()
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ r.stop() }, 10_000)
                }
                else -> throw DeviceActionError("$action: this device can't", "unsupported")
            }
            return JSONObject().put("done", true)
        }
    }
}
