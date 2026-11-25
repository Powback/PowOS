package dev.omalauncher.widgets.runtime

import android.media.AudioDeviceInfo
import android.media.session.PlaybackState
import dev.omalauncher.widgets.lang.Lst
import dev.omalauncher.widgets.lang.Null
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Str
import dev.omalauncher.widgets.lang.Value
import dev.omalauncher.widgets.lang.bool

/**
 * A media session as plain data, read once from its MediaController ([Media.snap]), and the state the page's media cards
 * are made from ([describe]): the control center's and the lock face's (shell/ui/media.tsx). Pure, so the mapping is
 * tested on the JVM (MediaShapeTest).
 */
object MediaShape {
    /** One session: its PlaybackState and MediaMetadata's parts, the art's id, its custom actions, where it plays. */
    data class Snap(
        val pkg: String,
        val app: String,
        /** PlaybackState.state; [PlaybackState.STATE_NONE] without a playback state. */
        val state: Int = PlaybackState.STATE_NONE,
        /** The last reported position (ms), null without a playback state. */
        val positionMs: Long? = null,
        /** PlaybackState.lastPositionUpdateTime (SystemClock.elapsedRealtime ms). */
        val updatedAt: Long = 0,
        val speed: Float = 1f,
        /** PlaybackState.actions (ACTION_* bits); 0: the app set none. */
        val actions: Long = 0,
        val title: String? = null,
        val artist: String? = null,
        val album: String? = null,
        val durationMs: Long? = null,
        /** The art's id for /_media/<id>, null: none. */
        val art: String? = null,
        val custom: List<Custom> = emptyList(),
        val output: Output? = null,
    )

    /** A PlaybackState.CustomAction (like, shuffle, repeat...): its action string, its name, its icon's /_media/ id. */
    data class Custom(val action: String, val name: String, val icon: String?)

    /** Where it plays: "phone", "bluetooth", "wired" or "cast", and the device's own name when it has one. */
    data class Output(val kind: String, val name: String?)

    /** At most this many custom actions on a card (stock's lock screen player has two spare slots beside the transport). */
    const val MAX_CUSTOM = 2

    /** Playing, as the play/pause button and the order mean it: also while it buffers or connects (MediaSession's isActive). */
    fun active(state: Int) =
        state == PlaybackState.STATE_PLAYING || state == PlaybackState.STATE_BUFFERING || state == PlaybackState.STATE_CONNECTING ||
            state == PlaybackState.STATE_FAST_FORWARDING || state == PlaybackState.STATE_REWINDING ||
            state == PlaybackState.STATE_SKIPPING_TO_NEXT || state == PlaybackState.STATE_SKIPPING_TO_PREVIOUS ||
            state == PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM

    /** Where playback is at [now] (elapsedRealtime ms), in whole seconds: the last position moved on while it plays. */
    fun position(s: Snap, now: Long): Double? {
        val at = s.positionMs ?: return null
        val drift = if (s.state == PlaybackState.STATE_PLAYING && s.updatedAt > 0) (now - s.updatedAt) * s.speed else 0f
        val sec = ((at + drift) / 1000.0).coerceAtLeast(0.0)
        val duration = s.durationMs?.takeIf { it > 0 }?.div(1000.0)
        return Math.floor(if (duration != null) sec.coerceAtMost(duration) else sec)
    }

    /** Whether the app takes [action] (an ACTION_* bit); an app that declared no actions at all gets the basics. */
    private fun takes(s: Snap, action: Long) = s.actions == 0L || s.actions and action != 0L

    /** [s] as the page's MediaState (shell/types.ts) at [now] (elapsedRealtime ms). */
    fun describe(s: Snap, now: Long): Obj {
        val playing = active(s.state)
        fun str(v: String?): Value = v?.takeIf { it.isNotBlank() }?.let(::Str) ?: Null
        return Obj(
            mapOf(
                "available" to bool(true),
                "playing" to bool(playing),
                "title" to str(s.title),
                "artist" to str(s.artist),
                "album" to str(s.album),
                "app" to Str(s.app),
                "package" to Str(s.pkg),
                "position" to (position(s, now)?.let(::Num) ?: Null),
                "duration" to (s.durationMs?.takeIf { it > 0 }?.let { Num(Math.floor(it / 1000.0)) } ?: Null),
                "art" to str(s.art),
                "seekable" to bool(s.actions and PlaybackState.ACTION_SEEK_TO != 0L),
                "canPrevious" to bool(takes(s, PlaybackState.ACTION_SKIP_TO_PREVIOUS)),
                "canNext" to bool(takes(s, PlaybackState.ACTION_SKIP_TO_NEXT)),
                "actions" to Lst(s.custom.take(MAX_CUSTOM).map { Obj(mapOf("id" to Str(it.action), "name" to Str(it.name), "icon" to str(it.icon))) }),
                "output" to (s.output?.let { Obj(mapOf("kind" to Str(it.kind), "name" to str(it.name))) } ?: Null),
                // Paused or stopped: seconds since (stock's lock screen drops a player paused for 10 minutes); null while it plays.
                "idle" to (if (!playing && s.updatedAt > 0) Num(Math.floor((now - s.updatedAt).coerceAtLeast(0) / 1000.0)) else Null),
            ),
        )
    }

    /** The cards' order: every session with a track, the ones playing first, one per app, at most [max]. */
    fun order(all: List<Snap>, max: Int): List<Snap> =
        (all.filter { active(it.state) } + all.filter { !active(it.state) }).distinctBy { it.pkg }.filter { !it.title.isNullOrBlank() }.take(max)

    /**
     * Where an app's audio goes: a remote session casts; otherwise the phone's outputs ([devices]: AudioDeviceInfo type
     * and product name) - a Bluetooth one when connected (media follows it), else wired headphones, else the phone.
     */
    fun output(remote: Boolean, devices: List<Pair<Int, String?>>): Output {
        if (remote) return Output("cast", null)
        devices.firstOrNull { it.first in BLUETOOTH }?.let { return Output("bluetooth", it.second?.takeIf(String::isNotBlank)) }
        if (devices.any { it.first in WIRED }) return Output("wired", null)
        return Output("phone", null)
    }

    private val BLUETOOTH =
        setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_HEARING_AID,
        )
    private val WIRED = setOf(AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET)
}
