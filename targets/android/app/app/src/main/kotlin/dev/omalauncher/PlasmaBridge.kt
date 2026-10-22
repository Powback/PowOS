package dev.omalauncher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.FileObserver
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The Plasma session's notifications and clipboard on Android (rooted mode), through powos-plasma-bridge in the
 * session (targets/android/session) and the run dir:
 *   run/plasma/out/   from the session: "notify" / "close" / "reset" / "clip"   (FileObserver here)
 *   run/plasma/in/    to the session:   "close" / "action" / "clip"            (inotify there)
 * each file written as .name and renamed into place, read once and deleted.
 *
 * A Plasma notification becomes an Android one (tag [TAG], id = Plasma's id), so PowOS's shade lists it like any
 * other, with its heads-up banner, buttons and swipe: the shade's item takes the Linux app's name and drawer icon
 * from [EXTRA_APP] / [EXTRA_ENTRY] (Notifications.item, ShellBridge.notificationJson). Swiped away (its delete
 * intent) -> closed in Plasma; a button or the tap -> Plasma's InvokeAction (the tap also opens the Linux app, as
 * Plasma's own popup would raise its window). Closed in Plasma (dismissed there, withdrawn by the app) -> cancelled
 * here; a popup that only timed out stays, as it stays in Plasma's history.
 *
 * Clipboard, text: the session's copy -> Android's clip. Android's -> the session when the app can read it - its
 * listener, which Android calls only while one of the app's windows has focus, and [pushClip] when a Linux window's
 * task takes focus (PowosWindowActivity's hook; the desktop's own MainActivity sends its clip through KWin already).
 * The last text either way is remembered, so neither echoes the other back.
 *
 * Nothing polls: one FileObserver, the files read on a thread of their own.
 */
object PlasmaBridge {
    private const val TAG = "PowosPlasma"
    const val NOTIFY_TAG = "plasma"

    /** In a mirrored notification's extras: the Linux app's name, and its desktop entry id (may be empty). */
    const val EXTRA_APP = "powos.linux.app"
    const val EXTRA_ENTRY = "powos.linux.entry"
    const val EXTRA_ICON = "powos.linux.icon"

    private const val CHANNEL = "plasma-v1"
    private const val CHANNEL_QUIET = "plasma-quiet-v1"
    private const val EXTRA_ID = "id"
    private const val EXTRA_KEY = "key"
    private const val EXTRA_OP = "op"
    private const val MAX_ACTIONS = 3
    private const val MAX_CLIP = 256 * 1024

    private val worker by lazy { Handler(HandlerThread("plasma").apply { start() }.looper) }
    private val main = Handler(Looper.getMainLooper())
    private var observer: FileObserver? = null
    private lateinit var app: Context
    private var outDir: File? = null
    private var inDir: File? = null

    /** The last clipboard text either way (main thread). */
    private var lastClip: String? = null

    /** Ids posted here, so a reset cancels only ours. */
    private val posted = HashSet<Int>()

    fun start(
        context: Context,
        runDir: File,
    ) {
        if (observer != null) return
        app = context.applicationContext
        val out = File(runDir, "plasma/out").apply { mkdirs() }
        outDir = out
        inDir = File(runDir, "plasma/in").apply { mkdirs() }
        channels()
        observer =
            object : FileObserver(out, MOVED_TO) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path != null && !path.startsWith(".") && path.endsWith(".json")) worker.post { take(File(out, path)) }
                }
            }.also { it.startWatching() }
        // What arrived while the app wasn't running (a reset first, if the bridge restarted meanwhile).
        worker.post { out.listFiles()?.filter { !it.name.startsWith(".") }?.sortedBy { it.name }?.forEach(::take) }
        main.post {
            app.getSystemService(ClipboardManager::class.java)?.addPrimaryClipChangedListener { pushClip(app) }
        }
    }

    private fun take(file: File) {
        val json = runCatching { JSONObject(file.readText()) }.getOrNull()
        file.delete()
        json ?: return
        main.post {
            when (json.optString("op")) {
                "notify" -> post(json)
                "close" -> cancel(json.optInt("id"))
                "reset" -> posted.toList().forEach(::cancel)
                "clip" -> setClip(json.optString("text"))
            }
        }
    }

    private fun nm() = app.getSystemService(NotificationManager::class.java)

    private fun channels() {
        nm().createNotificationChannels(
            listOf(
                // Plasma plays its own sound in the session; here the banner only.
                NotificationChannel(CHANNEL, "Plasma notifications", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Notifications from the PowOS desktop's apps (Plasma), with a banner"
                    setSound(null, null)
                    enableVibration(false)
                },
                NotificationChannel(CHANNEL_QUIET, "Plasma notifications (low)", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Low-urgency notifications from the PowOS desktop's apps, in the shade only"
                },
            ),
        )
    }

    private fun post(n: JSONObject) {
        val id = n.optInt("id").takeIf { it != 0 } ?: return
        val appName = n.optString("app").ifBlank { "Plasma" }
        val title = n.optString("title")
        val actions = n.optJSONArray("actions") ?: JSONArray()
        val keys = (0 until actions.length()).mapNotNull { actions.optJSONArray(it) }.map { it.optString(0) to it.optString(1) }
        val extras =
            android.os.Bundle().apply {
                putString(EXTRA_APP, appName)
                putString(EXTRA_ENTRY, n.optString("entry"))
                putString(EXTRA_ICON, n.optString("icon"))
            }
        val b =
            Notification.Builder(app, if (n.optInt("urgency", 1) == 0) CHANNEL_QUIET else CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title.ifBlank { appName })
                .setContentText(n.optString("text"))
                .setStyle(Notification.BigTextStyle().bigText(n.optString("text")))
                .setSubText(appName)
                .setWhen(n.optLong("time", System.currentTimeMillis() / 1000) * 1000)
                .setShowWhen(true)
                .setAutoCancel(true)
                .addExtras(extras)
                .setContentIntent(intent(id, "tap", keys.firstOrNull { it.first == "default" }?.first.orEmpty()))
                .setDeleteIntent(intent(id, "close", ""))
        if (n.optInt("urgency", 1) == 2) b.setCategory(Notification.CATEGORY_ERROR)
        if (n.optBoolean("transient")) b.setTimeoutAfter(n.optLong("timeout").takeIf { it > 0 } ?: TRANSIENT_MS)
        keys.filter { it.first != "default" && it.second.isNotBlank() }.take(MAX_ACTIONS).forEach { (key, label) ->
            b.addAction(Notification.Action.Builder(null, label, intent(id, "action", key)).build())
        }
        posted += id
        lastEntry[id] = n.optString("entry")
        runCatching { nm().notify(NOTIFY_TAG, id, b.build()) }.onFailure { Log.w(TAG, "notify $id: $it") }
    }

    private const val TRANSIENT_MS = 8000L

    private fun cancel(id: Int) {
        posted -= id
        lastEntry -= id
        nm().cancel(NOTIFY_TAG, id)
    }

    private fun intent(
        id: Int,
        op: String,
        key: String,
    ): PendingIntent =
        PendingIntent.getBroadcast(
            app,
            // One request code per (notification, op, key): distinct PendingIntents.
            "$id/$op/$key".hashCode(),
            Intent(app, Receiver::class.java).putExtra(EXTRA_ID, id).putExtra(EXTRA_OP, op).putExtra(EXTRA_KEY, key),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /** A request to the session's bridge. */
    private fun send(req: JSONObject) {
        val dir = inDir ?: return
        worker.post {
            val name = "${System.nanoTime()}.json"
            val tmp = File(dir, ".$name")
            runCatching {
                tmp.writeText(req.toString())
                if (!tmp.renameTo(File(dir, name))) tmp.delete()
            }.onFailure { Log.w(TAG, "request: $it") }
        }
    }

    /** The notification's buttons, tap and swipe (also PowOS's shade, which sends the same intents). */
    class Receiver : BroadcastReceiver() {
        override fun onReceive(
            context: Context,
            intent: Intent,
        ) {
            val id = intent.getIntExtra(EXTRA_ID, 0).takeIf { it != 0 } ?: return
            val key = intent.getStringExtra(EXTRA_KEY).orEmpty()
            when (intent.getStringExtra(EXTRA_OP)) {
                "close" -> {
                    posted -= id
                    send(JSONObject().put("op", "close").put("id", id))
                }
                "action" -> {
                    cancel(id)
                    send(JSONObject().put("op", "action").put("id", id).put("key", key))
                }
                "tap" -> {
                    posted -= id
                    val req = JSONObject().put("id", id)
                    send(if (key.isEmpty()) req.put("op", "close") else req.put("op", "action").put("key", key))
                    openApp(context, id)
                    lastEntry -= id
                }
            }
        }

        /** The tapped notification's Linux app, as its drawer icon opens it (its window as an Android task). */
        private fun openApp(
            context: Context,
            id: Int,
        ) {
            val sbn = runCatching { nm().activeNotifications.firstOrNull { it.tag == NOTIFY_TAG && it.id == id } }.getOrNull()
            val entry = sbn?.notification?.extras?.getString(EXTRA_ENTRY) ?: lastEntry[id] ?: return
            val runtime = (context.applicationContext as App).runtime
            runtime.linuxApps.firstOrNull { it.id == entry }?.let { runtime.launch(it) }
        }
    }

    /** The desktop entry per posted id, for a tap whose notification auto-cancelled before the receiver ran. */
    private val lastEntry = HashMap<Int, String>()

    /** Android's clip -> the session, when the app may read it (focused) and it isn't what the session sent. */
    @JvmStatic
    fun pushClip(context: Context) {
        if (inDir == null) return
        val cm = context.getSystemService(ClipboardManager::class.java) ?: return
        val text = runCatching { cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString() }.getOrNull()
        if (text.isNullOrEmpty() || text == lastClip || text.length > MAX_CLIP) return
        lastClip = text
        send(JSONObject().put("op", "clip").put("text", text))
    }

    private fun setClip(text: String) {
        if (text.isEmpty() || text == lastClip) return
        val cm = app.getSystemService(ClipboardManager::class.java) ?: return
        lastClip = text
        // Already there (KWin's own clipboard path set it while the desktop was up): don't set it twice.
        val now = runCatching { cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString() }.getOrNull()
        if (now == text) return
        runCatching { cm.setPrimaryClip(ClipData.newPlainText("PowOS desktop", text)) }.onFailure { Log.w(TAG, "clip: $it") }
    }
}
