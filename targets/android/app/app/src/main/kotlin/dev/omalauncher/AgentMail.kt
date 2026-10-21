package dev.omalauncher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationChannelGroup
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.compose.runtime.mutableStateListOf
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.linux.shellQuote
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * PowOS AI's agents reaching the user on the phone: what they send the user (`notify_user`, `powos comms notify`)
 * arrives in the run dir's agent-mail/ (lib/ai/comms/comms-mcp.py, on a phone) and becomes an Android notification -
 * tap it for the chat (the mail is put there), or answer inline: the reply goes to that agent's inbox
 * (`powos comms send <agent> <text>`).
 *
 * Kept until read. Every mail is stored ([store], the app's files - an update or reinstall keeps them) with whether
 * the user has read it: tapped it, replied, marked it read, or swiped it away (its delete intent). Whatever else takes
 * a notification away - an APK update or force stop cancels all of the app's, the system's own clean-ups - leaves the
 * mail unread, and unread mail is posted again (silently) when the app starts.
 *
 * How loud, by the mail's priority - a channel each, as a channel's sound, vibration and importance can't be changed
 * by the app once it exists (hence the versioned ids, [CHANNEL_VERSION]):
 * - urgent: an agent blocked on the user (approval asks too - [AgentsSpool]'s asks post here). Heads-up, the screen
 *   woken (to the lock face), a vibration, and the alarm-stream sound only with the ringer on - silent and vibrate
 *   mode are respected ([alertUrgent]). Passes Do not disturb's priority mode as an alarm. At most one alerting urgent
 *   per sender per 10 minutes: repeats collapse silently into its notification ([arrivedUrgent]).
 * - high: heads-up, the notification sound and a vibration - silent when the ringer is, held back by Do not disturb.
 * - normal: in the shade with a badge, no sound.
 * - low: in the shade only, silent, no badge.
 * Heads-up: SystemUI shows none while PowOS's shade has its own off (system/ShadeHost.kt) - PowOS's shade shows the
 * banner itself then (ShadeHost.peek), for every app's heads-up notification, these included.
 */
class AgentMail private constructor(
    private val context: Context,
    private val dir: File,
) : FileObserver(dir, MOVED_TO or CLOSE_WRITE) {
    override fun onEvent(
        event: Int,
        path: String?,
    ) {
        if (path == null || !path.endsWith(".json")) return
        arrived(File(dir, path))
    }

    private fun arrived(file: File) {
        val json = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return
        file.delete()
        // Read elsewhere (comms: `powos comms read`, the user's inbox drained): read here too, its notification gone.
        if (json.optString("op") == "read") {
            val ids = json.optJSONArray("ids") ?: return
            val list = (0 until ids.length()).map { ids.optString(it) }.filter { it.isNotEmpty() }
            main.post { markRead(context, list, fromComms = true) }
            return
        }
        val now = System.currentTimeMillis()
        val mail =
            Mail(
                from = json.optString("from").ifBlank { "manager" },
                text = json.optString("text"),
                time = json.optLong("time", now / 1000).takeIf { it > 0 } ?: (now / 1000),
                id = json.optString("id").ifBlank { "m$now-${file.name.hashCode().toUInt().toString(16)}" },
                priority = json.optString("priority").takeIf { it in PRIORITIES } ?: "normal",
            )
        main.post {
            if (store.any { it.id == mail.id }) return@post
            if (mail.priority == "urgent") return@post arrivedUrgent(context, mail)
            add(mail)
            post(context, mail, quiet = false)
        }
    }

    /** An inline reply, or "mark read", from the notification (or PowOS's shade, which sends the same intents). */
    class Reply : BroadcastReceiver() {
        override fun onReceive(
            context: Context,
            intent: Intent,
        ) {
            val id = intent.getStringExtra(EXTRA_MAIL) ?: ""
            val n = intent.getIntExtra(EXTRA_ID, 0)
            when (intent.getStringExtra(EXTRA_OP)) {
                OP_READ -> {
                    read(context, id)
                    context.getSystemService(NotificationManager::class.java).cancel(TAG, n)
                    return
                }
                // Swiped away (the notification's delete intent): read, as the user saw it go.
                OP_DISMISSED -> {
                    read(context, id)
                    return
                }
            }
            val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_TEXT)?.toString()?.trim() ?: return
            val agent = intent.getStringExtra(EXTRA_AGENT) ?: return
            val app = context.applicationContext
            val pending = goAsync()
            Thread({
                val ok =
                    runCatching {
                        // "--": a reply that starts with "-" is still the message, not an option.
                        RootedGuest.run("powos comms send ${shellQuote(agent)} -- ${shellQuote(text)}") == 0
                    }.getOrDefault(false)
                if (ok) {
                    read(app, id)
                    // The notification says so (Android shows the reply as sending until it's updated), then goes -
                    // posted after the read (which cancels the mail's notification) on the same queue.
                    main.post {
                        app.getSystemService(NotificationManager::class.java).notify(
                            TAG,
                            n,
                            Notification.Builder(app, channel(app, "low"))
                                .setSmallIcon(R.drawable.ic_notification)
                                .setContentTitle("PowOS AI · $agent")
                                .setContentText("You: $text")
                                .setTimeoutAfter(4000)
                                .build(),
                        )
                    }
                } else {
                    // Not sent: the mail stays unread, its notification back with what went wrong.
                    main.post {
                        load(app)
                        val mail = store.firstOrNull { it.id == id } ?: return@post
                        post(app, mail.copy(text = "Couldn't send your reply (\"$text\"): ${mail.text}"), quiet = true)
                    }
                }
                pending.finish()
            }, "agent-mail-reply").start()
        }
    }

    /** What an agent told the user: who, what, when (Unix seconds); [id] comms' message id, [read] by the user. */
    data class Mail(
        val from: String,
        val text: String,
        val time: Long,
        val id: String = "",
        val priority: String = "normal",
        val read: Boolean = false,
        /** An urgent repeat collapsed into an earlier one's notification: that one's id (it shares its notification). */
        val lead: String = "",
    ) {
        fun json(): JSONObject =
            JSONObject().put("id", id).put("from", from).put("text", text).put("time", time).put("priority", priority).put("read", read).put("lead", lead)

        /** The notification's id: the same for the same mail (and its collapsed repeats), so posting again replaces it. */
        val notificationId get() = lead.ifEmpty { id }.hashCode() and 0x7fffffff

        companion object {
            fun from(o: JSONObject) =
                Mail(o.optString("from"), o.optString("text"), o.optLong("time"), o.optString("id"), o.optString("priority", "normal"), o.optBoolean("read"), o.optString("lead"))
        }
    }

    companion object {
        /** The unread mail, newest first (the launcher's PowOS AI page's feed); kept across restarts. */
        val recent = mutableStateListOf<Mail>()

        /** Every mail kept (newest first): [recent] shows the first [KEEP_SHOWN]. */
        private val store = ArrayList<Mail>()
        private const val KEEP_SHOWN = 30

        /** Read mail is forgotten past this many; unread mail is kept however much there is (up to [KEEP_UNREAD]). */
        private const val KEEP_READ = 30
        private const val KEEP_UNREAD = 200

        private const val TAG = "agent-mail"
        private const val KEY_TEXT = "text"
        private const val EXTRA_AGENT = "agent"
        private const val EXTRA_ID = "id"
        private const val EXTRA_OP = "op"
        private const val OP_READ = "read"
        private const val OP_DISMISSED = "dismissed"

        /** On the chat's intent: the mail its notification was for ([opened]). */
        const val EXTRA_MAIL = "powos.mail"

        /** Quiet re-posts' group (see post): it alerts through its summary only, and there is none. */
        private const val QUIET_GROUP = "dev.omalauncher.agentmail.quiet"

        /** In a notification's extras: posted again quietly (after a restart) - PowOS's banner doesn't show it again. */
        const val EXTRA_QUIET = dev.omalauncher.widgets.runtime.Notifications.EXTRA_QUIET

        private val PRIORITIES = listOf("low", "normal", "high", "urgent")

        /** Bumped whenever a channel's settings change: a new id is the only way an app changes them. */
        private const val CHANNEL_VERSION = 2
        private const val GROUP = "powos-ai-agents"

        /** Channels of earlier versions, removed. */
        private val OLD_CHANNELS = listOf("powos-ai-agents", "powos-agents-ask", "agents-urgent-v2", "agents-urgent-v3")

        /**
         * urgent's own version: v3 tried for setBypassDnd (this phone's system drops it either way; urgent passes Do not
         * disturb's priority mode as an alarm instead), v4 has no sound of its own (the app's, ringer on only).
         */
        private const val URGENT_VERSION = 4

        private val main = Handler(Looper.getMainLooper())
        private var watcher: AgentMail? = null
        private var file: File? = null
        private var channelsMade = false

        /** The channel for [priority]'s mail (created if need be): urgent, high, normal or low. */
        fun channel(
            context: Context,
            priority: String,
        ): String {
            ensureChannels(context)
            return channelId(priority.takeIf { it in PRIORITIES } ?: "normal")
        }

        private fun channelId(priority: String) = "agents-$priority-v${if (priority == "urgent") URGENT_VERSION else CHANNEL_VERSION}"

        @Synchronized
        private fun ensureChannels(context: Context) {
            if (channelsMade) return
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannelGroup(NotificationChannelGroup(GROUP, "PowOS AI agents"))
            val notificationSound =
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            // The alarm stream: not muted by the ringer's silent mode (the alert slider), as the notification stream is.
            val alarmSound =
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            val channels =
                listOf(
                    NotificationChannel(channelId("urgent"), "Needs you", NotificationManager.IMPORTANCE_HIGH).apply {
                        description = "An agent is blocked until you answer (approvals, questions): a banner, the screen on, vibration; " +
                            "the alarm sound only with the ringer on. Through Do not disturb's priority mode"
                        // No sound of the channel's own: the app plays it, only with the ringer on (alertUrgent).
                        setSound(null, alarmSound)
                        // Nor a vibration: the app's (alertUrgent), as the system drops it on silent.
                        enableVibration(false)
                        // Kept by the system only for an app with Do not disturb access (PowOS has it: its notification listener).
                        setBypassDnd(true)
                        lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                    },
                    NotificationChannel(channelId("high"), "Important", NotificationManager.IMPORTANCE_HIGH).apply {
                        description = "An agent's important news: a banner, sound and vibration (as the ringer and Do not disturb allow)"
                        setSound(Settings.System.DEFAULT_NOTIFICATION_URI, notificationSound)
                        enableVibration(true)
                        vibrationPattern = longArrayOf(0, 250, 120, 250)
                    },
                    NotificationChannel(channelId("normal"), "Messages", NotificationManager.IMPORTANCE_DEFAULT).apply {
                        description = "What agents tell you: in the shade with a badge, no sound"
                        setSound(null, null)
                        enableVibration(false)
                        setShowBadge(true)
                    },
                    NotificationChannel(channelId("low"), "Quiet", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Agents' low-priority notes: in the shade only, silent"
                        setShowBadge(false)
                    },
                )
            channels.forEach { it.group = GROUP }
            nm.createNotificationChannels(channels)
            OLD_CHANNELS.forEach { runCatching { nm.deleteNotificationChannel(it) } }
            channelsMade = true
        }

        /** Posts [mail]'s notification; [quiet]: again after a restart - no sound, vibration or banner this time. */
        private fun post(
            context: Context,
            mail: Mail,
            quiet: Boolean,
        ) {
            val nm = context.getSystemService(NotificationManager::class.java)
            val n = mail.notificationId
            val open =
                PendingIntent.getActivity(
                    context,
                    n,
                    Intent(context, PowosAiActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra(EXTRA_MAIL, mail.id),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            fun op(
                code: Int,
                op: String?,
                mutable: Boolean = false,
            ) = PendingIntent.getBroadcast(
                context,
                n * 4 + code,
                Intent(context, Reply::class.java).putExtra(EXTRA_AGENT, mail.from).putExtra(EXTRA_ID, n).putExtra(EXTRA_MAIL, mail.id).apply {
                    op?.let { putExtra(EXTRA_OP, it) }
                },
                (if (mutable) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE) or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val reply =
                Notification.Action.Builder(null, "Reply", op(0, null, mutable = true))
                    .addRemoteInput(RemoteInput.Builder(KEY_TEXT).setLabel("Reply to ${mail.from}").build())
                    .build()
            val markRead = Notification.Action.Builder(null, "Mark read", op(1, OP_READ)).build()
            val urgent = mail.priority == "urgent"
            nm.notify(
                TAG,
                n,
                Notification.Builder(context, channel(context, mail.priority))
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle("PowOS AI · ${mail.from}")
                    // Collapsed: the first line. Expanded: the text, as much as a notification holds; the tap opens
                    // all of it in the chat ([opened]: the stored mail, never cut).
                    .setContentText(firstLine(mail.text))
                    .setStyle(Notification.BigTextStyle().bigText(expanded(mail.text)))
                    .setWhen(mail.time * 1000)
                    .setShowWhen(true)
                    .setContentIntent(open)
                    .setDeleteIntent(op(2, OP_DISMISSED))
                    .setAutoCancel(true)
                    .setOnlyAlertOnce(true)
                    // Quiet: no sound, vibration or banner - NotificationCompat.setSilent's way (the framework builder
                    // has no setSilent): a group member that leaves alerting to a summary that never comes.
                    .apply { if (quiet) setGroup(QUIET_GROUP).setGroupAlertBehavior(Notification.GROUP_ALERT_SUMMARY) }
                    .addAction(reply)
                    .addAction(markRead)
                    .setCategory(if (urgent) Notification.CATEGORY_ALARM else Notification.CATEGORY_MESSAGE)
                    .addExtras(android.os.Bundle().apply { putBoolean(EXTRA_QUIET, quiet) })
                    .build(),
            )
            if (urgent && !quiet) alertUrgent(context)
        }

        /**
         * Android keeps at most 5 KiB characters of a notification's text (Notification.MAX_CHARSEQUENCE_LENGTH: the
         * rest is dropped without a word); the expanded body stops short of it and says the tap has the rest.
         */
        private const val NOTIFICATION_TEXT_MAX = 5 * 1024
        private const val EXPANDED_MAX = NOTIFICATION_TEXT_MAX - 200

        /** The collapsed line: the text's first non-blank line (the system ellipsizes it to the width). */
        fun firstLine(text: String): String = text.lineSequence().firstOrNull { it.isNotBlank() }?.trim() ?: text

        /** The expanded body: all of [text] if it fits a notification, else its start and how much the tap opens. */
        fun expanded(text: String): String {
            if (text.length <= EXPANDED_MAX) return text
            // Not between a surrogate pair's halves (an emoji cut in two).
            var cut = EXPANDED_MAX
            if (Character.isHighSurrogate(text[cut - 1])) cut--
            return text.substring(0, cut) + "\n\n… ${text.length - cut} more characters - tap to read it all"
        }

        /** Urgent mail with the screen off: the screen comes on (to the lock face, the mail on it) for a moment. */
        private fun wake(context: Context) {
            val pm = context.getSystemService(PowerManager::class.java)
            if (pm.isInteractive) return
            runCatching {
                // HACK: ACQUIRE_CAUSES_WAKEUP and SCREEN_BRIGHT_WAKE_LOCK are deprecated (an app targeting 34+ gets them
                // ignored); this app targets 28 (W^X, see build.gradle.kts), where they still turn the screen on. Real fix
                // once the target moves up: a full-screen intent to PowOS's lock face (USE_FULL_SCREEN_INTENT).
                @Suppress("DEPRECATION")
                pm.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE, "powos:agent-mail")
                    .acquire(WAKE_MS)
            }.onFailure { Log.w(TAG, "can't wake the screen for urgent mail", it) }
        }

        private const val WAKE_MS = 5_000L

        /** When each sender's last urgent mail alerted (ms): at most one per [URGENT_WINDOW_MS] per sender. */
        private val urgentAlerted = HashMap<String, Long>()
        private const val URGENT_WINDOW_MS = 10 * 60_000L

        /**
         * An urgent mail: it alerts (banner, screen, vibration, the sound with the ringer on) unless its sender's last one
         * alerted under [URGENT_WINDOW_MS] ago - then it's collapsed into that one's notification if still unread (its
         * text and count updated), silently: no sound, vibration or banner.
         */
        private fun arrivedUrgent(
            context: Context,
            mail: Mail,
        ) {
            val now = System.currentTimeMillis()
            val last = urgentAlerted[mail.from]
            if (last == null || now - last >= URGENT_WINDOW_MS) {
                urgentAlerted[mail.from] = now
                add(mail)
                post(context, mail, quiet = false)
                return
            }
            // The sender's unread urgent notification, if there's one: this joins it.
            val lead = store.firstOrNull { !it.read && it.priority == "urgent" && it.from == mail.from && it.lead.isEmpty() }
            val joined = if (lead != null) mail.copy(lead = lead.id) else mail
            add(joined)
            val count = store.count { !it.read && it.notificationId == joined.notificationId }
            post(context, if (count > 1) joined.copy(text = "($count) ${joined.text}") else joined, quiet = true)
            Log.i(TAG, "urgent from ${mail.from} within ${URGENT_WINDOW_MS / 60_000} min of the last: collapsed, silent ($count)")
        }

        /**
         * An urgent mail's alert besides its banner: the screen on, a vibration, and the alarm-stream sound - only with
         * the ringer on (normal mode); vibrate mode vibrates only, silent too (the user chose no sound, not no alert).
         * Nothing in Do not disturb's total silence. The vibration is the app's own (as an alarm): the system drops a
         * notification's vibration on silent (seen on the phone: notification_alert buzz=0).
         */
        fun alertUrgent(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.currentInterruptionFilter == NotificationManager.INTERRUPTION_FILTER_NONE) return
            wake(context)
            val audio = context.getSystemService(android.media.AudioManager::class.java)
            if (audio.ringerMode == android.media.AudioManager.RINGER_MODE_NORMAL) {
                runCatching {
                    android.media.RingtoneManager.getRingtone(context, Settings.System.DEFAULT_NOTIFICATION_URI)?.apply {
                        audioAttributes =
                            AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
                        play()
                    }
                }.onFailure { Log.w(TAG, "can't play the urgent sound", it) }
            }
            runCatching {
                val vibrator =
                    if (Build.VERSION.SDK_INT >= 31) {
                        context.getSystemService(android.os.VibratorManager::class.java).defaultVibrator
                    } else {
                        context.getSystemService(android.os.Vibrator::class.java)
                    }
                val effect = android.os.VibrationEffect.createWaveform(URGENT_VIBRATION, -1)
                if (Build.VERSION.SDK_INT >= 33) {
                    vibrator.vibrate(effect, android.os.VibrationAttributes.createForUsage(android.os.VibrationAttributes.USAGE_ALARM))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(effect, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
                }
            }.onFailure { Log.w(TAG, "can't vibrate for urgent mail", it) }
        }

        private val URGENT_VIBRATION = longArrayOf(0, 350, 150, 350, 150, 600)

        /** The chat opened from a mail's notification: that mail read, and in the chat (which doesn't have it otherwise). */
        fun opened(
            context: Context,
            intent: Intent?,
        ) {
            val id = intent?.getStringExtra(EXTRA_MAIL) ?: return
            intent.removeExtra(EXTRA_MAIL)
            load(context.applicationContext)
            val mail = store.firstOrNull { it.id == id } ?: return
            read(context, id)
            // Once: PowOS's shade's tap may have swiped it read already (its delete intent) by the time the chat comes up.
            if (inChat.add(id)) PowosAiChat.mail(context, mail.from, mail.text)
        }

        /** Mail put in the chat since the app started. */
        private val inChat = HashSet<String>()

        /**
         * [id] read by the user (a tap, a reply, a swipe, the feed's dismiss): kept as read, not posted again, its
         * notification gone, and out of the user's comms inbox - one read state for the shade, the notification, the
         * PowOS AI page's feed and comms.
         */
        fun read(
            context: Context,
            id: String,
        ) {
            if (id.isEmpty()) return
            main.post { markRead(context, listOf(id), fromComms = false) }
        }

        /** Every unread mail read (the feed's "clear all"). */
        fun readAll(context: Context) {
            main.post {
                load(context.applicationContext)
                markRead(context, store.filter { !it.read }.map { it.id }, fromComms = false)
            }
        }

        /** On the main thread. [fromComms]: comms said so - it needn't be told back. */
        private fun markRead(
            context: Context,
            ids: List<String>,
            fromComms: Boolean,
        ) {
            val app = context.applicationContext
            load(app)
            val nm = app.getSystemService(NotificationManager::class.java)
            val newly = ArrayList<String>()
            // A collapsed urgent notification stands for all its mail: reading one reads them all.
            val shared = store.filter { it.id in ids }.map { it.notificationId }.toSet()
            for (i in store.indices) {
                val m = store[i]
                if (m.read || (m.id !in ids && m.notificationId !in shared)) continue
                store[i] = m.copy(read = true)
                nm.cancel(TAG, m.notificationId)
                newly += m.id
            }
            if (newly.isEmpty()) return
            changed()
            if (fromComms || !RootedGuest.enabled) return
            // Out of the user's inbox too (comms ids: the ones it sent; others aren't there and are ignored).
            Thread({
                runCatching { RootedGuest.run("powos comms read --agent user ${newly.joinToString(" ") { shellQuote(it) }}") }
                    .onFailure { Log.w(TAG, "can't mark ${newly.size} read in comms", it) }
            }, "agent-mail-read").start()
        }

        private fun add(mail: Mail) {
            store.add(0, mail)
            changed()
        }

        /** Saved, trimmed, and [recent] brought up to date. */
        private fun changed() {
            var read = 0
            var unread = 0
            store.retainAll { if (it.read) ++read <= KEEP_READ else ++unread <= KEEP_UNREAD }
            val shown = unread()
            if (recent.toList() != shown) {
                recent.clear()
                recent.addAll(shown)
            }
            val f = file ?: return
            runCatching {
                f.parentFile?.mkdirs()
                val tmp = File(f.path + ".tmp")
                tmp.writeText(JSONArray(store.map { it.json() }).toString())
                tmp.renameTo(f)
            }.onFailure { Log.w(TAG, "can't save agent mail", it) }
        }

        private fun load(context: Context) {
            if (file != null) return
            val f = File(context.filesDir, "powos-ai/agent-mail.json")
            file = f
            runCatching {
                val a = JSONArray(f.readText())
                for (i in 0 until a.length()) store += Mail.from(a.getJSONObject(i))
            }
            store.sortByDescending { it.time }
            recent.clear()
            recent.addAll(unread())
        }

        /** What the feed shows: the unread mail, newest first - read is read, wherever it was read. */
        private fun unread() = store.filter { !it.read }.take(KEEP_SHOWN)

        /**
         * Watches [runDir]/agent-mail (the PowOS session's /run/powos-app/agent-mail); mail already there is posted, and
         * unread mail whose notification is gone (an update, a force stop) is posted again, quietly.
         */
        fun start(
            context: Context,
            runDir: File,
        ) {
            if (watcher != null) return
            val app = context.applicationContext
            load(app)
            ensureChannels(app)
            val active =
                runCatching {
                    app.getSystemService(NotificationManager::class.java).activeNotifications.filter { it.tag == TAG }.map { it.id }.toSet()
                }.getOrDefault(emptySet())
            store.filter { !it.read && it.notificationId !in active }.asReversed().forEach { runCatching { post(app, it, quiet = true) } }
            val dir = File(runDir, "agent-mail").apply { mkdirs() }
            val w = AgentMail(app, dir)
            watcher = w
            w.startWatching()
            dir.listFiles { f -> f.name.endsWith(".json") }?.sortedBy { it.name }?.forEach { runCatching { w.arrived(it) } }
            Log.i(TAG, "watching $dir (${store.count { !it.read }} unread)")
        }
    }
}
