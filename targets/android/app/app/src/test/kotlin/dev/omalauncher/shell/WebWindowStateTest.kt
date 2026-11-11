package dev.omalauncher.shell

import dev.omalauncher.shell.WebWindowMachine.Effect
import dev.omalauncher.shell.WebWindowMachine.Event
import dev.omalauncher.shell.WebWindowMachine.Facts
import dev.omalauncher.shell.WebWindowMachine.Fx
import dev.omalauncher.shell.WebWindowMachine.Kind
import dev.omalauncher.shell.WebWindowMachine.KwinEvent
import dev.omalauncher.shell.WebWindowMachine.PageEvent
import dev.omalauncher.shell.WebWindowMachine.Phase
import dev.omalauncher.shell.WebWindowMachine.Step
import dev.omalauncher.shell.WebWindowMachine.TaskEvent
import dev.omalauncher.shell.WebWindowMachine.WinState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/*
 * Windows fix plan 3.3: the old WebWindows*Test cases ported onto the pure state machine (WebWindowState.kt). The old
 * tests stay: they test today's WebWindows; these prove the machine does the same, case by case. Behaviour that looks
 * wrong is kept faithful and marked SUSPECT (listed in the plan's 3.3 note).
 */

private val main = WebWindows.Companion.At.MAIN
private val own = WebWindows.Companion.At.OWN
private val elsewhere = WebWindows.Companion.At.ELSEWHERE

/** A landed Android window on its display. */
private fun android(id: Int = 1) = WinState(Kind(id), facts = Facts(landed = true))

/** A Linux (KWin) window; [game]: immersive full screen. */
private fun linux(
    id: Int = 7,
    game: Boolean = false,
) = WinState(Kind(id, linux = true, game = game, hasDisplay = false))

/** The events applied in order: the last step (its state and that event's effects). */
private fun WinState.run(vararg es: Event): Step = es.fold(Step(this)) { st, e -> WebWindowMachine.step(st.state, e) }

private fun Step.fx(): List<Fx> = effects.map { it.fx }

private fun Step.has(
    fx: Fx,
    on: Boolean? = null,
) = effects.contains(Effect(fx, on))

private fun kwinOn(
    focused: Int,
    open: List<Int>,
    coming: Boolean = false,
) = KwinEvent.FullScreen(true, focused, open, coming)

/** Port of WebWindowsSelfFullScreenTest: KWin's own full screen covers only the user's window, else held. */
class WebWindowStateSelfFullScreenTest {
    private fun heldBy(e: KwinEvent.FullScreen): Step = linux(7).run(e)

    @Test
    fun aBackgroundGameNeverCoversTheWindowJustOpenedInFront() {
        for (e in listOf(kwinOn(15, listOf(7, 11, 12, 15)), kwinOn(-1, listOf(7, 11, 12, 15)), kwinOn(-1, listOf(7), coming = true), kwinOn(7, listOf(15)))) {
            val s = heldBy(e)
            assertTrue("$e: held", s.state.held)
            assertEquals("$e: not full screen", Phase.Live, s.state.phase)
            assertTrue("$e: nothing covers the screen", s.effects.isEmpty())
        }
    }

    @Test
    fun theUsersOwnWindowStillGoesFullScreenByItself() {
        for ((id, e) in listOf(7 to kwinOn(7, listOf(7, 15)), 16 to kwinOn(-1, listOf(7, 15, 16)), 15 to kwinOn(9, listOf(7, 15)))) {
            val s = linux(id).run(e)
            assertEquals("$id: full screen, sized now (not asked)", Phase.FullLinux(asked = false), s.state.phase)
            assertTrue(s.has(Fx.COVER_SCREEN) && s.has(Fx.RESIZE_TO_SCREEN) && s.has(Fx.EMIT_FULL, true))
            assertFalse(s.state.held)
        }
    }

    @Test
    fun aHeldFullScreenWaitsForTheUserAndKwinsZeroDropsIt() {
        val held = linux(7).run(kwinOn(15, listOf(7, 15)))
        val came = held.state.run(PageEvent.Focus)
        assertEquals(Phase.FullLinux(asked = false), came.state.phase)
        assertTrue("applied when the user comes to it", came.has(Fx.RESIZE_TO_SCREEN) && came.has(Fx.EMIT_FULL, true))
        assertFalse(came.state.held)
        val dropped = held.state.run(KwinEvent.FullScreen(false), PageEvent.Focus)
        assertEquals("KWin's 0 dropped the hold: a focus does nothing", Phase.Live, dropped.state.phase)
        assertTrue(dropped.effects.isEmpty())
    }

    /** SUSPECT: a held full screen survives a minimise; the next focus puts the minimised window full screen. */
    @Test
    fun aHeldFullScreenSurvivesAMinimise() {
        val s = linux(7).run(kwinOn(15, listOf(7, 15)), PageEvent.Minimise, PageEvent.Focus)
        assertTrue(s.state.minimised)
        assertTrue(s.state.phase is Phase.FullLinux)
        assertEquals("full", s.state.listed)
    }

    @Test
    fun anAskedFullScreenIsConfirmedNotHeld() {
        val s = linux(7).run(PageEvent.FullScreen(kwinCan = true), kwinOn(15, listOf(7, 15)))
        assertEquals(Phase.FullLinux(asked = false), s.state.phase)
        assertEquals("KWin's answer sizes it", listOf(Fx.RESIZE_TO_SCREEN), s.fx())
        assertFalse(s.state.held)
    }
}

/** Port of WebWindowsMinimisePipTest: minimiseGoesPip's cases and the leave's HOME step, as transitions. */
class WebWindowStateMinimisePipTest {
    @Test
    fun onlyAnAndroidWindowOnItsDisplayNotLeftAlreadyStartsTheHomeGesture() {
        val a = android().run(PageEvent.Minimise)
        assertEquals(listOf(Fx.EMIT_STATE, Fx.START_LEAVE), a.fx())
        assertTrue(a.state.minimised)
        assertEquals("minimised", a.state.listed)
        assertFalse("linux", linux().run(PageEvent.Minimise).has(Fx.START_LEAVE))
        assertFalse("no display", WinState(Kind(1, hasDisplay = false)).run(PageEvent.Minimise).has(Fx.START_LEAVE))
        val left = android().run(PageEvent.Minimise, TaskEvent.LeaveMoved(true))
        assertEquals(Phase.MinimisedAsPip, left.state.phase)
        assertTrue("left already: nothing", left.state.run(PageEvent.Minimise).effects.isEmpty())
    }

    @Test
    fun noPipSupportOrAFailedMoveIsJustHidden() {
        // supportsPip false: leaveNow returns before any move (no LeaveMoved): still Minimised.
        assertEquals("Minimised", android().run(PageEvent.Minimise).state.name)
        val failed = android().run(PageEvent.Minimise, TaskEvent.LeaveMoved(false))
        assertEquals("Minimised", failed.state.name)
        assertTrue(failed.has(Fx.MARK_FULL_TASK, false))
    }

    @Test
    fun homeOnlyWhileLeft() {
        val left = android().run(PageEvent.Minimise, TaskEvent.LeaveMoved(true))
        assertEquals(listOf(Fx.START_HOME), left.state.run(TaskEvent.LeaveFront).fx())
        assertTrue("restored meanwhile: no home", left.state.run(PageEvent.Restore, TaskEvent.LeaveFront).effects.isEmpty())
    }

    @Test
    fun aFullScreenAppIsNotMinimised() {
        val full = android().run(PageEvent.FullScreen(), TaskEvent.FullMoved(task = true, ok = true))
        assertTrue(full.state.run(PageEvent.Minimise).effects.isEmpty())
        assertFalse(full.state.run(PageEvent.Minimise).state.minimised)
    }

    @Test
    fun restoreAndTheSettledLeave() {
        val left = android().run(PageEvent.Minimise, TaskEvent.LeaveMoved(true)).state
        val back = left.run(PageEvent.Restore)
        assertEquals(Phase.Live, back.state.phase)
        assertEquals(listOf(Fx.EMIT_STATE, Fx.BACK_FROM_LEFT, Fx.MARK_FULL_TASK), back.fx())
        val front = left.run(TaskEvent.LeftTaskSettled(alive = true, front = true))
        assertEquals("PiP expanded: back in its window, shown", "Live", front.state.name)
        assertTrue(front.has(Fx.EMIT_SHOW) && front.has(Fx.BACK_FROM_LEFT))
        val gone = left.run(TaskEvent.LeftTaskSettled(alive = false, front = false))
        assertEquals("PiP dismissed: the window closes", Phase.Closed, gone.state.phase)
        assertFalse("leftAt cleared before the drop: no second removal", gone.has(Fx.REMOVE_TASK))
        assertTrue("still in PiP: nothing", left.run(TaskEvent.LeftTaskSettled(alive = true, front = false)).effects.isEmpty())
    }

    /** SUSPECT: a restore of a window whose app went to PiP by itself only clears the dock flag; the app stays in PiP. */
    @Test
    fun restoreOfAPipWindowOnlyClearsTheFlag() {
        val s = android().run(TaskEvent.TaskSeen(main, 2), PageEvent.Minimise, PageEvent.Restore)
        assertEquals(Phase.Pip, s.state.phase)
        assertEquals(listOf(Fx.EMIT_STATE), s.fx())
    }
}

/** Port of WebWindowsReconcileTest: the orphan rule, follow and PiP as transitions. */
class WebWindowStateReconcileTest {
    private fun orphanCheck(s: WinState) = s.run(TaskEvent.DisplayTasks(0)).has(Fx.CONFIRM_ORPHAN)

    @Test
    fun aWindowWhoseTaskLeftItsDisplayIsAnOrphanAndClosesOnTheConfirm() {
        assertTrue(orphanCheck(android()))
        val closed = android().run(TaskEvent.DisplayTasks(0), TaskEvent.OrphanConfirmed(0))
        assertEquals(Phase.Closed, closed.state.phase)
        assertEquals(listOf(Fx.DROP, Fx.EMIT_CLOSED), closed.fx())
        assertEquals("came back meanwhile: kept", Phase.Live, android().run(TaskEvent.OrphanConfirmed(1)).state.phase)
    }

    @Test
    fun aRunningWindowIsKeptAndLands() {
        val s = WinState(Kind(1)).run(TaskEvent.DisplayTasks(1))
        assertTrue(s.state.facts.landed)
        assertEquals(listOf(Fx.FILL_DISPLAY), s.fx())
    }

    @Test
    fun launchesFullScreenAdoptsUnknownsAndClosedAreKept() {
        assertFalse("still launching", orphanCheck(WinState(Kind(1))))
        assertFalse("relaunched: landed reset", orphanCheck(android().run(TaskEvent.Launched).state))
        assertFalse("full screen app out of the window", orphanCheck(android().run(PageEvent.FullScreen(), TaskEvent.FullMoved(true, true)).state))
        assertFalse("full screen in flight (the map)", orphanCheck(android().run(PageEvent.FullScreen()).state))
        assertFalse("adopting", orphanCheck(android().copy(facts = Facts(landed = true, adopt = true))))
        assertFalse("unreadable", android().run(TaskEvent.DisplayTasks(null)).has(Fx.CONFIRM_ORPHAN))
        assertTrue("closed", android().run(PageEvent.Close, TaskEvent.DisplayTasks(0)).effects.isEmpty())
    }

    @Test
    fun followsTheTaskWhereverItGoes() {
        fun seen(
            at: WebWindows.Companion.At,
            mode: Int,
        ) = android().run(TaskEvent.TaskSeen(at, mode))
        assertEquals("zoom on display 0", listOf(Fx.FOLLOW_BACK), seen(main, 100).fx())
        assertEquals("freeform on display 0", listOf(Fx.FOLLOW_BACK), seen(main, 5).fx())
        assertEquals("zoom in its own display", listOf(Fx.FOLLOW_BACK), seen(own, 100).fx())
        for (mode in listOf(1, 6)) {
            val full = seen(main, mode)
            assertEquals("mode $mode on display 0: its full-screen app", Phase.FullAndroid(), full.state.phase)
            assertEquals(listOf(Fx.HIDE_FRAME, Fx.MARK_FULL_TASK, Fx.EMIT_FULL), full.fx())
        }
        assertEquals("PiP (pipStep first, never Follow.PIP)", Phase.Pip, seen(main, 2).state.phase)
        assertTrue("full screen in its own display: nothing", seen(own, 1).effects.isEmpty())
        assertTrue("another display: the orphan rule decides", seen(elsewhere, 100).effects.isEmpty())
        val twice = android().run(TaskEvent.TaskSeen(main, 5), TaskEvent.TaskSeen(main, 5))
        assertTrue("once per place", twice.effects.isEmpty())
        val failed = android().run(TaskEvent.TaskSeen(main, 5), TaskEvent.FollowedBack(false), TaskEvent.TaskSeen(main, 5))
        assertEquals("a failed move is tried again", listOf(Fx.FOLLOW_BACK), failed.fx())
        assertEquals(listOf(Fx.EMIT_SHOW), android().run(TaskEvent.TaskSeen(main, 5), TaskEvent.FollowedBack(true)).fx())
    }

    @Test
    fun anAppLeavingForPipIsTrackedAndComesBack() {
        for ((at, mode, float) in listOf(Triple(main, 2, false), Triple(own, 2, false), Triple(main, 100, true))) {
            val s = android().run(TaskEvent.TaskSeen(at, mode, float))
            assertEquals("$at $mode $float", Phase.Pip, s.state.phase)
            assertEquals(listOf(Effect(Fx.MARK_PIP, true), Effect(Fx.HIDE_FRAME), Effect(Fx.EMIT_PIP, true)), s.effects)
            assertEquals("pip", s.state.listed)
        }
        val pip = android().run(TaskEvent.TaskSeen(main, 2)).state
        assertTrue("PowOS's own float: follow pulls it back, not PiP", android().run(TaskEvent.TaskSeen(main, 5)).has(Fx.FOLLOW_BACK))
        assertTrue("in PiP still", pip.run(TaskEvent.TaskSeen(main, 2)).effects.isEmpty())
        val expanded = pip.run(TaskEvent.TaskSeen(main, 1))
        assertEquals("expanded on display 0: moved back first", listOf(Fx.PIP_MOVE_BACK), expanded.fx())
        assertEquals(Phase.Pip, expanded.state.phase)
        assertEquals(Phase.Live, expanded.state.run(TaskEvent.PipBack(true)).state.phase)
        assertEquals("move failed: still PiP", Phase.Pip, expanded.state.run(TaskEvent.PipBack(false)).state.phase)
        val home = pip.run(TaskEvent.TaskSeen(own, 1))
        assertEquals("back on its own display", Phase.Live, home.state.phase)
        assertEquals(listOf(Effect(Fx.MARK_PIP, false), Effect(Fx.EMIT_PIP, false)), home.effects)
        assertTrue("another display", android().run(TaskEvent.TaskSeen(elsewhere, 2)).effects.isEmpty())
    }

    /** SUSPECT: minimised while in PiP, then expanded: back in the window but still listed minimised. */
    @Test
    fun aPipWindowMinimisedComesBackStillMinimised() {
        val s = android().run(TaskEvent.TaskSeen(main, 2), PageEvent.Minimise, TaskEvent.TaskSeen(own, 1))
        assertEquals(Phase.Live, s.state.phase)
        assertEquals("minimised", s.state.listed)
    }

    @Test
    fun aTaskGoneClosesTheWindowWhateverItsState() {
        for (s in listOf(android(), android().run(PageEvent.FullScreen(), TaskEvent.FullMoved(true, true)).state)) {
            val gone = s.run(TaskEvent.TaskGone)
            assertEquals(Phase.Closed, gone.state.phase)
            assertEquals("full / leftAt cleared first: nothing left to remove", listOf(Fx.MARK_FULL_TASK, Fx.DROP, Fx.EMIT_CLOSED), gone.fx())
        }
        assertEquals("adopting: never", Phase.Live, android().copy(facts = Facts(adopt = true)).run(TaskEvent.TaskGone).state.phase)
    }

    @Test
    fun anAdoptThatFailedLaunchesInstead() {
        val s = WinState(Kind(1), facts = Facts(adopt = true))
        assertEquals("Opening", s.name)
        assertEquals(listOf(Fx.RELAUNCH), s.run(TaskEvent.AdoptDone(false)).fx())
        assertFalse(s.run(TaskEvent.AdoptDone(true)).state.facts.adopt)
    }
}

/** Port of WebWindowsHomeReturnTest's window side: a home-gesture minimise returns to its window, never full screen. */
class WebWindowStateHomeReturnTest {
    @Test
    fun aMinimisedAppBroughtToTheFrontReturnsToItsWindow() {
        val s = android().run(PageEvent.Minimise, TaskEvent.LeaveMoved(true), TaskEvent.LeftTaskSettled(alive = true, front = true))
        assertEquals(Phase.Live, s.state.phase)
        assertFalse(s.state.minimised)
        assertEquals("floating", s.state.listed)
    }

    @Test
    fun aMinimisedAppIsNotFollowedAsAFullScreenApp() {
        val left = android().run(PageEvent.Minimise, TaskEvent.LeaveMoved(true)).state
        assertTrue(left.run(TaskEvent.TaskSeen(main, 1)).effects.isEmpty())
    }
}

/** Port of WebWindowsImmersiveTest: a game's full screen is immersive, the bar hidden before the cover and back after. */
class WebWindowStateImmersiveTest {
    @Test
    fun fullScreenHidesTheBarAndLeavingBringsItBack() {
        val on = linux(game = true).run(PageEvent.FullScreen(kwinCan = true))
        assertEquals(Phase.FullLinux(asked = true, immersive = true), on.state.phase)
        assertEquals(listOf(Fx.KWIN_FULL, Fx.STATUS_BAR, Fx.COVER_SCREEN, Fx.EMIT_FULL, Fx.CONFIRM_TIMER), on.fx())
        assertTrue(on.has(Fx.STATUS_BAR, false))
        val off = on.state.run(PageEvent.ToWindow(kwinCan = true))
        assertEquals(listOf(Fx.KWIN_FULL, Fx.STATUS_BAR, Fx.PLACE_BACK, Fx.EMIT_FULL, Fx.RESEND), off.fx())
        assertTrue(off.has(Fx.STATUS_BAR, true))
        assertEquals(Phase.Live, off.state.phase)
    }

    @Test
    fun notAGameKeepsTheBar() {
        val on = linux(game = false).run(PageEvent.FullScreen(kwinCan = false))
        assertEquals(Phase.FullLinux(asked = false, immersive = false), on.state.phase)
        assertEquals("old KWin: full screen by PowOS alone, sized now", listOf(Fx.COVER_SCREEN, Fx.RESIZE_TO_SCREEN, Fx.EMIT_FULL), on.fx())
    }

    @Test
    fun aGameClosedWhileImmersiveBringsTheBarBack() {
        val s = linux(game = true).run(PageEvent.FullScreen(), PageEvent.Close)
        assertEquals(listOf(Fx.DROP, Fx.STATUS_BAR, Fx.EMIT_CLOSED), s.fx())
    }

    @Test
    fun noAnswerFromKwinSizesItOnce() {
        val on = linux().run(PageEvent.FullScreen())
        assertEquals(listOf(Fx.RESIZE_TO_SCREEN), on.state.run(KwinEvent.ConfirmTimeout).fx())
        assertTrue(on.state.run(KwinEvent.ConfirmTimeout, KwinEvent.ConfirmTimeout).effects.isEmpty())
    }
}

/** Port of WebWindowsFullScreenRaceTest's ordering: one cover per full screen; the way out places it before it says so. */
class WebWindowStateFullScreenRaceTest {
    @Test
    fun oneWriterOnTheWayInAndThePlaceQueuedOnTheWayOut() {
        val on = linux().run(PageEvent.FullScreen(kwinCan = false))
        assertEquals(1, on.fx().count { it == Fx.COVER_SCREEN })
        val off = on.state.run(KwinEvent.FullScreen(false))
        assertTrue(off.fx().indexOf(Fx.PLACE_BACK) in 0 until off.fx().indexOf(Fx.EMIT_FULL))
        assertTrue("again: a no-op", linux().run(PageEvent.FullScreen(), PageEvent.FullScreen()).effects.isEmpty())
    }

    @Test
    fun androidFullScreenHidesThenMovesAndAnnouncesOnTheAnswer() {
        val ask = android().run(PageEvent.FullScreen())
        assertEquals(listOf(Fx.HIDE_FRAME, Fx.MOVE_TO_MAIN), ask.fx())
        assertEquals("floating", ask.state.listed)
        val ok = ask.state.run(TaskEvent.FullMoved(task = true, ok = true))
        assertEquals(listOf(Fx.FILL_SCREEN, Fx.EMIT_FULL), ok.fx())
        assertEquals("full", ok.state.listed)
        val none = ask.state.run(TaskEvent.FullMoved(task = false, ok = false))
        assertEquals(listOf(Fx.EMIT_FULL, Fx.RESEND), none.fx())
        assertFalse("no task: landed untouched", WinState(Kind(1)).run(PageEvent.FullScreen(), TaskEvent.FullMoved(false, false)).state.facts.landed)
        assertEquals("a dock tap on it: to the front", listOf(Fx.FRONT), ok.state.run(PageEvent.FullScreen()).fx())
    }

    @Test
    fun closedDuringTheMoveTheAppGoesWithIt() {
        val s = android().run(PageEvent.FullScreen(), PageEvent.Close, TaskEvent.FullMoved(task = true, ok = true))
        assertEquals(listOf(Fx.REMOVE_TASK), s.fx())
        val full = android().run(PageEvent.FullScreen(), TaskEvent.FullMoved(true, true), PageEvent.Close)
        assertEquals("closed full screen: its task removed by the drop", listOf(Fx.DROP, Fx.REMOVE_TASK, Fx.EMIT_CLOSED), full.fx())
        assertEquals("closed floating: removed if still alive", listOf(Fx.DROP, Fx.EMIT_CLOSED, Fx.REMOVE_TASK_IF_ALIVE), android().run(PageEvent.Close).fx())
    }

    @Test
    fun backToAWindow() {
        val full = android().run(PageEvent.FullScreen(), TaskEvent.FullMoved(true, true)).state
        assertEquals(listOf(Fx.BACK_FROM_FULL), full.run(PageEvent.ToWindow()).fx())
        val back = full.run(TaskEvent.BackMoved(alive = true, ok = true))
        assertEquals(Phase.Live, back.state.phase)
        assertEquals(listOf(Fx.MARK_FULL_TASK, Fx.EMIT_FULL, Fx.RESEND), back.fx())
        assertEquals(listOf(Fx.RELAUNCH, Fx.MARK_FULL_TASK, Fx.EMIT_FULL, Fx.RESEND), full.run(TaskEvent.BackMoved(alive = false)).fx())
        assertEquals("move refused: still full", Phase.FullAndroid(), full.run(TaskEvent.BackMoved(alive = true, ok = false)).state.phase)
    }

    /** SUSPECT: "back to window" while the full-screen move is in flight says "not full", then the move lands as full. */
    @Test
    fun backToWindowDuringTheMoveIsOverruled() {
        val s = android().run(PageEvent.FullScreen(), PageEvent.ToWindow(), TaskEvent.FullMoved(true, true))
        assertEquals(Phase.FullAndroid(), s.state.phase)
        assertEquals(listOf(Fx.FILL_SCREEN, Fx.EMIT_FULL), s.fx())
    }
}

/** RL1 (page reload): unclaimed windows hidden after CLAIM_MS, a full-screen Linux window never; live once. */
class WebWindowStateReloadTest {
    @Test
    fun reloadClaimAndLive() {
        val loaded = android().run(PageEvent.PageLoaded)
        assertEquals(listOf(Fx.CLAIM_TIMER), loaded.fx())
        assertEquals(listOf(Fx.HIDE_UNCLAIMED), loaded.state.run(KwinEvent.ClaimTimeout).fx())
        assertTrue(loaded.state.run(PageEvent.Claimed, KwinEvent.ClaimTimeout).effects.isEmpty())
        assertEquals("a Linux window's consumer checked", listOf(Fx.CONSUMER_CHECK), linux().run(PageEvent.PageLoaded, PageEvent.Claimed).fx())
        assertTrue(linux().run(PageEvent.FullScreen(), PageEvent.PageLoaded, KwinEvent.ClaimTimeout).effects.isEmpty())
        assertEquals(listOf(Fx.EMIT_LIVE), android().run(PageEvent.Drawn).fx())
        assertTrue(android().run(PageEvent.Drawn, PageEvent.Drawn).effects.isEmpty())
    }
}
