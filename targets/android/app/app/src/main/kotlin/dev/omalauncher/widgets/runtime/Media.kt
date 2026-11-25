package dev.omalauncher.widgets.runtime

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
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
import dev.omalauncher.widgets.lang.Lst
import dev.omalauncher.widgets.lang.Obj
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

    /**
     * Album art by the id widgets and the control center see in `art`: each app's current track's only (the control
     * center shows up to two sessions at once), by package.
     */
    private val arts = HashMap<String, Art>()

    /** An app's art: what it was taken for (the track and the art's size), its id, the image. */
    private class Art(val track: List<Any?>, val src: String, val bitmap: Bitmap)
    private var artSerial = 0

    fun art(src: String): Bitmap? =
        if (src.startsWith(ACTION_ICON)) actionIcon(src) else synchronized(arts) { arts.values.firstOrNull { it.src == src }?.bitmap }

    private fun active(): List<MediaController> =
        if (!granted) emptyList() else runCatching { sessions.getActiveSessions(component) }.getOrNull().orEmpty()

    /** The session to show and control: [pkg]'s when named, else the one playing, else the most recent. */
    private fun controller(pkg: String? = null): MediaController? {
        val all = active()
        if (pkg != null) return all.firstOrNull { it.packageName == pkg }
        return all.firstOrNull { MediaShape.active(it.playbackState?.state ?: PlaybackState.STATE_NONE) } ?: all.firstOrNull()
    }

    fun value(): Value {
        val c = controller() ?: return Obj(mapOf("available" to bool(granted), "playing" to bool(false)))
        return describe(c)
    }

    /**
     * Every active session with a track, playing ones first, at most [max] (one per app): the control center's media
     * cards. Art of apps no longer listed is dropped.
     */
    fun sessions(max: Int = 2): Value {
        val all = active()
        val now = SystemClock.elapsedRealtime()
        val shown = MediaShape.order(all.map(::snap), max).map { MediaShape.describe(it, now) }
        val pkgs = all.mapTo(HashSet()) { it.packageName }
        synchronized(arts) { arts.keys.retainAll(pkgs) }
        return Lst(shown)
    }

    private fun describe(c: MediaController): Obj = MediaShape.describe(snap(c), SystemClock.elapsedRealtime())

    /** [c] read once (each getter is a binder call): what MediaShape maps to the page's state. */
    private fun snap(c: MediaController): MediaShape.Snap {
        val m = c.metadata
        val s = c.playbackState
        fun text(vararg keys: String) = keys.firstNotNullOfOrNull { k -> m?.getString(k)?.takeIf { it.isNotBlank() } }
        return MediaShape.Snap(
            pkg = c.packageName,
            app = label(c.packageName),
            state = s?.state ?: PlaybackState.STATE_NONE,
            positionMs = s?.position,
            updatedAt = s?.lastPositionUpdateTime ?: 0,
            speed = s?.playbackSpeed ?: 1f,
            actions = s?.actions ?: 0,
            title = text(MediaMetadata.METADATA_KEY_TITLE, MediaMetadata.METADATA_KEY_DISPLAY_TITLE),
            artist = text(MediaMetadata.METADATA_KEY_ARTIST, MediaMetadata.METADATA_KEY_ALBUM_ARTIST),
            album = text(MediaMetadata.METADATA_KEY_ALBUM),
            durationMs = m?.getLong(MediaMetadata.METADATA_KEY_DURATION),
            art = artOf(c.packageName, m),
            custom =
                s?.customActions.orEmpty().map {
                    MediaShape.Custom(it.action, it.name?.toString().orEmpty(), if (it.icon != 0) "$ACTION_ICON${c.packageName}:${it.icon}" else null)
                },
            output = MediaShape.output(runCatching { c.playbackInfo?.playbackType == MediaController.PlaybackInfo.PLAYBACK_TYPE_REMOTE }.getOrDefault(false), outputs()),
        )
    }

    /** The phone's audio outputs (type, product name), kept up to date by a callback instead of a binder call per tick. */
    @Volatile private var outputList: List<Pair<Int, String?>>? = null

    private fun outputs(): List<Pair<Int, String?>> =
        outputList ?: run {
            val audio = context.getSystemService(AudioManager::class.java)
            fun read() = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type to it.productName?.toString() }
            audio.registerAudioDeviceCallback(
                object : AudioDeviceCallback() {
                    override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) {
                        outputList = read()
                    }

                    override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) {
                        outputList = read()
                    }
                },
                main,
            )
            read().also { outputList = it }
        }

    /** Custom actions' icons (a drawable of the app's own, "media:act:<pkg>:<resId>"), drawn once and kept. */
    private val actionIcons = HashMap<String, Bitmap?>()

    private fun actionIcon(src: String): Bitmap? =
        synchronized(actionIcons) {
            actionIcons.getOrPut(src) {
                val rest = src.removePrefix(ACTION_ICON)
                runCatching {
                    val d = context.packageManager.getResourcesForApplication(rest.substringBeforeLast(':')).getDrawable(rest.substringAfterLast(':').toInt(), null)
                    val px = (24 * context.resources.displayMetrics.density).toInt()
                    Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888).also { b ->
                        d.setBounds(0, 0, px, px)
                        d.draw(Canvas(b))
                    }
                }.getOrNull()
            }
        }

    /**
     * [pkg]'s art id. Every c.metadata is a fresh parcel with a fresh Bitmap, and this runs every second while playing:
     * the art is kept for as long as the track (and the art's size) stays the same, so its id doesn't change each tick
     * and the widget doesn't swap, and briefly lose, the image.
     */
    private fun artOf(
        pkg: String,
        m: MediaMetadata?,
    ): String? {
        val bitmap =
            m?.let {
                it.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
                    ?: it.getBitmap(MediaMetadata.METADATA_KEY_ART)
                    ?: it.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            }
        return synchronized(arts) {
            if (bitmap == null) {
                arts.remove(pkg)
                return@synchronized null
            }
            val track = listOf(MediaMetadata.METADATA_KEY_MEDIA_ID, MediaMetadata.METADATA_KEY_TITLE, MediaMetadata.METADATA_KEY_ARTIST, MediaMetadata.METADATA_KEY_ALBUM).map { m.getString(it) } + listOf(bitmap.width, bitmap.height)
            val kept = arts[pkg]?.takeIf { it.track == track }
            (kept ?: Art(track, "media:art:${++artSerial}", bitmap).also { arts[pkg] = it }).src
        }
    }

    private fun label(pkg: String) =
        labels.getOrPut(pkg) {
            runCatching {
                val pm = context.packageManager
                pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
            }.getOrDefault(pkg)
        }

    /**
     * Emits whenever the session, track or playback state changes, and every
     * second while playing so `position` moves. Picks up access granted later.
     */
    fun updates(): Flow<Value> = updates(::value)

    /** [updates], reading [read] on each change: the control center reads every session ([sessions]). */
    fun <T> updates(read: () -> T): Flow<T> =
        callbackFlow {
            val watch = Watch { trySend(Unit) }
            watch.listen()
            watch.changed()
            // Access granted (or taken away) later: Android binds (or unbinds) the notification listener - an event too.
            val access =
                launch {
                    var connected = MediaListener.connected != null
                    MediaListener.changes.collect {
                        val now = MediaListener.connected != null
                        if (now == connected) return@collect
                        connected = now
                        watch.listen()
                        watch.changed()
                    }
                }
            // Every second while something plays, so `position` moves; no wake at all otherwise.
            val ticker =
                launch {
                    watch.playing.collectLatest { on ->
                        while (on) {
                            delay(1000)
                            trySend(Unit)
                        }
                    }
                }
            awaitClose {
                access.cancel()
                ticker.cancel()
                watch.close()
            }
        }.conflate().map { read() }.distinctUntilChanged()

    /**
     * Every active session watched, not only the one shown: another one starting to play is an event. A 5 s ticker used
     * to look instead - three binder calls into system_server each time, for the app's whole life once a control center
     * had asked (perf, 2026-10-22). [onChange] on each change; [playing] whether any plays.
     */
    private inner class Watch(
        private val onChange: () -> Unit,
    ) {
        private val bound = HashMap<MediaSession.Token, MediaController>()
        val playing = MutableStateFlow(false)
        private var listening = false

        fun changed() {
            playing.value = synchronized(bound) { bound.values.any { it.playbackState?.state == PlaybackState.STATE_PLAYING } }
            onChange()
        }

        private val callback =
            object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: PlaybackState?) = changed()

                override fun onMetadataChanged(metadata: MediaMetadata?) = changed()

                override fun onSessionDestroyed() = changed()
            }

        private fun bind(list: List<MediaController>) =
            synchronized(bound) {
                val tokens = list.mapTo(HashSet()) { it.sessionToken }
                bound.entries.removeAll { (token, c) -> (token !in tokens).also { gone -> if (gone) c.unregisterCallback(callback) } }
                for (c in list) if (bound.putIfAbsent(c.sessionToken, c) == null) c.registerCallback(callback, main)
            }

        private val sessionsChanged =
            MediaSessionManager.OnActiveSessionsChangedListener { list ->
                bind(list.orEmpty())
                changed()
            }

        fun listen() {
            if (listening || !granted) return
            listening = runCatching { sessions.addOnActiveSessionsChangedListener(sessionsChanged, component, main) }.isSuccess
            bind(active())
        }

        fun close() {
            synchronized(bound) {
                bound.values.forEach { it.unregisterCallback(callback) }
                bound.clear()
            }
            if (listening) sessions.removeOnActiveSessionsChangedListener(sessionsChanged)
        }
    }

    /**
     * media("toggle"), "play", "pause", "next", "previous", "open"; on [pkg]'s session when named (a control center
     * card's), else the one shown. Without access, opens the setting that grants it.
     */
    fun control(
        command: String,
        pkg: String? = null,
    ) {
        if (!granted) {
            openAccessSettings()
            return
        }
        val c = controller(pkg) ?: return
        val t = c.transportControls
        when (command) {
            "play" -> t.play()
            "pause" -> t.pause()
            "toggle" -> toggle(c)
            "next" -> t.skipToNext()
            "previous" -> t.skipToPrevious()
            "open" -> open(c)
            else -> custom(c, command)
        }
    }

    /** Pauses [c] while it plays (buffering counts: MediaShape.active), else plays it. */
    private fun toggle(c: MediaController) {
        if (MediaShape.active(c.playbackState?.state ?: PlaybackState.STATE_NONE)) c.transportControls.pause() else c.transportControls.play()
    }

    /** The session's own action (like, shuffle, repeat...): "custom:<action>", sent with its extras as stock's player does. */
    private fun custom(
        c: MediaController,
        command: String,
    ) {
        if (!command.startsWith("custom:")) return
        val action = command.removePrefix("custom:")
        c.playbackState?.customActions?.firstOrNull { it.action == action }?.let { c.transportControls.sendCustomAction(it, it.extras) }
    }

    /** The session's app: its own activity for the session, else its launcher activity. */
    private fun open(c: MediaController) {
        // send() throws CanceledException, which isn't a RuntimeException: the tap handler wouldn't catch it.
        c.sessionActivity?.let { runCatching { dev.omalauncher.system.AppWindows.send(context, it) } }
            ?: context.packageManager.getLaunchIntentForPackage(c.packageName)?.let { dev.omalauncher.system.AppWindows.startActivity(context, it) }
    }

    /** Moves [pkg]'s session (else the one shown) to [seconds] in, when it takes seeking. */
    fun seek(
        pkg: String?,
        seconds: Double,
    ) {
        val c = controller(pkg) ?: return
        if ((c.playbackState?.actions ?: 0L) and PlaybackState.ACTION_SEEK_TO == 0L) return
        c.transportControls.seekTo((seconds.coerceAtLeast(0.0) * 1000).toLong())
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

    private companion object {
        const val ACTION_ICON = "media:act:"
    }
}
