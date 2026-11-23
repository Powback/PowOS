package dev.omalauncher.system

import android.os.BatteryManager.BATTERY_PLUGGED_AC
import android.os.BatteryManager.BATTERY_PLUGGED_USB
import android.os.BatteryManager.BATTERY_PLUGGED_WIRELESS
import android.os.BatteryManager.BATTERY_STATUS_CHARGING
import android.os.BatteryManager.BATTERY_STATUS_DISCHARGING
import android.os.BatteryManager.BATTERY_STATUS_FULL
import android.os.BatteryManager.BATTERY_STATUS_NOT_CHARGING
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The lock face's charging class (system/Charging.kt; the user, ask-1a209c7798a: the S25's lock screen says "super fast
 * charging ... one hour until full", PowOS's didn't). By the charger's offered power only: < 5 W slow, >= 7.5 W fast,
 * >= 20 W super fast; the battery's intake may raise the class, never lower it to slow; no time unless Android has one.
 */
class ChargingTest {
    private fun c(
        status: Int = BATTERY_STATUS_CHARGING,
        plugged: Int = BATTERY_PLUGGED_AC,
        maxUa: Int = -1,
        maxUv: Int = -1,
        nowUa: Long = Long.MIN_VALUE,
        mv: Int = 4000,
        timeMs: Long = -1,
        level: Int = 50,
    ) = Charging.classify(level, 100, status, plugged, maxUa, maxUv, nowUa, mv, timeMs)

    @Test fun chargerClasses() {
        assertEquals("slow", c(maxUa = 500_000, maxUv = 5_000_000).speed) // 2.5 W: a PC's USB port
        assertEquals("normal", c(maxUa = 1_000_000, maxUv = 5_000_000).speed) // 5 W
        assertEquals("fast", c(maxUa = 1_670_000, maxUv = 9_000_000).speed) // 15 W adapter
        assertEquals("fast", c(maxUa = 1_500_000, maxUv = 5_000_000).speed) // 7.5 W: exactly AOSP's line
        assertEquals("superfast", c(maxUa = 2_770_000, maxUv = 9_000_000).speed) // 25 W PD
        assertEquals("superfast", c(maxUa = 3_000_000, maxUv = 15_000_000).speed) // 45 W
        val i = c(maxUa = 3_000_000, maxUv = 9_000_000)
        assertEquals(27.0, i.watts!!, 0.01)
        assertEquals("charger", i.wattsFrom)
    }

    @Test fun noVoltageMeansFiveVolts() {
        // AOSP: a current without a voltage is at 5 V. 2 A -> 10 W -> fast.
        assertEquals("fast", c(maxUa = 2_000_000, maxUv = 0).speed)
    }

    @Test fun measuredIntakeOnlyRaises() {
        // No charger figure: 3 A at 4 V into the battery = 12 W -> fast.
        val i = c(nowUa = 3_000_000, mv = 4000)
        assertEquals("fast", i.speed)
        assertEquals("measured", i.wattsFrom)
        // A vendor reporting mA (3000 "uA" = 0.012 W) never reads as a trickle: "normal", not "slow".
        assertEquals("normal", c(nowUa = 3000, mv = 4000).speed)
        // A negative (discharge-signed) reading is ignored: nothing known -> normal.
        val n = c(nowUa = -2_000_000)
        assertEquals("normal", n.speed)
        assertNull(n.watts)
    }

    @Test fun wirelessAndUsb() {
        assertEquals("wireless", c(plugged = BATTERY_PLUGGED_WIRELESS).plugged)
        assertEquals("usb", c(plugged = BATTERY_PLUGGED_USB).plugged)
        assertEquals("ac", c().plugged)
    }

    @Test fun timeUntilFullOnlyWhenAndroidKnows() {
        assertEquals(3_600_000L, c(timeMs = 3_600_000).fullInMs)
        assertNull(c(timeMs = -1).fullInMs)
        assertNull(c(timeMs = 0).fullInMs)
    }

    @Test fun onBatteryFullAndHeld() {
        val off = c(status = BATTERY_STATUS_DISCHARGING, plugged = 0, maxUa = 3_000_000, timeMs = 100)
        assertFalse(off.charging)
        assertNull(off.speed)
        assertNull(off.fullInMs)
        assertNull(off.plugged)
        val full = c(status = BATTERY_STATUS_FULL, level = 100, timeMs = 100)
        assertTrue(full.full)
        assertNull(full.speed)
        assertNull(full.fullInMs)
        val held = c(status = BATTERY_STATUS_NOT_CHARGING, level = 80)
        assertTrue(held.held)
        assertFalse(held.charging)
        assertNull(held.speed)
    }
}
