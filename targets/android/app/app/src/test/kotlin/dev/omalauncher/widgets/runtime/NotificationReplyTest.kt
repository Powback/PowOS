package dev.omalauncher.widgets.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** What needs me's inline reply (Notifications.action): what goes into the notification's own RemoteInputs, and when nothing is pressed. */
class NotificationReplyTest {
    @Test
    fun replyFillsEveryFreeFormInput() {
        assertEquals(mapOf("reply" to "on my way"), Notifications.replyResults(listOf("reply"), "on my way"))
        assertEquals(mapOf("a" to "ok", "b" to "ok"), Notifications.replyResults(listOf("a", "b"), "ok"))
    }

    @Test
    fun replyIsTrimmed() {
        assertEquals(mapOf("reply" to "hi"), Notifications.replyResults(listOf("reply"), "  hi \n"))
    }

    @Test
    fun plainPressTypesNothing() {
        assertEquals(emptyMap<String, String>(), Notifications.replyResults(listOf("reply"), null))
        assertEquals(emptyMap<String, String>(), Notifications.replyResults(emptyList(), null))
    }

    @Test
    fun blankReplyIsNotPressed() {
        assertNull(Notifications.replyResults(listOf("reply"), "   "))
        assertNull(Notifications.replyResults(listOf("reply"), ""))
    }

    @Test
    fun textForAnActionWithoutAFieldIsNotPressed() {
        assertNull(Notifications.replyResults(emptyList(), "on my way"))
    }
}
