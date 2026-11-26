package dev.omalauncher.devices

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast

/**
 * The share sheet's "Send to my device" (and "Send to <device>", the sharing shortcuts [DropInbox] keeps): text, a
 * link, an image or a file goes, sealed ([Drops]), to one of the owner's other signed-in devices, which shows it as a
 * notification. No window of its own: a device picker when the share didn't name one, then a toast saying how it went.
 * Without root: an ordinary exported activity (docs/DEVICES.md "Clipboard and Send to").
 */
class SendToDeviceActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = applicationContext
        val share = intent
        val to = share.getStringExtra(EXTRA_TO) ?: share.getStringExtra(Intent.EXTRA_SHORTCUT_ID)?.removePrefix("send:")
        if (PowStation.credentials(app) == null) return done("Join your PowStation first (Settings > powstation)")
        if (to != null) return send(app, share, to, null)
        Thread {
            val devices = Drops.devices(app)
            runOnUiThread {
                when {
                    devices == null -> done("PowStation isn't reachable")
                    devices.isEmpty() -> done("No other device is signed in to your account")
                    devices.size == 1 -> send(app, share, devices[0].first, devices[0].second)
                    else ->
                        AlertDialog.Builder(this)
                            .setTitle("Send to")
                            .setItems(devices.map { it.second }.toTypedArray()) { _, i -> send(app, share, devices[i].first, devices[i].second) }
                            .setOnCancelListener { finish() }
                            .show()
                }
            }
        }.start()
    }

    private fun send(
        app: Context,
        share: Intent,
        to: String,
        name: String?,
    ) {
        Thread {
            val msg =
                runCatching {
                    when (val item = itemOf(app, share)) {
                        null -> "Nothing to send"
                        else ->
                            when (val r = Drops.put(app, "send", to, item)) {
                                is Drops.Sent.Ok -> "Sent to ${name ?: "your device"}"
                                is Drops.Sent.No -> "Not sent: ${r.why}"
                            }
                    }
                }.getOrElse { "Not sent: ${it.message}" }
            runOnUiThread { done(msg) }
        }.start()
    }

    private fun done(msg: String) {
        Toast.makeText(applicationContext, msg, Toast.LENGTH_LONG).show()
        finish()
    }

    companion object {
        const val EXTRA_TO = "dev.omalauncher.devices.SEND_TO"
        const val SHARE_CATEGORY = "dev.omalauncher.category.SEND_TO_DEVICE"

        /** What the share carries: a stream (image/file, read up to the cap) or text/link. */
        fun itemOf(
            c: Context,
            share: Intent,
        ): Drops.Item? {
            @Suppress("DEPRECATION")
            val uri = share.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (uri != null) return streamItem(c, uri, share.type)
            val text = share.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { it.isNotBlank() } ?: return null
            return Drops.Item.ofText(text)
        }

        private fun streamItem(
            c: Context,
            uri: Uri,
            type: String?,
        ): Drops.Item? {
            val mime = type?.takeIf { '*' !in it } ?: c.contentResolver.getType(uri).orEmpty()
            val (name, size) = nameAndSize(c, uri)
            Drops.tooBig("send", size)?.let { throw IllegalStateException(it) }
            val bytes = c.contentResolver.openInputStream(uri)?.use { readCapped(it) } ?: return null
            return Drops.Item(if (mime.startsWith("image/")) "image" else "file", bytes, name, mime)
        }

        private fun nameAndSize(
            c: Context,
            uri: Uri,
        ): Pair<String, Long> =
            c.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                if (!it.moveToFirst()) return@use "" to -1L
                it.getString(0).orEmpty() to (if (it.isNull(1)) -1L else it.getLong(1))
            } ?: ("" to -1L)

        private fun readCapped(s: java.io.InputStream): ByteArray {
            val out = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(64 * 1024)
            var n = s.read(chunk)
            while (n >= 0) {
                out.write(chunk, 0, n)
                Drops.tooBig("send", out.size().toLong())?.let { throw IllegalStateException(it) }
                n = s.read(chunk)
            }
            return out.toByteArray()
        }
    }
}
