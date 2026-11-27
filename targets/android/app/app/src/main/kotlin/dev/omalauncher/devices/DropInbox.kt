package dev.omalauncher.devices

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.PowerManager
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import dev.omalauncher.R
import java.io.File

/**
 * Send to my device, the receiving end (docs/DEVICES.md "Clipboard and Send to"): what another of the owner's devices
 * sent here waits in the realm (sealed, [Drops]); this polls for it while the screen is on, opens it, keeps it in the
 * app's cache and shows a notification - Open (a link, a file in the app that takes it) and Save (Downloads) or Copy
 * (text). The realm's copy goes once it is here. Also keeps the share sheet's "Send to <device>" targets current
 * (sharing shortcuts, one per device of the account; [SendToDeviceActivity]).
 */
object DropInbox {
    private const val TAG = "PowosDrops"
    private const val CHANNEL = "drops"
    private const val POLL_MS = 15_000L
    private const val AWAY_MS = 120_000L // not joined / PowStation not reachable
    private const val SHORTCUTS_MS = 3_600_000L
    const val ACTION = "dev.omalauncher.devices.DROP"
    private var started = false

    @Synchronized
    fun start(context: Context) {
        if (started || android.app.Application.getProcessName() != context.packageName) return
        started = true
        val app = context.applicationContext
        Thread({
            while (true) Thread.sleep(runCatching { round(app) }.getOrElse { Log.w(TAG, "round: $it"); AWAY_MS })
        }, "powos-drops").apply { isDaemon = true }.start()
    }

    private var shortcutsAt = 0L

    /** One poll; how long until the next. */
    private fun round(app: Context): Long {
        val pm = app.getSystemService(PowerManager::class.java)
        if (PowStation.credentials(app) == null || pm?.isInteractive == false) return POLL_MS
        if (System.currentTimeMillis() - shortcutsAt > SHORTCUTS_MS) {
            Drops.devices(app)?.let { publishTargets(app, it) }
            shortcutsAt = System.currentTimeMillis()
        }
        val waiting = Drops.waiting(app, "send") ?: return AWAY_MS
        waiting.forEach { receive(app, it) }
        return POLL_MS
    }

    private fun receive(
        c: Context,
        w: Drops.Waiting,
    ) {
        val item = Drops.take(c, w) ?: return
        if (item.type == Handoff.TYPE) {
            Handoff.parse(item.body)?.let { continueFrom(c, w, it) }
            return Drops.done(c, w.id)
        }
        val dir = File(c.cacheDir, "share/drops/${w.id}").apply { mkdirs() }
        val f = File(dir, safeName(item)).apply { writeBytes(item.body) }
        notify(c, w, item, f)
        Drops.done(c, w.id)
    }

    /** The file name a drop lands under here (pure: DropsTest): its own name, no path, never empty. */
    fun safeName(item: Drops.Item): String {
        val n = item.name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\u0000-\\u001f:*?\"<>|]"), "_").trim().trimStart('.')
        if (n.isNotBlank()) return n.take(120)
        return when (item.type) {
            "text", "link" -> "text.txt"
            "image" -> "image." + item.mime.substringAfter('/', "png").filter { it.isLetterOrDigit() }.ifBlank { "png" }
            else -> "file"
        }
    }

    private fun notify(
        c: Context,
        w: Drops.Waiting,
        item: Drops.Item,
        f: File,
    ) {
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Sent from your devices", NotificationManager.IMPORTANCE_HIGH))
        val from = w.fromName.ifBlank { "your other device" }
        val nid = w.id.hashCode()
        val text = item.type == "text" || item.type == "link"
        val open = openIntent(c, item, f)
        val second =
            Intent(c, Action::class.java).setAction(ACTION).putExtra("op", if (text) "copy" else "save")
                .putExtra("path", f.absolutePath).putExtra("mime", item.mime).putExtra("nid", nid)
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val n =
            Notification.Builder(c, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("From $from")
                .setContentText(if (text) item.text.take(200) else f.name)
                .setStyle(if (text) Notification.BigTextStyle().bigText(item.text.take(2000)) else null)
                .setContentIntent(PendingIntent.getActivity(c, nid, Intent.createChooser(open, "Open with").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), flags))
                .addAction(Notification.Action.Builder(null, if (text) "Copy" else "Save", PendingIntent.getBroadcast(c, nid, second, flags)).build())
                .setAutoCancel(true)
                .build()
        nm.notify(nid, n)
    }

    /** A handoff ([Handoff]): "Continue <title>" from the other device, its tap opens it here. */
    private fun continueFrom(
        c: Context,
        w: Drops.Waiting,
        p: org.json.JSONObject,
    ) {
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Sent from your devices", NotificationManager.IMPORTANCE_HIGH))
        val nid = w.id.hashCode()
        val title = p.optString("title").ifBlank { "this" }
        val open = PendingIntent.getActivity(c, nid, Handoff.openIntent(c, p), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n =
            Notification.Builder(c, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Continue $title")
                .setContentText("from ${w.fromName.ifBlank { "your other device" }}" + (p.optString("url").takeIf { it.isNotBlank() }?.let { " - $it" } ?: ""))
                .setContentIntent(open)
                .addAction(Notification.Action.Builder(null, "Continue", open).build())
                .setAutoCancel(true)
                .build()
        nm.notify(nid, n)
    }

    private fun openIntent(
        c: Context,
        item: Drops.Item,
        f: File,
    ): Intent {
        if (item.type == "link") return Intent(Intent.ACTION_VIEW, Uri.parse(item.text.trim())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val uri = FileProvider.getUriForFile(c, c.packageName + ".files", f)
        val mime = item.mime.ifBlank { if (item.type == "text") "text/plain" else "*/*" }
        return Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    /** The share sheet's direct targets: "Send to <device>" for each of the account's other devices. */
    private fun publishTargets(
        c: Context,
        devices: List<Pair<String, String>>,
    ) {
        val sm = c.getSystemService(ShortcutManager::class.java) ?: return
        val icon = Icon.createWithResource(c, R.drawable.ic_notification)
        val list =
            devices.take(sm.maxShortcutCountPerActivity.coerceAtMost(4)).map { (id, name) ->
                ShortcutInfo.Builder(c, "send:$id")
                    .setShortLabel(name)
                    .setLongLabel("Send to $name")
                    .setIcon(icon)
                    .setCategories(setOf(SendToDeviceActivity.SHARE_CATEGORY))
                    .setIntent(Intent(Intent.ACTION_DEFAULT, null, c, SendToDeviceActivity::class.java).putExtra(SendToDeviceActivity.EXTRA_TO, id))
                    .setLongLived(true)
                    .build()
            }
        runCatching {
            sm.dynamicShortcuts.filter { it.id.startsWith("send:") && list.none { s -> s.id == it.id } }.map { it.id }
                .takeIf { it.isNotEmpty() }?.let { sm.removeDynamicShortcuts(it) }
            list.forEach { sm.pushDynamicShortcut(it) }
        }.onFailure { Log.w(TAG, "share targets: $it") }
    }

    /** The notification's second button: Copy (text) or Save (into Downloads, MediaStore - no permission needed). */
    class Action : BroadcastReceiver() {
        override fun onReceive(
            c: Context,
            i: Intent,
        ) {
            val f = File(i.getStringExtra("path") ?: return)
            if (!f.canonicalPath.startsWith(File(c.cacheDir, "share/drops").canonicalPath)) return
            c.getSystemService(NotificationManager::class.java).cancel(i.getIntExtra("nid", 0))
            if (i.getStringExtra("op") == "copy") {
                c.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("sent", f.readText()))
                return
            }
            val pending = goAsync()
            Thread {
                runCatching {
                    val v =
                        ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, f.name)
                            put(MediaStore.Downloads.MIME_TYPE, i.getStringExtra("mime")?.ifBlank { null } ?: "application/octet-stream")
                        }
                    val uri = c.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v) ?: error("no Downloads")
                    c.contentResolver.openOutputStream(uri)?.use { out -> f.inputStream().use { it.copyTo(out) } }
                    f.parentFile?.deleteRecursively()
                }.onFailure { Log.w(TAG, "save: $it") }
                pending.finish()
            }.start()
        }
    }
}
