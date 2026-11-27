package dev.omalauncher.system

import android.app.ActivityOptions
import android.app.Notification
import android.content.Context
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.service.notification.StatusBarNotification
import dev.omalauncher.widgets.runtime.MediaListener
import org.json.JSONArray
import org.json.JSONObject

/**
 * Live activities round the camera ring (shell/ui/chrome.tsx LiveIsland; board `live-activities-around-the-camera-ring`,
 * docs/research/stock-parity-gaps.md): what's going on now, read from the ongoing notifications the launcher's
 * listener already gets - no root, no extra permission. A media player that plays, a call, a timer / stopwatch
 * (a chronometer notification), something with progress (a download, a ship, a PowOS AI task) and Android 16's
 * promoted "live updates". The page draws the first; a tap runs its notification's tap action ([open]).
 */
object LiveActivities {
    /** A chronometer: [base] the notification's `when` (epoch ms) - counting up from it, or down to it. */
    data class Clock(val base: Long, val countDown: Boolean)

    /** Notification progress: [value] of [max], or [indeterminate]. */
    data class Progress(val value: Int, val max: Int, val indeterminate: Boolean)

    /** What one notification says about itself. [playing] null: not a media player's. */
    data class Signals(
        val ongoing: Boolean,
        val category: String? = null,
        val playing: Boolean? = null,
        val clock: Clock? = null,
        val progress: Progress? = null,
        val promoted: Boolean = false,
    )

    /** A notification as read ([raw]), or as shown with its [kind] (call, timer, progress, live, media). */
    data class Item(val key: String, val pkg: String, val kind: String?, val title: String?, val text: String?, val signals: Signals)

    /** The order shown (the pill draws the first): a call first, a paused player never. */
    private val RANK = listOf("call", "timer", "progress", "live", "media")

    /** [item]'s kind, null when it's nothing live: a plain ongoing one (a VPN, "USB debugging") or a finished download. */
    fun kind(item: Item): String? {
        val s = item.signals
        return when {
            s.playing == true -> "media"
            !s.ongoing || s.playing == false -> null
            s.category == "call" -> "call"
            s.clock != null -> "timer"
            running(s.progress) -> "progress"
            s.promoted && item.title != null -> "live"
            else -> null
        }
    }

    /** Progress still going: indeterminate, or short of its max. */
    private fun running(p: Progress?) = p != null && (p.indeterminate || (p.max > 0 && p.value < p.max))

    /** The live ones of [items] (newest first), in [RANK] order; within a kind newest first. */
    fun pick(items: List<Item>): List<Item> =
        items.mapNotNull { i -> kind(i)?.let { i.copy(kind = it) } }.sortedBy { RANK.indexOf(it.kind) }

    /** The shade's live ones now (none without notification access). */
    fun read(context: Context): List<Item> {
        val listener = MediaListener.connected ?: return emptyList()
        val all = runCatching { listener.activeNotifications }.getOrNull().orEmpty()
        return pick(all.filter { it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 }.sortedByDescending { it.postTime }.map { raw(context, it) })
    }

    private fun raw(context: Context, sbn: StatusBarNotification): Item {
        val n = sbn.notification
        val e = n.extras
        val max = e.getInt(Notification.EXTRA_PROGRESS_MAX)
        val indeterminate = e.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE)
        val signals =
            Signals(
                ongoing = n.flags and (Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE) != 0,
                category = n.category,
                playing = playing(context, e),
                clock = if (e.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER)) Clock(n.`when`, e.getBoolean(Notification.EXTRA_CHRONOMETER_COUNT_DOWN)) else null,
                progress = if (max > 0 || indeterminate) Progress(e.getInt(Notification.EXTRA_PROGRESS), max, indeterminate) else null,
                // Android 16's promoted ongoing ("live updates"): the app asked for it (Notification.Builder.setRequestPromotedOngoing).
                promoted = e.getBoolean("android.requestPromotedOngoing"),
            )
        fun str(k: String) = e.getCharSequence(k)?.toString()?.takeIf { it.isNotBlank() }
        return Item(sbn.key, sbn.packageName, null, str(Notification.EXTRA_TITLE), str(Notification.EXTRA_TEXT), signals)
    }

    /** A media player's notification: whether its session plays now. Null when it names no session. */
    private fun playing(context: Context, e: Bundle): Boolean? {
        val token =
            runCatching {
                if (Build.VERSION.SDK_INT >= 33) {
                    e.getParcelable(Notification.EXTRA_MEDIA_SESSION, MediaSession.Token::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    e.getParcelable(Notification.EXTRA_MEDIA_SESSION)
                }
            }.getOrNull() ?: return null
        return runCatching { MediaController(context, token).playbackState?.state == PlaybackState.STATE_PLAYING }.getOrDefault(false)
    }

    private val labels = java.util.concurrent.ConcurrentHashMap<String, String>()

    private fun label(context: Context, pkg: String) =
        labels.getOrPut(pkg) {
            runCatching { context.packageManager.run { getApplicationLabel(getApplicationInfo(pkg, 0)).toString() } }.getOrDefault(pkg)
        }

    /** ChromeState.live (shell/types.ts LiveActivity): the first few, enough for the pill and its count. */
    fun json(context: Context, items: List<Item>): JSONArray =
        JSONArray(
            items.take(MAX).map { i ->
                val s = i.signals
                JSONObject().put("key", i.key).put("kind", i.kind).put("app", label(context, i.pkg))
                    .put("title", i.title ?: JSONObject.NULL).put("text", i.text ?: JSONObject.NULL)
                    .apply {
                        s.clock?.let { put("clock", JSONObject().put("base", it.base).put("down", it.countDown)) }
                        s.progress?.let { p -> put("progress", if (p.indeterminate || p.max <= 0) JSONObject.NULL else p.value.toDouble() / p.max) }
                    }
            },
        )

    /** The pill's tap: [key]'s notification's tap action - its app, opened as from the shade (Notifications.control "open"). */
    fun open(context: Context, key: String) {
        val listener = MediaListener.connected ?: return
        val sbn = runCatching { listener.getActiveNotifications(arrayOf(key)) }.getOrNull()?.firstOrNull() ?: return
        val intent = sbn.notification.contentIntent ?: return
        val options =
            if (Build.VERSION.SDK_INT >= 34) {
                @Suppress("DEPRECATION")
                ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
            } else {
                null
            }
        runCatching { AppWindows.send(context, intent, null, options) }
    }

    private const val MAX = 4
}
