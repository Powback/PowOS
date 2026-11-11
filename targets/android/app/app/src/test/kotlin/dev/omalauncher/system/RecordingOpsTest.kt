package dev.omalauncher.system

import dev.omalauncher.system.RecordingOps.Companion.OP_CAMERA
import dev.omalauncher.system.RecordingOps.Companion.OP_PHONE_CALL_MICROPHONE
import dev.omalauncher.system.RecordingOps.Companion.OP_PROJECT_MEDIA
import dev.omalauncher.system.RecordingOps.Companion.OP_RECORD_AUDIO
import dev.omalauncher.system.RecordingOps.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The recording light's op -> state mapping (RecordingLight.kt): which colour the ring takes, and when it goes off. */
class RecordingOpsTest {
    @Test fun opsMapToKinds() {
        assertEquals(Kind.CAMERA, RecordingOps.kind(OP_CAMERA))
        assertEquals(Kind.CAMERA, RecordingOps.kind("android:phone_call_camera"))
        assertEquals(Kind.MIC, RecordingOps.kind(OP_RECORD_AUDIO))
        assertEquals(Kind.MIC, RecordingOps.kind(OP_PHONE_CALL_MICROPHONE))
        assertEquals(Kind.SCREEN, RecordingOps.kind(OP_PROJECT_MEDIA))
        assertEquals(Kind.LOCATION, RecordingOps.kind("android:coarse_location"))
        assertNull(RecordingOps.kind("android:read_contacts"))
        assertTrue(RecordingOps.WATCHED.all { RecordingOps.kind(it) != null })
    }

    @Test fun offUntilAnOpStarts() {
        val ops = RecordingOps()
        assertNull(ops.state().ring)
        assertFalse(ops.changed("android:read_contacts", 10100, "contacts", true))
        assertNull(ops.state().ring)
        // Location is the shade's row only: it lights no ring and names no one there.
        assertTrue(ops.changed("android:coarse_location", 10100, "maps", true))
        assertNull(ops.state().ring)
        assertEquals(emptyList<String>(), ops.state().apps)
    }

    @Test fun micIsOrangeCameraWinsAndItEndsWhenTheLastStops() {
        val ops = RecordingOps()
        assertTrue(ops.changed(OP_RECORD_AUDIO, 10100, "recorder", true))
        assertEquals(Kind.MIC, ops.state().ring)
        // A video call: camera and mic - the camera's colour.
        assertTrue(ops.changed(OP_CAMERA, 10200, "meet", true))
        // The ring keeps the camera's colour, but the shade's privacy row now names meet's mic too: a change.
        assertTrue(ops.changed(OP_RECORD_AUDIO, 10200, "meet", true))
        assertEquals(Kind.CAMERA, ops.state().ring)
        assertEquals(listOf("recorder", "meet"), ops.state().apps)
        assertTrue(ops.changed(OP_CAMERA, 10200, "meet", false))
        assertEquals(Kind.MIC, ops.state().ring)
        // The recorder stops; the call's mic still runs.
        ops.changed(OP_RECORD_AUDIO, 10100, "recorder", false)
        assertEquals(Kind.MIC, ops.state().ring)
        assertEquals(listOf("meet"), ops.state().apps)
        assertTrue(ops.changed(OP_RECORD_AUDIO, 10200, "meet", false))
        assertNull(ops.state().ring)
        assertEquals(emptyList<String>(), ops.state().apps)
    }

    @Test fun screenBeatsMicNotCamera() {
        val ops = RecordingOps()
        ops.changed(OP_PHONE_CALL_MICROPHONE, 1001, "com.android.phone", true)
        ops.changed(OP_PROJECT_MEDIA, 10300, "screenrec", true)
        assertEquals(Kind.SCREEN, ops.state().ring)
        ops.changed(OP_CAMERA, 10300, "screenrec", true)
        assertEquals(Kind.CAMERA, ops.state().ring)
        assertEquals(setOf(Kind.MIC, Kind.SCREEN, Kind.CAMERA), ops.state().kinds)
    }

    @Test fun aStopForAnOpNeverStartedChangesNothing() {
        val ops = RecordingOps()
        assertFalse(ops.changed(OP_CAMERA, 10100, "cam", false))
        ops.changed(OP_CAMERA, 10100, "cam", true)
        assertFalse(ops.changed(OP_CAMERA, 10100, "cam", true))
        assertFalse(ops.changed(OP_CAMERA, 10999, "other", false))
        assertEquals(Kind.CAMERA, ops.state().ring)
    }

    // The non-root mic (no WATCH_APPOPS): AudioManager's recordings, anonymous. MediaRecorder.AudioSource.MIC = 1,
    // VOICE_RECOGNITION = 6, VOICE_COMMUNICATION = 7.
    @Test fun anAnonymousCaptureLightsTheMicNamingNoOne() {
        val ops = RecordingOps()
        assertFalse(ops.captures(emptyList()))
        assertNull(ops.state().ring)
        assertTrue(ops.captures(listOf(1 to false)))
        assertEquals(Kind.MIC, ops.state().ring)
        assertEquals(emptyList<String>(), ops.state().apps)
        assertEquals(emptyList<RecordingOps.Chip>(), ops.chips())
        // A second capture joins: still on, nothing the ring shows changed.
        assertFalse(ops.captures(listOf(1 to false, 7 to false)))
        assertTrue(ops.captures(emptyList()))
        assertNull(ops.state().ring)
    }

    @Test fun aMicAtRestNeverLights() {
        val ops = RecordingOps()
        // A silenced client (a background app fed zeros) and the hotword detector are not the mic in use.
        assertFalse(ops.captures(listOf(6 to true, RecordingOps.SOURCE_HOTWORD to false)))
        assertNull(ops.state().ring)
        assertFalse(RecordingOps.capturing(1, silenced = true))
        assertFalse(RecordingOps.capturing(RecordingOps.SOURCE_HOTWORD, silenced = false))
        assertTrue(RecordingOps.capturing(6, silenced = false))
        // The same client unsilenced (back in front): it lights; silenced again: off.
        assertTrue(ops.captures(listOf(6 to false)))
        assertEquals(Kind.MIC, ops.state().ring)
        assertTrue(ops.captures(listOf(6 to true)))
        assertNull(ops.state().ring)
    }

    @Test fun anonymousAndAppOpsMicTogetherAndCameraStillWins() {
        val ops = RecordingOps()
        ops.changed(OP_RECORD_AUDIO, 10100, "com.powos.app", true)
        assertTrue(ops.captures(listOf(1 to false, 6 to false))) // anonymous captures started (the ring already orange)
        assertEquals(listOf("com.powos.app"), ops.state().apps)
        ops.changed(OP_RECORD_AUDIO, 10100, "com.powos.app", false)
        assertEquals(Kind.MIC, ops.state().ring) // another app's capture still runs
        ops.changed(OP_CAMERA, 10100, "com.powos.app", true)
        assertEquals(Kind.CAMERA, ops.state().ring)
        ops.changed(OP_CAMERA, 10100, "com.powos.app", false)
        assertTrue(ops.captures(emptyList()))
        assertNull(ops.state().ring)
    }

    @Test fun anAppsMicOpLightsOnlyWhileACaptureReallyRuns() {
        val ops = RecordingOps()
        assertTrue(ops.changed(OP_RECORD_AUDIO, 10100, "recorder", true))
        // Before AudioManager has reported anything, the op alone lights it (nothing better to go on).
        assertEquals(Kind.MIC, ops.state().ring)
        // The recordings say only a silenced client runs: the op is no capture - off, no one named.
        assertTrue(ops.captures(listOf(6 to true)))
        assertNull(ops.state().ring)
        assertEquals(emptyList<String>(), ops.state().apps)
        // It records for real: on, named.
        assertTrue(ops.captures(listOf(6 to false)))
        assertEquals(Kind.MIC, ops.state().ring)
        assertEquals(listOf("recorder"), ops.state().apps)
        // A phone call's mic is not gated by the recordings (telephony audio isn't one).
        assertTrue(ops.captures(emptyList()))
        ops.changed(OP_PHONE_CALL_MICROPHONE, 1001, "com.android.phone", true)
        assertEquals(Kind.MIC, ops.state().ring)
        assertEquals(listOf("com.android.phone"), ops.state().apps)
    }
}
