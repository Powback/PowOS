package dev.omalauncher.widgets.runtime

import android.app.ActivityOptions
import android.app.Notification
import android.content.Context
import android.os.Build
import android.os.UserHandle
import android.service.notification.StatusBarNotification
import dev.omalauncher.widgets.lang.Lst
import dev.omalauncher.widgets.lang.Null
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Str
import dev.omalauncher.widgets.lang.Value
import dev.omalauncher.widgets.lang.bool
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * The phone's notifications, for `source n = android.notifications`, and
 * `notification("open" | "dismiss", key)`. Read through [MediaListener], so
 * they need the same notification access as media widgets. Nothing is kept:
 * each update reads what's in the shade now.
 */
class Notifications(
    private val context: Context,
    private val media: Media,
    /** "work" or "clone" for a profile beside the launcher's own, null for its own. */
    private val profile: (UserHandle) -> String?,
) {
    /** App labels by package; the lookup is a binder call. */
    private val labels = HashMap<String, String>()

    /** What a widget lists: not ongoing ones (music, downloads, the launcher's own service) or group headers. */
    private fun shown(): List<StatusBarNotification> {
        val listener = MediaListener.connected ?: return emptyList()
        val all = runCatching { listener.activeNotifications }.getOrNull().orEmpty()
        val hidden = Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE or Notification.FLAG_GROUP_SUMMARY
        return all.filter { it.notification.flags and hidden == 0 && (title(it) != null || text(it) != null) }.sortedByDescending { it.postTime }
    }

    private fun title(sbn: StatusBarNotification) = sbn.notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.takeIf { it.isNotBlank() }

    private fun text(sbn: StatusBarNotification) = sbn.notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.takeIf { it.isNotBlank() }

    private fun label(pkg: String) =
        labels.getOrPut(pkg) {
            runCatching {
                val pm = context.packageManager
                pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
            }.getOrDefault(pkg)
        }

    /** A notification as shown: [profile] is "work" or "clone" beside the launcher's own profile, else null. */
    data class Item(
        val key: String,
        val app: String,
        val pkg: String,
        val profile: String?,
        val title: String,
        val text: String,
        /** Unix seconds. */
        val time: Long,
        val clearable: Boolean,
    )

    /** Whether the launcher may read notifications (the user granted it notification access). */
    val available get() = media.granted && MediaListener.connected != null

    /** The notifications shown, newest first; empty without access. */
    fun items(): List<Item> =
        (if (available) shown() else emptyList()).take(MAX_ITEMS).map { sbn ->
            Item(sbn.key, label(sbn.packageName), sbn.packageName, profile(sbn.user), title(sbn).orEmpty(), text(sbn).orEmpty(), sbn.postTime / 1000, sbn.isClearable)
        }

    fun value(): Value {
        val items =
            items().map { n ->
                Obj(
                    mapOf(
                        "key" to Str(n.key),
                        "app" to Str(n.app),
                        "package" to Str(n.pkg),
                        // From a work profile or a cloned app; icon is the app's icon from that profile, badge included.
                        "profile" to (n.profile?.let(::Str) ?: Null),
                        "icon" to Str("app:" + n.pkg + (n.profile?.let { "@$it" } ?: "")),
                        "title" to Str(n.title),
                        "text" to Str(n.text),
                        "time" to Num(n.time.toDouble()),
                        "clearable" to bool(n.clearable),
                    ),
                )
            }
        return Obj(mapOf("available" to bool(available), "count" to Num(items.size.toDouble()), "items" to Lst(items)))
    }

    fun updates(): Flow<Value> = MediaListener.changes.map { value() }.distinctUntilChanged()

    /** "open" runs the notification's tap action, "dismiss" clears it; without access, opens the setting that grants it. */
    fun control(
        command: String,
        key: String,
    ) {
        val listener = MediaListener.connected
        if (!media.granted || listener == null) return media.openAccessSettings()
        val sbn = runCatching { listener.getActiveNotifications(arrayOf(key)) }.getOrNull()?.firstOrNull() ?: return
        when (command) {
            "open" -> {
                val intent = sbn.notification.contentIntent ?: return
                // The launcher is in front, so it may start the app; since Android 14 it has to say so.
                val options =
                    if (Build.VERSION.SDK_INT >= 34) {
                        @Suppress("DEPRECATION")
                        ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED).toBundle()
                    } else {
                        null
                    }
                runCatching { intent.send(context, 0, null, null, null, null, options) }
                if (sbn.notification.flags and Notification.FLAG_AUTO_CANCEL != 0) listener.cancelNotification(key)
            }
            "dismiss" -> listener.cancelNotification(key)
        }
    }

    /** Clears every notification that can be cleared, as the shade's "clear all". */
    fun clearAll() {
        val listener = MediaListener.connected ?: return
        if (media.granted) runCatching { listener.cancelAllNotifications() }
    }

    /** Opens the setting that grants the launcher notification access. */
    fun askAccess() = media.openAccessSettings()

    companion object {
        private const val MAX_ITEMS = 50
    }
}
