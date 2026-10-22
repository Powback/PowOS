package dev.omalauncher.widgets.runtime

import android.app.ActivityOptions
import android.app.Notification
import android.app.NotificationManager
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.UserHandle
import android.service.notification.NotificationListenerService.Ranking
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
        /** Its buttons, in order ([action]'s index): their labels, and whether one takes typed text (a reply). */
        val actions: List<Action> = emptyList(),
        /** Notification.category: "alarm" and "call" keep a banner up longer. */
        val category: String? = null,
        /** The app's group (Notification.getGroup, its bundle; the summary itself is never listed), null: none. */
        val group: String? = null,
        /** A conversation (MessagingStyle, or a shortcut-backed message): the shade shows it on its own. */
        val conversation: Boolean = false,
    )

    data class Action(
        val title: String,
        val input: Boolean,
    )

    /** [sbn] as listed. */
    fun item(sbn: StatusBarNotification) =
        Item(
            sbn.key,
            label(sbn.packageName),
            sbn.packageName,
            profile(sbn.user),
            title(sbn).orEmpty(),
            text(sbn).orEmpty(),
            sbn.postTime / 1000,
            sbn.isClearable,
            sbn.notification.actions.orEmpty().map { a ->
                Action(a.title?.toString().orEmpty(), a.remoteInputs.orEmpty().any { it.allowFreeFormInput })
            },
            sbn.notification.category,
            sbn.notification.group,
            sbn.notification.extras.getString(Notification.EXTRA_TEMPLATE) == "android.app.Notification\$MessagingStyle" ||
                (sbn.notification.category == Notification.CATEGORY_MESSAGE && sbn.notification.shortcutId != null),
        )

    /** Keys of what had a banner (the time it was posted), for once-only alerts' updates. */
    private val alerted = HashMap<String, Long>()

    /**
     * Whether [sbn], just posted, gets a heads-up banner - as SystemUI decides it (its VisualInterruptionDecisionProvider),
     * for PowOS's shade, which shows the banner while SystemUI's is off: important enough (IMPORTANCE_HIGH), not held
     * back by Do not disturb, not a silent or once-only update, not a group's other half by its alert behavior.
     */
    fun peeks(
        sbn: StatusBarNotification,
        ranking: Ranking,
    ): Boolean {
        val n = sbn.notification
        val before = alerted[sbn.key]
        if (alerted.size > MAX_ALERTED) {
            val live = runCatching { MediaListener.connected?.activeNotifications?.map { it.key }?.toSet() }.getOrNull().orEmpty()
            alerted.keys.retainAll(live)
        }
        if (ranking.importance < NotificationManager.IMPORTANCE_HIGH) return false
        if (!ranking.matchesInterruptionFilter()) return false
        if (ranking.suppressedVisualEffects and NotificationManager.Policy.SUPPRESSED_EFFECT_PEEK != 0) return false
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return false
        if (n.flags and Notification.FLAG_ONGOING_EVENT != 0 && n.category != Notification.CATEGORY_CALL) return false
        val summary = n.flags and Notification.FLAG_GROUP_SUMMARY != 0
        // setSilent(true) is a group child that leaves the alert to its summary; a summary may say the same of its children.
        if (n.group != null && !summary && n.groupAlertBehavior == Notification.GROUP_ALERT_SUMMARY) return false
        if (summary && n.groupAlertBehavior != Notification.GROUP_ALERT_SUMMARY) return false
        if (n.extras.getBoolean(EXTRA_QUIET)) return false
        if (n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0 && before != null) return false
        if (title(sbn) == null && text(sbn) == null) return false
        alerted[sbn.key] = sbn.postTime
        return true
    }

    /**
     * Presses [key]'s action [index] - with [text] typed into it when it takes a reply (its RemoteInputs, as SystemUI's
     * inline reply fills them).
     */
    fun action(
        key: String,
        index: Int,
        text: String?,
    ) {
        val listener = MediaListener.connected
        if (!media.granted || listener == null) return
        val sbn = runCatching { listener.getActiveNotifications(arrayOf(key)) }.getOrNull()?.firstOrNull() ?: return
        val action = sbn.notification.actions?.getOrNull(index) ?: return
        val fill = Intent()
        val inputs = action.remoteInputs.orEmpty().filter { it.allowFreeFormInput }.toTypedArray()
        if (text != null && inputs.isNotEmpty()) {
            val results = Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, text) } }
            RemoteInput.addResultsToIntent(inputs, fill, results)
            RemoteInput.setResultsSource(fill, RemoteInput.SOURCE_FREE_FORM_INPUT)
        }
        runCatching { action.actionIntent.send(context, 0, fill, null, null, null, startOptions()) }
    }

    /** The launcher is in front, so it may start the app; since Android 14 it has to say so. */
    private fun startOptions() =
        // Unfolded: the app opens in a floating window, as from the dock (AppWindows).
        dev.omalauncher.system.AppWindows.bundle(
            context,
            if (Build.VERSION.SDK_INT >= 34) {
                @Suppress("DEPRECATION")
                ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
            } else {
                null
            },
        )

    /** Whether the launcher may read notifications (the user granted it notification access). */
    val available get() = media.granted && MediaListener.connected != null

    /** The notifications shown, newest first; empty without access. */
    fun items(): List<Item> =
        (if (available) shown() else emptyList()).take(MAX_ITEMS).map(::item)

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
                runCatching { intent.send(context, 0, null, null, null, null, startOptions()) }
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
        private const val MAX_ALERTED = 200

        /** In a notification's extras: posted again quietly (dev.omalauncher.AgentMail) - no banner for it. */
        const val EXTRA_QUIET = "powos.quiet"
    }
}
