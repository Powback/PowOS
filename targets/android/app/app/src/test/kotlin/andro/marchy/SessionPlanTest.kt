package andro.marchy

import andro.marchy.SessionPlan.Action
import andro.marchy.SessionPlan.Health
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 11-04 emulator run: the no-root session started mid-install, never retried, and KWin was downgraded by the repo. */
class SessionPlanTest {
    @Test
    fun noStartWhileTheImageInstalls() {
        // rootfs not in place yet (download/unpack), or in place but the install (packs) not finished
        assertEquals(Action.WAIT_IMAGE, SessionPlan.next(false, false, false, Health.NOT_STARTED, 0))
        assertEquals(Action.WAIT_IMAGE, SessionPlan.next(false, true, true, Health.NOT_STARTED, 0))
        assertEquals(Action.START, SessionPlan.next(false, true, false, Health.NOT_STARTED, 0))
        assertTrue(SessionPlan.status(Action.WAIT_IMAGE, 0, 0)!!.contains("installing"))
    }

    @Test
    fun rootedNeverWaitsForTheAppImage() {
        assertEquals(Action.START, SessionPlan.next(true, false, true, Health.NOT_STARTED, 0))
    }

    @Test
    fun aStartThatDoesNotComeUpIsRetriedThenGivenUp() {
        assertEquals(Health.STARTING, SessionPlan.health(true, true, false, 10_000))
        assertEquals(Action.UP, SessionPlan.next(false, true, false, Health.STARTING, 1)) // still within its time
        val failed = SessionPlan.health(true, true, false, SessionPlan.START_TIMEOUT_MS)
        assertEquals(Health.FAILED, failed)
        assertEquals(Action.RETRY, SessionPlan.next(false, true, false, failed, 1))
        assertEquals(Action.GIVE_UP, SessionPlan.next(false, true, false, failed, SessionPlan.MAX_ATTEMPTS))
        assertTrue(SessionPlan.status(Action.RETRY, 2, 10_000)!!.contains("try 2 of"))
        assertTrue(SessionPlan.status(Action.GIVE_UP, 5, 0)!!.contains("Reopen"))
        assertNull(SessionPlan.status(Action.START, 0, 0))
    }

    @Test
    fun upNeedsBusAndCompositor() {
        assertEquals(Health.NOT_STARTED, SessionPlan.health(false, true, true, 0))
        assertEquals(Health.UP, SessionPlan.health(true, true, true, 1_000))
        assertEquals(Action.UP, SessionPlan.next(false, true, false, Health.UP, 1))
    }

    @Test
    fun retryPausesGrowAndCap() {
        assertEquals(5_000L, SessionPlan.retryDelayMs(1))
        assertEquals(10_000L, SessionPlan.retryDelayMs(2))
        assertEquals(40_000L, SessionPlan.retryDelayMs(4))
        assertEquals(60_000L, SessionPlan.retryDelayMs(9))
    }

    @Test
    fun aKilledCoreProcessFailsTheTryAtOnce() {
        // 11-09 razr: the storage grant SIGKILLed dbus + the display daemon 1 s in; the bus socket file stayed, so
        // the session counted as up and Plasma came up on a dead bus (blank desktop). A lost core process = FAILED.
        assertEquals(Health.FAILED, SessionPlan.health(true, true, true, 1_000, "dbus"))
        assertEquals(SessionPlan.Action.RETRY, SessionPlan.next(false, true, false, Health.FAILED, 0))
        assertEquals(Health.UP, SessionPlan.health(true, true, true, 1_000, null))
        assertEquals(Health.NOT_STARTED, SessionPlan.health(false, true, true, 0, "dbus"))
        for (core in listOf("dbus", "andromarchy", "system-dbus", "hyprland"))
            assertTrue(core, SessionPlan.CORE.contains(core))
        assertFalse("a side service ending is not a failed session", SessionPlan.CORE.contains("gnome-keyring"))
    }

    @Test
    fun packageUpdateNeverDowngrades() {
        val c = SessionPlan.packagesCommand()
        assertTrue(c.contains("-Syu"))
        assertFalse("installs the whole repo (-S --needed downgraded kwin 3.31 to 3.3)", c.contains("--needed"))
        assertFalse(c.contains("-uu"))
        assertFalse(c.contains("Slq"))
    }
}
