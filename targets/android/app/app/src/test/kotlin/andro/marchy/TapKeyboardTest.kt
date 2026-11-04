package andro.marchy

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 11-04 emulator, no root: System Settings' search took the focus as it opened and Android's keyboard came up untapped. */
class TapKeyboardTest {
    @Test
    fun anAskWithNoTouchIsHeldUntilTheUsersTap() {
        val t = TapKeyboard(true)
        assertFalse(t.show(10_000)) // the window opened, its search field took the focus
        assertTrue(t.held())
        t.down(12_000, 100f, 40f)
        assertTrue(t.up(12_080, 102f, 41f)) // the user's tap raises it
        t.shown()
        assertFalse(t.held())
    }

    @Test
    fun anAskRightAfterATouchIsTheUsers() {
        val t = TapKeyboard(true)
        t.down(5_000, 10f, 10f)
        assertTrue(t.show(5_150)) // the tap focused a text field
        assertFalse(t.show(5_000 + TapKeyboard.TOUCH_ASK_MS + 1)) // a later ask on its own is not
    }

    @Test
    fun aDragOrAHideRaisesNothing() {
        val t = TapKeyboard(true)
        assertFalse(t.show(1_000))
        t.down(2_000, 0f, 0f)
        assertFalse(t.up(2_100, 0f, 200f)) // a scroll, not a tap
        t.hide() // the field lost the focus
        t.down(3_000, 0f, 0f)
        assertFalse(t.up(3_050, 0f, 0f))
        assertFalse(TapKeyboard(true).up(100, 0f, 0f)) // no ask held: a tap alone raises nothing
    }

    @Test
    fun aTapRaisesItAgainWhileKwinsAskStands() {
        val t = TapKeyboard(true)
        t.down(1_000, 5f, 5f)
        assertTrue(t.show(1_100)) // up at once: the user's tap focused the field
        t.shown() // the user put it away with back; KWin still counts it up and asks nothing new
        t.down(9_000, 5f, 5f)
        assertTrue(t.up(9_050, 5f, 5f))
        assertTrue(t.held())
    }

    @Test
    fun anOlderKwinKeepsTheOldKeyboard() {
        // No "keyboard-live" (kwin < 3.63): KWin never moves its ask to the window, so every ask raises it at once.
        val t = TapKeyboard(false)
        assertTrue(t.show(10_000))
        t.down(12_000, 1f, 1f)
        assertFalse(t.up(12_050, 1f, 1f)) // and a tap adds nothing of its own
        assertFalse(t.held())
    }
}
