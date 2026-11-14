package andro.marchy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The no-root adb handover (razr no-root log, 11-14: the Linux side had no link - lib/android.sh only knew
 * 127.0.0.1:5555, got no port or key, and mDNS doesn't work under fakechroot). run/adb-link and run/adb-pair are
 * read by lib/android.sh (_android_link_*; test/tier1/test-android-link.sh feeds it these exact lines).
 */
class AdbLinkTest {
    @Test
    fun theRecordNamesThePackageStateAndTheConnectPort() {
        assertEquals(
            "package com.powos.app\nwireless on\nkeep on\nconnect 127.0.0.1:39715\n",
            AdbLink.record("com.powos.app", true, true, 39715),
        )
    }

    @Test
    fun noConnectLineWithoutAPort() {
        // Wireless debugging off (or adbd not announced yet): the Linux side must not try a stale port.
        assertEquals("package com.powos.app\nwireless off\nkeep off\n", AdbLink.record("com.powos.app", false, false, -1))
    }

    @Test
    fun onlyThisPhonesAdbdIsTaken() {
        // mDNS also sees the Mac's and other phones' Wireless debugging on the LAN; IPv6 answers carry a scope.
        val found = listOf(arrayOf("192.168.50.77", "41111"), arrayOf("fe80::1%wlan0", "42222"), arrayOf("192.168.50.18", "39715"))
        assertEquals(42222, AdbLink.ownPort(found, setOf("127.0.0.1", "fe80::1", "192.168.50.18")))
        assertEquals(39715, AdbLink.ownPort(found.drop(2), setOf("192.168.50.18", "10.13.13.8")))
        assertEquals(-1, AdbLink.ownPort(found.take(1), setOf("192.168.50.18")))
        assertEquals(-1, AdbLink.ownPort(emptyList(), setOf("192.168.50.18")))
    }

    @Test
    fun thePairLineNeedsAPortAndASixDigitCode() {
        assertEquals("127.0.0.1:37001 482913\n", AdbLink.pairLine(37001, " 482 913 "))
        assertNull(AdbLink.pairLine(-1, "482913")) // the pairing dialog not found yet
        assertNull(AdbLink.pairLine(37001, "48291")) // a typo
        assertNull(AdbLink.pairLine(37001, "abcdef"))
        assertNull(AdbLink.pairLine(37001, null))
    }
}
