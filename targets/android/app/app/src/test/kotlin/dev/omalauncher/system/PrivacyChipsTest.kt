package dev.omalauncher.system

import dev.omalauncher.system.RecordingOps.Chip
import dev.omalauncher.system.RecordingOps.Companion.GRACE_MS
import dev.omalauncher.system.RecordingOps.Companion.OP_CAMERA
import dev.omalauncher.system.RecordingOps.Companion.OP_FINE_LOCATION
import dev.omalauncher.system.RecordingOps.Companion.OP_MONITOR_HIGH_POWER_LOCATION
import dev.omalauncher.system.RecordingOps.Companion.OP_RECORD_AUDIO
import dev.omalauncher.system.RecordingOps.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The shade's privacy row (shell/ui/privacy.tsx, ShellBridge privacyList): AppOps' active ops -> one chip per app, what
 * it uses, "now" or when it stopped, gone [GRACE_MS] after (the user, 11-03: "I should be able to see where my
 * microphone is used in the notification center").
 */
class PrivacyChipsTest {
    private var t = 0L

    @Test fun oneChipPerAppNamingWhatItUses() {
        val ops = RecordingOps { t }
        t = 1_000
        ops.changed(OP_RECORD_AUDIO, 10100, "com.example.recorder", true)
        // A video call: camera and mic, one chip; the camera first (the ring's order).
        t = 2_000
        ops.changed(OP_RECORD_AUDIO, 10200, "com.example.meet", true)
        t = 2_000
        ops.changed(OP_CAMERA, 10200, "com.example.meet", true)
        t = 3_000
        ops.changed(OP_FINE_LOCATION, 10300, "com.example.maps", true)
        t = 3_000
        ops.changed(OP_MONITOR_HIGH_POWER_LOCATION, 10300, "com.example.maps", true)
        assertEquals(
            listOf(
                Chip("com.example.recorder", 10100, listOf(Kind.MIC), true, null),
                Chip("com.example.meet", 10200, listOf(Kind.CAMERA, Kind.MIC), true, null),
                Chip("com.example.maps", 10300, listOf(Kind.LOCATION), true, null),
            ),
            ops.chips(now = 4_000),
        )
    }

    @Test fun aStoppedUseStaysGreyedForTheGraceThenGoes() {
        val ops = RecordingOps { t }
        t = 0
        ops.changed(OP_RECORD_AUDIO, 10100, "com.powos.app", true)
        t = 0
        ops.changed(OP_CAMERA, 10200, "com.example.cam", true)
        t = 10_000
        ops.changed(OP_RECORD_AUDIO, 10100, "com.powos.app", false)
        // Still using: first; stopped: after, with when.
        assertEquals(
            listOf(Chip("com.example.cam", 10200, listOf(Kind.CAMERA), true, null), Chip("com.powos.app", 10100, listOf(Kind.MIC), false, 10_000)),
            ops.chips(now = 12_000),
        )
        assertEquals(10_000 + GRACE_MS, ops.nextExpiry())
        assertEquals(listOf("com.example.cam"), ops.chips(now = 10_000 + GRACE_MS).map { it.pkg })
        assertNull(ops.nextExpiry())
    }

    @Test fun startingAgainMakesItNowAgain() {
        val ops = RecordingOps { t }
        t = 0
        ops.changed(OP_RECORD_AUDIO, 10100, "rec", true)
        t = 1_000
        ops.changed(OP_RECORD_AUDIO, 10100, "rec", false)
        t = 2_000
        ops.changed(OP_RECORD_AUDIO, 10100, "rec", true)
        assertEquals(listOf(Chip("rec", 10100, listOf(Kind.MIC), true, null)), ops.chips(now = 3_000))
        assertNull(ops.nextExpiry())
    }

    @Test fun anAppPartlyStoppedIsStillNowAndNamesBoth() {
        val ops = RecordingOps { t }
        t = 0
        ops.changed(OP_CAMERA, 10200, "meet", true)
        t = 0
        ops.changed(OP_RECORD_AUDIO, 10200, "meet", true)
        t = 5_000
        ops.changed(OP_CAMERA, 10200, "meet", false)
        assertEquals(listOf(Chip("meet", 10200, listOf(Kind.CAMERA, Kind.MIC), true, null)), ops.chips(now = 6_000))
    }

    @Test fun theLatestStopFirstAmongTheStopped() {
        val ops = RecordingOps { t }
        t = 0
        ops.changed(OP_RECORD_AUDIO, 1, "a", true)
        t = 0
        ops.changed(OP_CAMERA, 2, "b", true)
        t = 1_000
        ops.changed(OP_RECORD_AUDIO, 1, "a", false)
        t = 2_000
        ops.changed(OP_CAMERA, 2, "b", false)
        assertEquals(listOf("b", "a"), ops.chips(now = 3_000).map { it.pkg })
    }
}
