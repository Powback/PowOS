package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The lock face's fingerprint spot: config_udfps_sensor_props (native px, natural orientation) on the display as it is. */
class FingerprintSensorTest {
    @Test
    fun nativeModeIsTakenAsIs() {
        // A 1080 x 2340 panel at its native mode, sensor low in the middle.
        assertEquals(FingerprintSensor.Spot(540, 2108, 95), FingerprintSensor.spot(intArrayOf(540, 2108, 95), FingerprintSensor.Size(1080, 2340), FingerprintSensor.Size(1080, 2340), 0))
    }

    @Test
    fun scaledToTheCurrentMode() {
        // A QHD+ panel (1440 x 3120) running at FHD+ (1080 x 2340): everything x0.75.
        assertEquals(FingerprintSensor.Spot(540, 2250, 75), FingerprintSensor.spot(intArrayOf(720, 3000, 100), FingerprintSensor.Size(1440, 3120), FingerprintSensor.Size(1080, 2340), 0))
    }

    @Test
    fun turnedWithTheDisplay() {
        val p = intArrayOf(540, 2000, 80)
        assertEquals(FingerprintSensor.Spot(2000, 540, 80), FingerprintSensor.spot(p, FingerprintSensor.Size(1080, 2400), FingerprintSensor.Size(1080, 2400), 1))
        assertEquals(FingerprintSensor.Spot(540, 400, 80), FingerprintSensor.spot(p, FingerprintSensor.Size(1080, 2400), FingerprintSensor.Size(1080, 2400), 2))
        assertEquals(FingerprintSensor.Spot(400, 540, 80), FingerprintSensor.spot(p, FingerprintSensor.Size(1080, 2400), FingerprintSensor.Size(1080, 2400), 3))
    }

    @Test
    fun nothingUsableIsNoSpot() {
        assertNull(FingerprintSensor.spot(null, FingerprintSensor.Size(1080, 2400), FingerprintSensor.Size(1080, 2400), 0))
        assertNull(FingerprintSensor.spot(intArrayOf(), FingerprintSensor.Size(1080, 2400), FingerprintSensor.Size(1080, 2400), 0))
        assertNull(FingerprintSensor.spot(intArrayOf(540, 2000), FingerprintSensor.Size(1080, 2400), FingerprintSensor.Size(1080, 2400), 0))
        assertNull(FingerprintSensor.spot(intArrayOf(540, 2000, 0), FingerprintSensor.Size(1080, 2400), FingerprintSensor.Size(1080, 2400), 0))
        assertNull(FingerprintSensor.spot(intArrayOf(540, 9000, 80), FingerprintSensor.Size(1080, 2400), FingerprintSensor.Size(1080, 2400), 0))
        assertNull(FingerprintSensor.spot(intArrayOf(540, 2000, 80), FingerprintSensor.Size(0, 0), FingerprintSensor.Size(1080, 2400), 0))
    }

    @Test
    fun kinds() {
        val s = FingerprintSensor.Spot(1, 1, 1)
        assertEquals(FingerprintSensor.NONE, FingerprintSensor.kind(false, s, true))
        assertEquals(FingerprintSensor.UDFPS, FingerprintSensor.kind(true, s, false))
        assertEquals(FingerprintSensor.SIDE, FingerprintSensor.kind(true, null, true))
        assertEquals(FingerprintSensor.OTHER, FingerprintSensor.kind(true, null, false))
    }
}
