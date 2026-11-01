package dev.omalauncher.widgets.runtime

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** The shade's big picture: what size it's sent at, and that a notification without one has no "picture" field. */
class NotificationPictureTest {
    @Test
    fun wideIsCappedAt720KeepingAspect() {
        assertEquals(720 to 405, NotificationPicture.scaled(1920, 1080))
        assertEquals(720 to 540, NotificationPicture.scaled(4000, 3000))
    }

    @Test
    fun tallIsCappedByHeight() {
        assertEquals(360 to 1440, NotificationPicture.scaled(1000, 4000))
    }

    @Test
    fun smallIsNeverScaledUp() {
        assertEquals(400 to 300, NotificationPicture.scaled(400, 300))
        assertEquals(720 to 720, NotificationPicture.scaled(720, 720))
    }

    @Test
    fun extremeStripKeepsOnePixel() {
        assertEquals(720 to 1, NotificationPicture.scaled(100_000, 10))
    }

    @Test
    fun emptyIsNone() {
        assertNull(NotificationPicture.scaled(0, 100))
        assertNull(NotificationPicture.scaled(-1, -1))
    }

    @Test
    fun absentPictureHasNoField() {
        val o = NotificationPicture.put(JSONObject().put("key", "k"), NotificationPicture.url("https://o", "k", 5, has = false))
        assertFalse(o.has("picture"))
        assertNull(NotificationPicture.url("https://o", "k", 5, has = false))
    }

    @Test
    fun presentPictureIsAUrlNotBytes() {
        val o = NotificationPicture.put(JSONObject(), NotificationPicture.url("https://o", "0|pkg|1|null|10", 5, has = true))
        assertEquals("https://o/_npic/0%7Cpkg%7C1%7Cnull%7C10?t=5", o.getString("picture"))
    }
}
