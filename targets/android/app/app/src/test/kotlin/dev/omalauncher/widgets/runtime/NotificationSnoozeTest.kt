package dev.omalauncher.widgets.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The shade's Snooze (Notifications.snooze): which durations the bridge passes on to snoozeNotification, which it refuses. */
class NotificationSnoozeTest {
    private val min = 60_000L
    private val hour = 60 * min

    @Test
    fun theMenusChoicesPass() {
        for (ms in listOf(15 * min, hour, 2 * hour, 9 * hour, 33 * hour)) assertEquals(ms, Notifications.snoozeMs(ms))
    }

    @Test
    fun edgesPass() {
        assertEquals(min, Notifications.snoozeMs(min))
        assertEquals(Notifications.SNOOZE_MAX_MS, Notifications.snoozeMs(Notifications.SNOOZE_MAX_MS))
    }

    /** A 0, negative or past-the-cap duration is an error the card rolls back on, never an instant re-post or a lost one. */
    @Test
    fun outOfRangeIsRefused() {
        assertNull(Notifications.snoozeMs(0))
        assertNull(Notifications.snoozeMs(-hour))
        assertNull(Notifications.snoozeMs(min - 1))
        assertNull(Notifications.snoozeMs(Notifications.SNOOZE_MAX_MS + 1))
        assertNull(Notifications.snoozeMs(Long.MAX_VALUE))
    }
}
