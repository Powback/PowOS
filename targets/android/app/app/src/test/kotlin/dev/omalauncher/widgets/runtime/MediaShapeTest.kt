package dev.omalauncher.widgets.runtime

import android.media.AudioDeviceInfo
import android.media.session.PlaybackState
import dev.omalauncher.widgets.lang.Bool
import dev.omalauncher.widgets.lang.Lst
import dev.omalauncher.widgets.lang.Null
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Str
import dev.omalauncher.widgets.lang.Value
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A media session's state as the media cards read it (MediaShape; shell/ui/media.tsx): the control center's and the lock
 * face's (the user, 11-25: "we are missing basic features such as a media control on the lockscreen if media is playing").
 */
class MediaShapeTest {
    private val now = 100_000L

    private fun snap(
        state: Int = PlaybackState.STATE_PLAYING,
        actions: Long = PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS,
        pkg: String = "com.spotify.music",
        title: String? = "Teardrop",
        custom: List<MediaShape.Custom> = emptyList(),
        output: MediaShape.Output? = null,
    ) = MediaShape.Snap(
        pkg = pkg,
        app = "Spotify",
        state = state,
        positionMs = 42_000,
        updatedAt = now - 2_500,
        speed = 1f,
        actions = actions,
        title = title,
        artist = "Massive Attack",
        durationMs = 330_400,
        art = "media:art:1",
        custom = custom,
        output = output,
    )

    private fun Obj.f(k: String): Value = fields[k] ?: Null

    @Test fun playingMovesOnFromTheLastReport() {
        val o = MediaShape.describe(snap(), now)
        assertEquals(Bool(true), o.f("playing"))
        assertEquals(Num(44.0), o.f("position")) // 42 s + 2.5 s since, floored
        assertEquals(Num(330.0), o.f("duration"))
        assertEquals(Str("Teardrop"), o.f("title"))
        assertEquals(Str("com.spotify.music"), o.f("package"))
        assertEquals(Bool(true), o.f("seekable"))
        assertEquals(Null, o.f("idle"))
    }

    @Test fun pausedStaysWhereItStoppedAndSaysHowLongAgo() {
        val o = MediaShape.describe(snap(state = PlaybackState.STATE_PAUSED), now)
        assertEquals(Bool(false), o.f("playing"))
        assertEquals(Num(42.0), o.f("position"))
        assertEquals(Num(2.0), o.f("idle"))
    }

    @Test fun bufferingCountsAsPlaying() {
        assertEquals(Bool(true), MediaShape.describe(snap(state = PlaybackState.STATE_BUFFERING), now).f("playing"))
        // ... but its position doesn't run on while it waits.
        assertEquals(Num(42.0), MediaShape.describe(snap(state = PlaybackState.STATE_BUFFERING), now).f("position"))
    }

    @Test fun positionNeverPassesTheEnd() {
        val s = snap().copy(positionMs = 330_000, updatedAt = now - 60_000)
        assertEquals(Num(330.0), MediaShape.describe(s, now).f("position"))
    }

    @Test fun transportFollowsTheAppsActions() {
        val o = MediaShape.describe(snap(actions = PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT), now)
        assertEquals(Bool(false), o.f("canPrevious"))
        assertEquals(Bool(true), o.f("canNext"))
        assertEquals(Bool(false), o.f("seekable"))
        // An app that declared no actions at all still gets the basics.
        val none = MediaShape.describe(snap(actions = 0), now)
        assertEquals(Bool(true), none.f("canPrevious"))
        assertEquals(Bool(true), none.f("canNext"))
    }

    @Test fun customActionsAtMostTwo() {
        val c = listOf(MediaShape.Custom("like", "Like", "media:act:x:1"), MediaShape.Custom("shuffle", "Shuffle", null), MediaShape.Custom("radio", "Radio", null))
        val actions = MediaShape.describe(snap(custom = c), now).f("actions") as Lst
        assertEquals(2, actions.items.size)
        val first = actions.items[0] as Obj
        assertEquals(Str("like"), first.f("id"))
        assertEquals(Str("media:act:x:1"), first.f("icon"))
        assertEquals(Null, (actions.items[1] as Obj).f("icon"))
    }

    @Test fun outputPicksBluetoothThenWiredThenPhone() {
        val speaker = AudioDeviceInfo.TYPE_BUILTIN_SPEAKER to "OnePlus Open"
        assertEquals(MediaShape.Output("phone", null), MediaShape.output(false, listOf(speaker)))
        assertEquals(MediaShape.Output("wired", null), MediaShape.output(false, listOf(speaker, AudioDeviceInfo.TYPE_WIRED_HEADPHONES to null)))
        assertEquals(
            MediaShape.Output("bluetooth", "WH-1000XM4"),
            MediaShape.output(false, listOf(speaker, AudioDeviceInfo.TYPE_WIRED_HEADPHONES to null, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP to "WH-1000XM4")),
        )
        assertEquals(MediaShape.Output("cast", null), MediaShape.output(true, listOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP to "Buds")))
        val o = MediaShape.describe(snap(output = MediaShape.Output("bluetooth", "Buds")), now).f("output") as Obj
        assertEquals(Str("bluetooth"), o.f("kind"))
        assertEquals(Str("Buds"), o.f("name"))
    }

    @Test fun orderPlayingFirstOnePerAppTitledOnly() {
        val paused = snap(state = PlaybackState.STATE_PAUSED, pkg = "youtube")
        val playing = snap(pkg = "spotify")
        val untitled = snap(pkg = "podcasts", title = null)
        val second = snap(state = PlaybackState.STATE_PAUSED, pkg = "spotify")
        assertEquals(listOf("spotify", "youtube"), MediaShape.order(listOf(paused, untitled, second, playing), 4).map { it.pkg })
        assertEquals(listOf("spotify"), MediaShape.order(listOf(paused, playing), 1).map { it.pkg })
    }
}
