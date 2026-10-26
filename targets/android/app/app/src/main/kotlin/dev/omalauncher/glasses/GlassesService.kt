package dev.omalauncher.glasses

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.companion.CompanionDeviceService
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import dev.omalauncher.R
import dev.omalauncher.shell.ShellActivity
import org.json.JSONObject

/**
 * Keeps the glasses' connection while it's wanted: a foreground service (connected device), its notification saying
 * how the glasses are. It holds no state of its own - [Glasses] does; this is the process's claim to stay up with a
 * link open while nothing else of PowOS is in front. Started by [Glasses.connect], stopped by [Glasses.disconnect].
 */
class GlassesService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Glasses", NotificationManager.IMPORTANCE_MIN))
        val note = notification(this, text(Glasses.state()))
        if (Build.VERSION.SDK_INT >= 29) startForeground(ID, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE) else startForeground(ID, note)
        Glasses.init(this)
        return START_STICKY
    }

    companion object {
        private const val TAG = "PowosGlasses"
        private const val CHANNEL = "glasses"
        private const val ID = 0x61a5

        fun start(context: Context) {
            runCatching { context.startForegroundService(Intent(context, GlassesService::class.java)) }
                .onFailure { Log.w(TAG, "glasses service not started", it) }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, GlassesService::class.java))
        }

        /** The notification follows the state, while the service runs. */
        fun update(
            context: Context,
            s: JSONObject,
        ) {
            if (!s.optBoolean("wanted")) return
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.activeNotifications.none { it.id == ID }) return
            nm.notify(ID, notification(context, text(s)))
        }

        private fun text(s: JSONObject): String {
            val model = s.optJSONObject("paired")?.optString("model") ?: "Glasses"
            return when (s.optString("phase")) {
                "ready" -> "$model connected" + (if (s.optBoolean("mic")) " · mic on" else "") + (if (!s.optBoolean("shown", true)) " · off the face" else "")
                "connecting" -> "$model connecting…"
                else -> "$model waiting to be in range"
            }
        }

        private fun notification(
            context: Context,
            text: String,
        ): Notification {
            val open =
                PendingIntent.getActivity(context, 0, Intent(context, ShellActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(text)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        }
    }
}

/**
 * Android's companion presence for the paired arms (Glasses' pairing asked it to watch them): an arm is in range again
 * - the glasses connect, if they're wanted. No scanning or polling of ours: the system tells us.
 */
@android.annotation.TargetApi(33)
class GlassesPresenceService : CompanionDeviceService() {
    @Deprecated("API 33+ has onDeviceAppeared(AssociationInfo); this one is the API 31-32 path and still called")
    override fun onDeviceAppeared(address: String) {
        Glasses.init(this)
        Glasses.appeared(address)
    }

    override fun onDeviceAppeared(info: android.companion.AssociationInfo) {
        Glasses.init(this)
        info.deviceMacAddress?.toString()?.uppercase()?.let { Glasses.appeared(it) }
    }
}
