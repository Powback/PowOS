package dev.omalauncher.system

import dev.omalauncher.system.KeyboardPlan.Default
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** PowOS's keyboard (DefaultKeyboard): the latest published build, gated, upgrades only; the default set once. */
class KeyboardPlanTest {
    @Test fun takesNewerPublishedBuild() {
        assertEquals(29895077L, KeyboardPlan.target(29890000L, 29895077L, emptySet()))
        assertEquals(29895077L, KeyboardPlan.target(null, 29895077L, emptySet()))
    }

    @Test fun neverDowngradesOrReinstalls() {
        assertNull(KeyboardPlan.target(29895077L, 29895077L, emptySet()))
        assertNull(KeyboardPlan.target(29895078L, 29895077L, emptySet()))
    }

    @Test fun skipsAFailedVersionUntilANewerOne() {
        assertNull(KeyboardPlan.target(1L, 5L, setOf(5L)))
        assertEquals(6L, KeyboardPlan.target(1L, 6L, setOf(5L)))
    }

    @Test fun storeUnreachableOrGarbageIsNothing() {
        assertNull(KeyboardPlan.target(1L, null, emptySet()))
        assertNull(KeyboardPlan.parseVersion("<html>"))
        assertNull(KeyboardPlan.parseVersion("0"))
        assertEquals(29895077L, KeyboardPlan.parseVersion("29895077\n"))
    }

    @Test fun gate() {
        val pkg = DefaultKeyboard.PACKAGE
        assertNull(KeyboardPlan.gate(KeyboardPlan.Archive(pkg, 7, true, true), 7))
        assertNull(KeyboardPlan.gate(KeyboardPlan.Archive(pkg, 7, true, null), 7))
        assertTrue(KeyboardPlan.gate(KeyboardPlan.Archive("com.other", 7, true, true), 7)!!.contains("package"))
        assertTrue(KeyboardPlan.gate(KeyboardPlan.Archive(pkg, 6, true, true), 7)!!.contains("advertised"))
        assertTrue(KeyboardPlan.gate(KeyboardPlan.Archive(pkg, 7, false, true), 7)!!.contains("input method"))
        assertTrue(KeyboardPlan.gate(KeyboardPlan.Archive(pkg, 7, true, false), 7)!!.contains("signed"))
    }

    @Test fun defaultWrittenWhenPermitted() {
        val d = KeyboardPlan.default(KeyboardPlan.State(true, "com.google/.Gboard", "com.google/.Gboard", false, true))
        assertEquals(Default.Write("com.google/.Gboard:${DefaultKeyboard.IME}", DefaultKeyboard.IME), d)
    }

    @Test fun defaultAskedWithoutPermission() {
        assertEquals(Default.Ask, KeyboardPlan.default(KeyboardPlan.State(true, "", "com.google/.Gboard", false, false)))
    }

    @Test fun defaultOnceOnly() {
        assertEquals(Default.None, KeyboardPlan.default(KeyboardPlan.State(true, "", "com.google/.Gboard", true, true)))
        assertEquals(Default.None, KeyboardPlan.default(KeyboardPlan.State(false, "", "com.google/.Gboard", false, true)))
        assertEquals(Default.None, KeyboardPlan.default(KeyboardPlan.State(true, DefaultKeyboard.IME, DefaultKeyboard.IME, false, true)))
        assertEquals(Default.None, KeyboardPlan.default(KeyboardPlan.State(true, "", "com.swipekeyboard/com.swipekeyboard.SwipeKeyboardService", false, true)))
    }

    @Test fun enabledListKeepsSubtypesAndDoesNotDuplicate() {
        assertEquals(DefaultKeyboard.IME, KeyboardPlan.withIme(null))
        assertEquals("a/.X;123:${DefaultKeyboard.IME};5", KeyboardPlan.withIme("a/.X;123:${DefaultKeyboard.IME};5"))
    }
}
