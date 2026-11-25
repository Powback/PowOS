package dev.omalauncher.system

import android.telephony.ServiceState
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The status bar's icon mapping (StatusIcons): what stock SystemUI shows for each SIM state, signal level, network type
 * and override, and the notification icons it lists. The user, 11-25: "the statusbar doesnt contain all the icons it
 * should like the sim card status and whatever shows originally".
 */
class StatusIconsTest {
    @Test
    fun simStates() {
        assertEquals("ready", StatusIcons.sim(TelephonyManager.SIM_STATE_READY))
        assertEquals("ready", StatusIcons.sim(10)) // SIM_STATE_LOADED
        assertEquals("absent", StatusIcons.sim(TelephonyManager.SIM_STATE_ABSENT))
        assertEquals("locked", StatusIcons.sim(TelephonyManager.SIM_STATE_PIN_REQUIRED))
        assertEquals("locked", StatusIcons.sim(TelephonyManager.SIM_STATE_PUK_REQUIRED))
        assertEquals("locked", StatusIcons.sim(TelephonyManager.SIM_STATE_NETWORK_LOCKED))
        assertEquals("error", StatusIcons.sim(TelephonyManager.SIM_STATE_CARD_IO_ERROR))
        assertEquals("error", StatusIcons.sim(TelephonyManager.SIM_STATE_PERM_DISABLED))
        assertEquals("unknown", StatusIcons.sim(TelephonyManager.SIM_STATE_UNKNOWN))
        assertEquals("unknown", StatusIcons.sim(TelephonyManager.SIM_STATE_NOT_READY))
    }

    @Test
    fun signalLevelsToBars() {
        for (l in 0..4) assertEquals(l, StatusIcons.bars(l))
        assertEquals(0, StatusIcons.bars(-1))
        assertEquals(4, StatusIcons.bars(9))
        // An OEM's 6-level scale (0..5) still ends at 4 bars, starts at 0.
        assertEquals(0, StatusIcons.bars(0, 6))
        assertEquals(4, StatusIcons.bars(5, 6))
        assertEquals(2, StatusIcons.bars(3, 6))
    }

    @Test
    fun wifiLevels() {
        assertEquals(4, StatusIcons.wifiBars(4, 4))
        assertEquals(0, StatusIcons.wifiBars(0, 4))
        assertEquals(2, StatusIcons.wifiBars(1, 2))
    }

    @Test
    fun serviceStates() {
        assertEquals("in", StatusIcons.service(ServiceState.STATE_IN_SERVICE))
        assertEquals("none", StatusIcons.service(ServiceState.STATE_OUT_OF_SERVICE))
        assertEquals("emergency", StatusIcons.service(ServiceState.STATE_OUT_OF_SERVICE, emergencyOnly = true))
        assertEquals("emergency", StatusIcons.service(ServiceState.STATE_EMERGENCY_ONLY))
        assertEquals("off", StatusIcons.service(ServiceState.STATE_POWER_OFF))
    }

    @Test
    fun networkTypes() {
        assertEquals("5G", StatusIcons.type(TelephonyManager.NETWORK_TYPE_NR))
        assertEquals("LTE", StatusIcons.type(TelephonyManager.NETWORK_TYPE_LTE))
        assertEquals("4G", StatusIcons.type(TelephonyManager.NETWORK_TYPE_LTE, show4g = true))
        assertEquals("H+", StatusIcons.type(TelephonyManager.NETWORK_TYPE_HSPAP))
        assertEquals("3G", StatusIcons.type(TelephonyManager.NETWORK_TYPE_UMTS))
        assertEquals("E", StatusIcons.type(TelephonyManager.NETWORK_TYPE_EDGE))
        assertEquals("G", StatusIcons.type(TelephonyManager.NETWORK_TYPE_GPRS))
        assertNull(StatusIcons.type(TelephonyManager.NETWORK_TYPE_UNKNOWN))
        assertNull(StatusIcons.type(TelephonyManager.NETWORK_TYPE_IWLAN))
    }

    @Test
    fun displayOverridesRaiseTheType() {
        val lte = TelephonyManager.NETWORK_TYPE_LTE
        assertEquals("5G", StatusIcons.type(lte, TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA))
        assertEquals("5G+", StatusIcons.type(lte, TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_ADVANCED))
        assertEquals("LTE+", StatusIcons.type(lte, TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_CA))
        assertEquals("4G+", StatusIcons.type(lte, TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_CA, show4g = true))
    }

    @Test
    fun dataArrows() {
        assertEquals("in", StatusIcons.activity(TelephonyManager.DATA_ACTIVITY_IN))
        assertEquals("out", StatusIcons.activity(TelephonyManager.DATA_ACTIVITY_OUT))
        assertEquals("inout", StatusIcons.activity(TelephonyManager.DATA_ACTIVITY_INOUT))
        assertNull(StatusIcons.activity(TelephonyManager.DATA_ACTIVITY_NONE))
        assertNull(StatusIcons.activity(TelephonyManager.DATA_ACTIVITY_DORMANT))
    }

    @Test
    fun slotsShownAsStock() {
        // Dual SIM: both; one SIM in slot 2: only that one; no SIM at all: one "no SIM" icon.
        assertEquals(listOf(0 to "ready", 1 to "ready"), StatusIcons.slots(listOf("ready", "ready")))
        assertEquals(listOf(1 to "ready"), StatusIcons.slots(listOf("absent", "ready")))
        assertEquals(listOf(0 to "absent"), StatusIcons.slots(listOf("absent", "absent")))
        assertEquals(listOf(0 to "locked", 1 to "ready"), StatusIcons.slots(listOf("locked", "ready")))
        // The OnePlus Open 11-25: slot 0 empty, the eSIM in slot 1 disabled (NOT_READY) - "no SIM", not nothing.
        assertEquals(listOf(0 to "absent"), StatusIcons.slots(listOf("absent", "unknown")))
        assertEquals(emptyList<Pair<Int, String>>(), StatusIcons.slots(emptyList()))
    }

    @Test
    fun oneNotificationIconPerApp() {
        val a = StatusIcons.NotifIcon("k1", "chat", "u1")
        val b = StatusIcons.NotifIcon("k2", "chat", "u2")
        val c = StatusIcons.NotifIcon("k3", "mail", "u3")
        val silent = StatusIcons.NotifIcon("k4", "weather", "u4")
        assertEquals(listOf(a, c), StatusIcons.notifications(listOf(a, b, c, silent)) { it != silent })
    }

    @Test
    fun theJsonThePageReads() {
        val s =
            StatusIcons.Status(
                cells = listOf(StatusIcons.Cell(0, "ready", bars = 3, type = "5G", data = true, activity = "inout")),
                wifi = 2,
                alarm = 123L,
            ).json()
        val cell = s.getJSONArray("cells").getJSONObject(0)
        assertEquals(3, cell.getInt("bars"))
        assertEquals("5G", cell.getString("type"))
        assertEquals("inout", cell.getString("activity"))
        assertTrue(cell.getBoolean("data"))
        assertEquals(2, s.getInt("wifi"))
        assertEquals(123L, s.getLong("alarm"))
        assertFalse(s.getBoolean("airplane"))
        assertTrue(s.isNull("bluetoothBattery"))
    }
}
