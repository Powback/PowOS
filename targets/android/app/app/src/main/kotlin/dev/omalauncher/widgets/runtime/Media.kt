package dev.omalauncher.widgets.runtime

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.NotificationListenerService.Ranking
import android.service.notification.NotificationListenerService.RankingMap
import android.service.notification.StatusBarNotification
import dev.omalauncher.widgets.lang.Null
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Str
import dev.omalauncher.widgets.lang.Value
import dev.omalauncher.widgets.lang.bool
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Notification access, which the user grants in Android's settings. Android
 * requires it before an app may see other apps' media sessions (android.media),
 * and it lets widgets list notifications (android.notifications). Notifications
 * are only read when a widget asks; see [Notifications].
 */
class MediaListener : NotificationListenerService() {
    override fun onListenerConnected() {
        connected = this
        changes.update { it + 1 }
    }

    override fun onListenerDisconnected() {
        if (connected === this) connected = null
        changes.update { it + 1 }
    }

    override fun onNotificationPosted(
        sbn: StatusBarNotification?,
        rankingMap: RankingMap?,
    ) {
        changes.update { it + 1 }
        // A new one, with how the system ranks it (its importance, whether Do not disturb holds it back): PowOS's
        // shade's heads-up banner decides with it (system/ShadeHost.peek).
        val to = posted ?: return
        if (sbn == null || rankingMap == null) return
        val ranking = Ranking()
        if (rankingMap.getRanking(sbn.key, ranking)) to(sbn, ranking)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        changes.update { it + 1 }
    }

    override fun onDestroy() {
        if (connected === this) connected = null
        super.onDestroy()
    }

    companion object {
        /** The listener Android has bound, while it's bound. */
        @Volatile
        var connected: MediaListener? = null
            private set

        /** Bumped whenever the notifications or the connection change. */
        val changes = MutableStateFlow(0)

        /** Told of each notification posted (on the main thread), with its ranking: PowOS's shade's banner. */
        @Volatile
        var posted: ((StatusBarNotification, Ranking) -> Unit)? = null
    }
}

/** What's playing on the phone, for `source m = android.media`, and play/pause/skip for `media(...)`. */
class Media(
    private val context: Context,
) {
    private val component = ComponentName(context, MediaListener::class.java)
    private val sessions = context.getSystemService(MediaSessionManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val main = Handler(Looper.getMainLooper())

    val granted get() = notifications.isNotificationListenerAccessGranted(component)

    /** Album art by the id widgets see in `art`; only the current track's is kept. */
    private var art: Pair<String, Bitmap>? = null

    /** What [art] was taken for: the app, the track and the art's size. */
    private var artTrack: List<Any?>? = null
    private var artSerial = 0

    fun art(src: String): Bitmap? = art?.takeIf { it.first == src }?.second

    /** The session to show and control: the one playing, else the most recent. */
    private fun controller(): MediaController? {
        if (!granted) return null
        val all = runCatching { sessions.getActiveSessions(component) }.getOrNull().orEmpty()
        return all.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: all.firstOrNull()
    }

    fun value(): Value {
        val c = controller() ?: return Obj(mapOf("available" to bool(granted), "playing" to bool(false)))
        val m = c.metadata
        val s = c.playbackState
        val playing = s?.state == PlaybackState.STATE_PLAYING
        val position =
            s?.let {
                val drift = if (playing && it.lastPositionUpdateTime > 0) (SystemClock.elapsedRealtime() - it.lastPositionUpdateTime) * it.playbackSpeed else 0f
                ((it.position + drift) / 1000.0).coerceAtLeast(0.0)
            }
        val duration = m?.getLong(MediaMetadata.METADATA_KEY_DURATION)?.takeIf { it > 0 }?.let { it / 1000.0 }
        val bitmap =
            m?.let {
                it.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
                    ?: it.getBitmap(MediaMetadata.METADATA_KEY_ART)
                    ?: it.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            }
        fun text(key: String) = m?.getString(key)?.takeIf { it.isNotBlank() }?.let(::Str) ?: Null
        // Every c.metadata is a fresh parcel with a fresh Bitmap, and this runs every second while playing:
        // keep the art for as long as the track (and the art's size) stays the same, so its id doesn't change
        // each tick and the widget doesn't swap, and briefly lose, the image.
        val artKey =
            bitmap?.let { b ->
                val track = listOf(MediaMetadata.METADATA_KEY_MEDIA_ID, MediaMetadata.METADATA_KEY_TITLE, MediaMetadata.METADATA_KEY_ARTIST, MediaMetadata.METADATA_KEY_ALBUM).map { m.getString(it) }
                listOf(c.packageName, track, b.width, b.height)
            }
        if (artKey != artTrack) {
            artTrack = artKey
            art = bitmap?.let { "media:art:${++artSerial}" to it }
        }
        val artSrc = art?.first
        val app =
            labels.getOrPut(c.packageName) {
                runCatching {
                    val pm = context.packageManager
                    pm.getApplicationLabel(pm.getApplicationInfo(c.packageName, 0)).toString()
                }.getOrDefault(c.packageName)
            }
        return Obj(
            mapOf(
                "available" to bool(true),
                "playing" to bool(playing),
                "title" to (text(MediaMetadata.METADATA_KEY_TITLE).takeIf { it != Null } ?: text(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)),
                "artist" to (text(MediaMetadata.METADATA_KEY_ARTIST).takeIf { it != Null } ?: text(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)),
                "album" to text(MediaMetadata.METADATA_KEY_ALBUM),
                "app" to Str(app),
                "package" to Str(c.packageName),
                "position" to (position?.let { Num(Math.floor(it)) } ?: Null),
                "duration" to (duration?.let { Num(Math.floor(it)) } ?: Null),
                "art" to (artSrc?.let(::Str) ?: Null),
            ),
        )
    }

    /**
     * Emits whenever the session, track or playback state changes, and every
     * second while playing so `position` moves. Picks up access granted later.
     */
    fun updates(): Flow<Value> =
        callbackFlow {
            // Every active session is watched, not only the one shown: another one starting to play is an event. A 5 s
            // ticker used to look instead - three binder calls into system_server each time, for the app's whole life
            // once a control center had asked (perf, 2026-10-22).
            val bound = HashMap<MediaSession.Token, MediaController>()
            val playing = MutableStateFlow(false)

            fun changed() {
                playing.value = synchronized(bound) { bound.values.any { it.playbackState?.state == PlaybackState.STATE_PLAYING } }
                trySend(Unit)
            }
            val callback =
                object : MediaController.Callback() {
                    override fun onPlaybackStateChanged(state: PlaybackState?) = changed()

                    override fun onMetadataChanged(metadata: MediaMetadata?) = changed()

                    override fun onSessionDestroyed() = changed()
                }

            fun bind(list: List<MediaController>) =
                synchronized(bound) {
                    val tokens = list.mapTo(HashSet()) { it.sessionToken }
                    bound.entries.removeAll { (token, c) -> (token !in tokens).also { gone -> if (gone) c.unregisterCallback(callback) } }
                    for (c in list) if (bound.putIfAbsent(c.sessionToken, c) == null) c.registerCallback(callback, main)
                }
            val sessionsChanged =
                MediaSessionManager.OnActiveSessionsChangedListener { list ->
                    bind(list.orEmpty())
                    changed()
                }
            var listening = false

            fun listen() {
                if (listening || !granted) return
                listening = runCatching { sessions.addOnActiveSessionsChangedListener(sessionsChanged, component, main) }.isSuccess
                bind(runCatching { sessions.getActiveSessions(component) }.getOrNull().orEmpty())
            }
            listen()
            changed()
            // Access granted (or taken away) later: Android binds (or unbinds) the notification listener - an event too.
            val access =
                launch {
                    var connected = MediaListener.connected != null
                    MediaListener.changes.collect {
                        val now = MediaListener.connected != null
                        if (now == connected) return@collect
                        connected = now
                        listen()
                        changed()
                    }
                }
            // Every second while something plays, so `position` moves; no wake at all otherwise.
            val ticker =
                launch {
                    playing.collectLatest { on ->
                        while (on) {
                            delay(1000)
                            trySend(Unit)
                        }
                    }
                }
            awaitClose {
                access.cancel()
                ticker.cancel()
                synchronized(bound) {
                    bound.values.forEach { it.unregisterCallback(callback) }
                    bound.clear()
                }
                if (listening) sessions.removeOnActiveSessionsChangedListener(sessionsChanged)
            }
        }.conflate().map { value() }.distinctUntilChanged()

    /** media("toggle"), "play", "pause", "next", "previous"; without access, opens the setting that grants it. */
    fun control(command: String) {
        if (!granted) {
            openAccessSettings()
            return
        }
        val c = controller() ?: return
        val t = c.transportControls
        when (command) {
            "play" -> t.play()
            "pause" -> t.pause()
            "toggle" -> if (c.playbackState?.state == PlaybackState.STATE_PLAYING) t.pause() else t.play()
            "next" -> t.skipToNext()
            "previous" -> t.skipToPrevious()
            // send() throws CanceledException, which isn't a RuntimeException: the tap handler wouldn't catch it.
            "open" -> c.sessionActivity?.let { runCatching { it.send() } } ?: context.packageManager.getLaunchIntentForPackage(c.packageName)?.let { context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
    }

    fun openAccessSettings() {
        val list = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT < 30) return context.startActivity(list)
        // Straight to this app's switch where the phone supports it; some skins only have the list.
        val detail =
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, component.flattenToString())
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(detail) }.onFailure { context.startActivity(list) }
    }

    /** App labels by package: the lookup is a binder call, and value() runs every second while playing. */
    private val labels = HashMap<String, String>()
}
