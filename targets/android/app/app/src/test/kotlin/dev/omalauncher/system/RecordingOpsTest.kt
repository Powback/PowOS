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
        assertNull(RecordingOps.kind("android:coarse_location"))
        assertTrue(RecordingOps.WATCHED.all { RecordingOps.kind(it) != null })
    }

    @Test fun offUntilAnOpStarts() {
        val ops = RecordingOps()
        assertNull(ops.state().ring)
        assertFalse(ops.changed("android:coarse_location", 10100, "maps", true))
        assertNull(ops.state().ring)
    }

    @Test fun micIsOrangeCameraWinsAndItEndsWhenTheLastStops() {
        val ops = RecordingOps()
        assertTrue(ops.changed(OP_RECORD_AUDIO, 10100, "recorder", true))
        assertEquals(Kind.MIC, ops.state().ring)
        // A video call: camera and mic - the camera's colour.
        assertTrue(ops.changed(OP_CAMERA, 10200, "meet", true))
        assertFalse(ops.changed(OP_RECORD_AUDIO, 10200, "meet", true)) // meet is on the list already, the camera wins
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
}
