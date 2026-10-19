package dev.omalauncher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.FileObserver
import android.util.Log
import androidx.compose.runtime.mutableStateListOf
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.linux.shellQuote
import org.json.JSONObject
import java.io.File

/**
 * PowOS AI's agents reaching the user on the phone: what they send the user (`notify_user`, `powos comms notify`)
 * arrives in the run dir's agent-mail/ (lib/ai/comms/comms-mcp.py, on a phone) and becomes an Android notification -
 * tap it for the chat, or answer inline: the reply goes to that agent's inbox (`powos comms send <agent> <text>`).
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
        post(File(dir, path))
    }

    private fun post(file: File) {
        val mail = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return
        file.delete()
        val from = mail.optString("from").ifBlank { "manager" }
        val text = mail.optString("text")
        // Kept for the launcher's PowOS AI page as well as notified, newest first.
        recent.add(0, Mail(from, text, System.currentTimeMillis() / 1000))
        while (recent.size > KEEP) recent.removeAt(recent.lastIndex)
        val urgent = mail.optString("priority") in setOf("high", "urgent")
        val id = (System.currentTimeMillis() and 0x7fffffff).toInt()
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "PowOS AI agents", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "What PowOS AI's agents tell you; reply inline to answer them"
            },
        )
        val open =
            PendingIntent.getActivity(
                context,
                id,
                Intent(context, PowosAiActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE,
            )
        val reply =
            PendingIntent.getBroadcast(
                context,
                id,
                Intent(context, Reply::class.java).putExtra(EXTRA_AGENT, from).putExtra(EXTRA_ID, id),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        val action =
            Notification.Action.Builder(null, "Reply", reply)
                .addRemoteInput(RemoteInput.Builder(KEY_TEXT).setLabel("Reply to $from").build())
                .build()
        nm.notify(
            TAG,
            id,
            Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("PowOS AI · $from")
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(open)
                .setAutoCancel(true)
                .addAction(action)
                .setCategory(if (urgent) Notification.CATEGORY_ALARM else Notification.CATEGORY_MESSAGE)
                .build(),
        )
    }

    /** An inline reply: to the agent's inbox, then the notification says so. */
    class Reply : BroadcastReceiver() {
        override fun onReceive(
            context: Context,
            intent: Intent,
        ) {
            val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_TEXT)?.toString()?.trim() ?: return
            val agent = intent.getStringExtra(EXTRA_AGENT) ?: return
            val id = intent.getIntExtra(EXTRA_ID, 0)
            val pending = goAsync()
            Thread({
                val ok =
                    runCatching {
                        RootedGuest.run("powos comms send ${shellQuote(agent)} ${shellQuote(text)}") == 0
                    }.getOrDefault(false)
                context.getSystemService(NotificationManager::class.java).notify(
                    TAG,
                    id,
                    Notification.Builder(context, CHANNEL)
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle("PowOS AI · $agent")
                        .setContentText(if (ok) "You: $text" else "Couldn't send your reply to $agent")
                        .setTimeoutAfter(if (ok) 4000 else 0)
                        .build(),
                )
                pending.finish()
            }, "agent-mail-reply").start()
        }
    }

    /** What an agent told the user: who, what, when (Unix seconds). */
    data class Mail(
        val from: String,
        val text: String,
        val time: Long,
    )

    companion object {
        /** The latest mail since the app started, newest first (the launcher's PowOS AI page lists it). */
        val recent = mutableStateListOf<Mail>()
        private const val KEEP = 30

        private const val TAG = "agent-mail"
        private const val CHANNEL = "powos-ai-agents"
        private const val KEY_TEXT = "text"
        private const val EXTRA_AGENT = "agent"
        private const val EXTRA_ID = "id"
        private var watcher: AgentMail? = null

        /** Watches [runDir]/agent-mail (the PowOS session's /run/powos-app/agent-mail); mail already there is posted. */
        fun start(
            context: Context,
            runDir: File,
        ) {
            if (watcher != null) return
            val dir = File(runDir, "agent-mail").apply { mkdirs() }
            val w = AgentMail(context.applicationContext, dir)
            watcher = w
            w.startWatching()
            dir.listFiles { f -> f.name.endsWith(".json") }?.sortedBy { it.name }?.forEach { runCatching { w.post(it) } }
            Log.i(TAG, "watching $dir")
        }
    }
}
