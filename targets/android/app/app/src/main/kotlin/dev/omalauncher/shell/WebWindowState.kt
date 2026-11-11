package dev.omalauncher.shell

/**
 * Windows fix plan 3.2 (docs/WINDOWS_FIX_PLAN.md, phase 3): one web window's state as ONE value and a pure transition
 * function `(state, event) -> (state, effects)` - no Android imports, no side effects; effects are plain data the
 * caller performs. NOTHING in [WebWindows] uses it yet (3.1's swap of `Win`'s flags is a later step): it is derived
 * from what WebWindows.kt does today with those flags (line numbers below are WebWindows.kt's at 11-11) and the 3.3
 * tests (WebWindowStateTest) prove it reproduces today's behaviour case by case, including behaviour that looks wrong
 * (kept faithful; listed in the plan's 3.3 note).
 *
 * Map from today's flags: [Phase] holds `full` (Android), `linuxFull` + `fullAsked` + `immersive` ([Phase.FullLinux]),
 * `pip`, `leftAt` ([Phase.MinimisedAsPip]) and `closed`; [WinState.minimised] and [WinState.held] (`fullHeld`) stay
 * booleans because today they are orthogonal to the phase (a window can be minimised in PiP or full screen, a held
 * full screen survives a minimise); [Facts] holds `landed`, `adopt`, `claimed`, `live`, `followed`. 3.1's names are
 * [WinState.name]: Opening = [Phase.Live] not landed yet (or adopting), Minimised = Live + [WinState.minimised].
 */
object WebWindowMachine {
    /** What a window is (fixed for its life): a Linux (KWin) window, a game's (immersive full screen), with a display. */
    data class Kind(
        val id: Int,
        val linux: Boolean = false,
        val game: Boolean = false,
        val hasDisplay: Boolean = true,
    )

    sealed interface Phase {
        /** On its display / in the page as a floating window (`full`, `linuxFull`, `pip`, `leftAt`, `closed` all off). */
        data object Live : Phase

        /** MN1 (`leftAt` != 0, :3343): minimised as a home gesture, its task on display 0 in PiP / behind home. */
        data object MinimisedAsPip : Phase

        /** PP1 (`pip`, :330): its app left the window by itself for PiP / its own floating window. */
        data object Pip : Phase

        /**
         * An Android window's app as a full-screen app on display 0 (`full`, :3629). [moving]: the bar's full screen asked
         * and its move on [WebWindows]' io thread not answered yet (`full` still false, the display map set, :3591).
         * [back]: "Back to window" asked meanwhile - taken back once the move lands ([toWindow]'s deferred ask).
         */
        data class FullAndroid(
            val moving: Boolean = false,
            val back: Boolean = false,
        ) : Phase

        /** A Linux window full screen (`linuxFull` and `full`, :3675/:3718); [asked]: `fullAsked` (:3570), KWin's answer due. */
        data class FullLinux(
            val asked: Boolean = false,
            val immersive: Boolean = false,
        ) : Phase

        /** `closed` (:3215): dropped. Every event is a no-op from here (today's `if (w.closed) return` guards). */
        data object Closed : Phase
    }

    /** The data beside the phase that today's flags carry. */
    data class Facts(
        val landed: Boolean = false,
        val adopt: Boolean = false,
        val claimed: Boolean = true,
        val live: Boolean = false,
        val followed: String? = null,
    )

    data class WinState(
        val kind: Kind,
        val phase: Phase = Phase.Live,
        val facts: Facts = Facts(),
        val minimised: Boolean = false,
        val held: Boolean = false,
    ) {
        /** 3.1's state name. */
        val name: String get() = nameOf(this)

        /** What "webwindows.list" says today (`listedState`, :245). */
        val listed: String get() = listedOf(this)
    }

    /** What the caller does. [on]: the boolean the effect carries (an emit's "on"/"minimised", a status bar's shown). */
    enum class Fx {
        EMIT_FULL, EMIT_STATE, EMIT_PIP, EMIT_SHOW, EMIT_LIVE, EMIT_CLOSED, RESEND,
        HIDE_FRAME, MOVE_TO_MAIN, FRONT, FILL_SCREEN, BACK_FROM_FULL, BACK_FROM_LEFT, MARK_FULL_TASK, MARK_PIP,
        START_LEAVE, START_HOME, PIP_MOVE_BACK, FOLLOW_BACK, RELAUNCH, CHECK_LANDED, FILL_DISPLAY,
        CONFIRM_ORPHAN, CLAIM_TIMER, HIDE_UNCLAIMED, CONSUMER_CHECK,
        KWIN_FULL, COVER_SCREEN, RESIZE_TO_SCREEN, PLACE_BACK, STATUS_BAR, CONFIRM_TIMER,
        DROP, REMOVE_TASK, REMOVE_TASK_IF_ALIVE,
    }

    data class Effect(
        val fx: Fx,
        val on: Boolean? = null,
    )

    data class Step(
        val state: WinState,
        val effects: List<Effect> = emptyList(),
    )

    sealed interface Event

    /** The page's asks. */
    sealed interface PageEvent : Event {
        data object Minimise : PageEvent

        data object Restore : PageEvent

        /** The bar's full screen; [kwinCan]: KWin takes full-screen requests (0043). */
        data class FullScreen(val kwinCan: Boolean = true) : PageEvent

        /** The switcher card's "Back to window". */
        data class ToWindow(val kwinCan: Boolean = true) : PageEvent

        /** The user came to this window ("focus" with its id). */
        data object Focus : PageEvent

        data object Close : PageEvent

        /** Home's page (re)loaded (`pageStarted`, :145). */
        data object PageLoaded : PageEvent

        /** The page's "w.f" names it (:1944). */
        data object Claimed : PageEvent

        /** Its content drew ([goLive], :2985). */
        data object Drawn : PageEvent
    }

    /** Task changes and the io thread's answers to the moves the effects asked for. */
    sealed interface TaskEvent : Event {
        /** [launch] (:4221): a (re)launch onto its display. */
        data object Launched : TaskEvent

        /** [adoptNow] (:1672): the adopted task moved onto its display ([ok]) or not (launched instead). */
        data class AdoptDone(val ok: Boolean) : TaskEvent

        /** `checkOrphan` / `landedOrFallback` (:645/:4144): its display's root task count, null = unreadable. */
        data class DisplayTasks(val n: Int?) : TaskEvent

        /** `confirmOrphan` (:620s): still empty [ORPHAN_CONFIRM_MS] later. */
        data class OrphanConfirmed(val n: Int?) : TaskEvent

        /** `confirmDead` (:530s): its task is in no running task and its display holds none. */
        data object TaskGone : TaskEvent

        /** `follow` (:555): its task seen [at] in windowing [mode]; [float]: the user's own floating window. */
        data class TaskSeen(
            val at: WebWindows.Companion.At,
            val mode: Int,
            val float: Boolean = false,
        ) : TaskEvent

        /** `pipLeave`'s move back (:347): [ok]. */
        data class PipBack(val ok: Boolean) : TaskEvent

        /** `followBack`'s move (:615): [ok]. */
        data class FollowedBack(val ok: Boolean) : TaskEvent

        /** `fullScreenNow` (:3580): [task] found on its display, moved to display 0 [ok]. */
        data class FullMoved(
            val task: Boolean,
            val ok: Boolean,
        ) : TaskEvent

        /** `toWindowNow` (:3991): its task [alive] (moved back [ok]) or gone (relaunched). */
        data class BackMoved(
            val alive: Boolean,
            val ok: Boolean = true,
        ) : TaskEvent

        /** `leaveNow` (:3336): the task found, its top supports PiP, moved to display 0 [ok]. */
        data class LeaveMoved(val ok: Boolean) : TaskEvent

        /** `awaitFront` -> `leaveHome` (:3398): [WebWindows.leaveStep] said HOME. */
        data object LeaveFront : TaskEvent

        /** `checkLeft` (:3496), after `LEFT_SETTLE_MS`: its task [alive], full screen and visible on display 0 [front]. */
        data class LeftTaskSettled(
            val alive: Boolean,
            val front: Boolean,
        ) : TaskEvent
    }

    /** KWin's lines and the real waits. */
    sealed interface KwinEvent : Event {
        /** "fullscreen <id> 1|0" (:3866): [focused], [open] and [coming] are [WebWindows.selfFullScreenNow]'s inputs. */
        data class FullScreen(
            val on: Boolean,
            val focused: Int = -1,
            val open: List<Int> = emptyList(),
            val coming: Boolean = false,
        ) : KwinEvent

        /** The 1.5 s with no KWin answer to a full-screen ask (:3576). */
        data object ConfirmTimeout : KwinEvent

        /** `CLAIM_MS` after a page load (`hideUnclaimed`, :169). */
        data object ClaimTimeout : KwinEvent
    }

    fun step(
        s: WinState,
        e: Event,
    ): Step =
        when {
            s.phase == Phase.Closed -> afterClose(s, e)
            e is PageEvent -> page(s, e)
            e is TaskEvent -> task(s, e)
            e is KwinEvent -> kwin(s, e)
            else -> Step(s)
        }

    // ---- page asks ----------------------------------------------------------------------------------------------------

    private fun page(
        s: WinState,
        e: PageEvent,
    ): Step =
        when (e) {
            PageEvent.Minimise -> minimise(s)
            PageEvent.Restore -> restore(s)
            is PageEvent.FullScreen -> fullScreen(s, e.kwinCan)
            is PageEvent.ToWindow -> toWindow(s, e.kwinCan)
            PageEvent.Focus -> focus(s)
            PageEvent.Close -> close(s)
            else -> pageFacts(s, e)
        }

    private fun pageFacts(
        s: WinState,
        e: PageEvent,
    ): Step =
        when (e) {
            // :145 every window unclaimed, the CLAIM_MS timer started (once per load, not per window: one effect each here).
            PageEvent.PageLoaded -> Step(s.copy(facts = s.facts.copy(claimed = false)), listOf(Effect(Fx.CLAIM_TIMER)))
            // :1944; a Linux window reclaimed checks its consumer (:1942).
            PageEvent.Claimed -> claimed(s)
            // goLive (:2983): once.
            PageEvent.Drawn -> if (s.facts.live) Step(s) else Step(s.copy(facts = s.facts.copy(live = true)), listOf(Effect(Fx.EMIT_LIVE)))
            else -> Step(s)
        }

    private fun claimed(s: WinState): Step {
        val fx = if (!s.facts.claimed && s.kind.linux) listOf(Effect(Fx.CONSUMER_CHECK)) else emptyList()
        return Step(s.copy(facts = s.facts.copy(claimed = true)), fx)
    }

    /** `minimise` (:3311): no-op while `full`; else minimised (told on change, :3329), a PiP-able home gesture asked. */
    private fun minimise(s: WinState): Step {
        val p = s.phase
        if (p is Phase.FullLinux || p == Phase.FullAndroid(moving = false)) return Step(s)
        val left = p == Phase.MinimisedAsPip
        val fx = mutableListOf<Effect>()
        if (!s.minimised) fx += Effect(Fx.EMIT_STATE, true)
        // minimiseGoesPip(linux, displayId, left, true): leaveNow then checks the real PiP support and finds the task.
        if (WebWindows.minimiseGoesPip(s.kind.linux, if (s.kind.hasDisplay) 0 else -1, left, true)) fx += Effect(Fx.START_LEAVE)
        return Step(s.copy(minimised = true), fx)
    }

    /** `restore` (:3477): the dock flag off; a home-gesture minimise ([Phase.MinimisedAsPip]) brought back ([backNow]). */
    private fun restore(s: WinState): Step {
        val fx = if (s.minimised) listOf(Effect(Fx.EMIT_STATE, false)) else emptyList()
        if (s.phase != Phase.MinimisedAsPip) return Step(s.copy(minimised = false), fx)
        // backNow (:3486): leftAt off, the task moved back (or relaunched: BACK_FROM_LEFT does both), the map cleared.
        return Step(s.copy(phase = Phase.Live, minimised = false), fx + Effect(Fx.BACK_FROM_LEFT) + Effect(Fx.MARK_FULL_TASK, false))
    }

    /** The page's `fullScreen(id)` (:3967) -> `fullScreen(win)` (:3557). */
    private fun fullScreen(
        s: WinState,
        kwinCan: Boolean,
    ): Step =
        when {
            s.phase is Phase.FullLinux -> Step(s)
            s.phase == Phase.FullAndroid(moving = false) -> Step(s, listOf(Effect(Fx.FRONT)))
            s.kind.linux -> linuxFullAsk(s, kwinCan)
            !s.kind.hasDisplay -> Step(s)
            // :3585: hidden at once, the move on io. Today this runs from PiP / MinimisedAsPip too (a second move).
            else -> Step(s.copy(phase = Phase.FullAndroid(moving = true)), listOf(Effect(Fx.HIDE_FRAME), Effect(Fx.MOVE_TO_MAIN)))
        }

    /** :3558-3578: KWin asked (its answer sizes it, 1.5 s timer) or, before kwin 0043, full screen by PowOS alone. */
    private fun linuxFullAsk(
        s: WinState,
        kwinCan: Boolean,
    ): Step {
        if (!kwinCan) return linuxFullOn(s, asked = false)
        val on = linuxFullOn(s, asked = true)
        return Step(on.state, listOf(Effect(Fx.KWIN_FULL, true)) + on.effects + Effect(Fx.CONFIRM_TIMER))
    }

    /**
     * `linuxFullScreen(win, true)` (:3651): immersive from the offer (:3832), the screen covered (`fillScreen`; sized now
     * unless [asked]), "webwindows.full" on. `fullHeld` is NOT cleared here (only KWin's "0" and [focus] clear it).
     */
    private fun linuxFullOn(
        s: WinState,
        asked: Boolean,
    ): Step {
        val fx = mutableListOf<Effect>()
        if (s.kind.game) fx += Effect(Fx.STATUS_BAR, false)
        fx += Effect(Fx.COVER_SCREEN)
        if (!asked) fx += Effect(Fx.RESIZE_TO_SCREEN)
        fx += Effect(Fx.EMIT_FULL, true)
        return Step(s.copy(phase = Phase.FullLinux(asked = asked, immersive = s.kind.game)), fx)
    }

    /** `linuxFullScreen(win, false)` (:3651): back in its window at the page's place, the bar back if immersive. */
    private fun linuxFullOff(s: WinState): Step {
        val p = s.phase as? Phase.FullLinux ?: return Step(s)
        val fx = mutableListOf<Effect>()
        if (p.immersive) fx += Effect(Fx.STATUS_BAR, true)
        fx += listOf(Effect(Fx.PLACE_BACK), Effect(Fx.EMIT_FULL, false), Effect(Fx.RESEND))
        return Step(s.copy(phase = Phase.Live), fx)
    }

    /** `toWindow` (:3977). */
    private fun toWindow(
        s: WinState,
        kwinCan: Boolean,
    ): Step {
        if (s.kind.linux) return linuxToWindow(s, kwinCan)
        val p = s.phase as? Phase.FullAndroid ?: return Step(s, listOf(Effect(Fx.EMIT_FULL, false)))
        // The move in flight: full off said now, the way back once it lands (`toWindow`'s io -> main re-ask).
        if (p.moving) return Step(s.copy(phase = p.copy(back = true)), listOf(Effect(Fx.EMIT_FULL, false)))
        return Step(s, listOf(Effect(Fx.BACK_FROM_FULL)))
    }

    private fun linuxToWindow(
        s: WinState,
        kwinCan: Boolean,
    ): Step {
        if (s.phase !is Phase.FullLinux) return Step(s, listOf(Effect(Fx.EMIT_FULL, false)))
        val off = linuxFullOff(s)
        return if (kwinCan) Step(off.state, listOf(Effect(Fx.KWIN_FULL, false)) + off.effects) else off
    }

    /** `focus` (:3436): a held full screen ([WinState.held]) applied now. */
    private fun focus(s: WinState): Step {
        if (!s.held) return Step(s)
        val cleared = s.copy(held = false)
        if (cleared.phase is Phase.FullLinux) return Step(cleared)
        return linuxFullOn(cleared, asked = false)
    }

    /** `close` (:3169) = `drop` + the app's task removed if it is still alive off its display. */
    private fun close(s: WinState): Step {
        val dropped = drop(s)
        if (s.kind.linux || away(s)) return dropped
        return Step(dropped.state, dropped.effects + Effect(Fx.REMOVE_TASK_IF_ALIVE))
    }

    /** `full || leftAt != 0` (close :3172, drop :3226): the app is on display 0 by the user's choice. */
    private fun away(s: WinState): Boolean = s.phase == Phase.FullAndroid(moving = false) || s.phase == Phase.MinimisedAsPip

    /** `drop` (:3207) + `dropLinux` (:1562): layers and display gone, an away app's task removed, the bar back. */
    private fun drop(s: WinState): Step {
        val fx = mutableListOf(Effect(Fx.DROP))
        if ((s.phase as? Phase.FullLinux)?.immersive == true) fx += Effect(Fx.STATUS_BAR, true)
        if (!s.kind.linux && away(s)) fx += Effect(Fx.REMOVE_TASK)
        fx += Effect(Fx.EMIT_CLOSED)
        return Step(s.copy(phase = Phase.Closed), fx)
    }

    // ---- tasks --------------------------------------------------------------------------------------------------------

    private fun task(
        s: WinState,
        e: TaskEvent,
    ): Step =
        when (e) {
            is TaskEvent.TaskSeen -> follow(s, e)
            is TaskEvent.DisplayTasks -> displayTasks(s, e.n)
            is TaskEvent.OrphanConfirmed -> orphanConfirmed(s, e.n)
            TaskEvent.TaskGone -> taskGone(s)
            is TaskEvent.PipBack -> pipBack(s, e.ok)
            is TaskEvent.FollowedBack -> followedBack(s, e.ok)
            else -> moves(s, e)
        }

    private fun moves(
        s: WinState,
        e: TaskEvent,
    ): Step =
        when (e) {
            is TaskEvent.FullMoved -> fullMoved(s, e)
            is TaskEvent.BackMoved -> backMoved(s, e)
            is TaskEvent.LeaveMoved -> leaveMoved(s, e.ok)
            TaskEvent.LeaveFront -> if (s.phase == Phase.MinimisedAsPip) Step(s, listOf(Effect(Fx.START_HOME))) else Step(s)
            is TaskEvent.LeftTaskSettled -> leftSettled(s, e)
            else -> launches(s, e)
        }

    private fun launches(
        s: WinState,
        e: TaskEvent,
    ): Step =
        when (e) {
            // launch (:4220): landed off, the 0.7 s / 3 s checks started.
            TaskEvent.Launched -> Step(s.copy(facts = s.facts.copy(landed = false)), listOf(Effect(Fx.CHECK_LANDED)))
            // adoptNow (:1670): adopt cleared; not moved: launched there instead (landed stays as it was until launch runs).
            is TaskEvent.AdoptDone -> Step(s.copy(facts = s.facts.copy(adopt = false)), if (e.ok) emptyList() else listOf(Effect(Fx.RELAUNCH)))
            else -> Step(s)
        }

    /** `confirmOrphan` (:612): still an orphan = closed the bar's way. */
    private fun orphanConfirmed(
        s: WinState,
        n: Int?,
    ): Step = if (orphaned(s, n)) drop(s) else Step(s)

    /** `pipLeave` (:347): moved back = out of PiP. */
    private fun pipBack(
        s: WinState,
        ok: Boolean,
    ): Step = if (ok && s.phase == Phase.Pip) pipOut(s) else Step(s)

    /** `gone`'s `held` (:665): full screen (the map is set before the move, so in flight too), minimised away, adopting. */
    private fun held(s: WinState): Boolean = s.phase is Phase.FullAndroid || s.phase == Phase.MinimisedAsPip || s.facts.adopt

    private fun orphaned(
        s: WinState,
        n: Int?,
    ): Boolean = WebWindows.orphaned(false, s.facts.landed, held(s), n)

    /** `checkOrphan` (:641): a task on its display = landed (and filled); known empty after landing = confirm later. */
    private fun displayTasks(
        s: WinState,
        n: Int?,
    ): Step {
        if (n == null || n <= 0) return Step(s, if (orphaned(s, n)) listOf(Effect(Fx.CONFIRM_ORPHAN)) else emptyList())
        return Step(s.copy(facts = s.facts.copy(landed = true)), listOf(Effect(Fx.FILL_DISPLAY)))
    }

    /** `taskDead` + `confirmDead` (:511/:529): not while adopting; full / leftAt dropped first, so nothing to remove. */
    private fun taskGone(s: WinState): Step {
        if (s.facts.adopt) return Step(s)
        val d = drop(s.copy(phase = Phase.Live))
        return Step(d.state, listOf(Effect(Fx.MARK_FULL_TASK, false)) + d.effects)
    }

    /**
     * `follow` (:555) via `followedTask` (:582): nothing while full / adopting / the map holds it (full in flight, a
     * home-gesture minimise); PiP first (`pipCheck`, :306), then `followOf` once per place ([Facts.followed]).
     */
    private fun follow(
        s: WinState,
        e: TaskEvent.TaskSeen,
    ): Step {
        if (held(s) || s.kind.linux) return Step(s)
        val pip = WebWindows.pipStep(s.phase == Phase.Pip, e.at, e.mode, e.float)
        return when {
            pip == WebWindows.Companion.Pip.ENTER -> pipIn(s)
            pip == WebWindows.Companion.Pip.LEAVE -> pipLeave(s, e.at)
            s.phase == Phase.Pip -> Step(s)
            else -> followOf(s, e)
        }
    }

    /** `pipEnter` (:323): frame dropped, tracked as PiP, the page told. `minimised` is kept as it was. */
    private fun pipIn(s: WinState): Step {
        val fx = listOf(Effect(Fx.MARK_PIP, true), Effect(Fx.HIDE_FRAME), Effect(Fx.EMIT_PIP, true))
        return Step(s.copy(phase = Phase.Pip, facts = s.facts.copy(followed = null)), fx)
    }

    /** `pipLeave` (:341): on its own display already = back now; on display 0 the move back answers ([TaskEvent.PipBack]). */
    private fun pipLeave(
        s: WinState,
        at: WebWindows.Companion.At,
    ): Step = if (at == WebWindows.Companion.At.OWN) pipOut(s) else Step(s, listOf(Effect(Fx.PIP_MOVE_BACK)))

    /** `pipLeave`'s back in its window: shown, so not minimised either (`minimisedIs(w, false)`, told on change). */
    private fun pipOut(s: WinState): Step {
        val state = if (s.minimised) listOf(Effect(Fx.EMIT_STATE, false)) else emptyList()
        val fx = listOf(Effect(Fx.MARK_PIP, false)) + state + Effect(Fx.EMIT_PIP, false)
        return Step(s.copy(phase = Phase.Live, facts = s.facts.copy(followed = null), minimised = false), fx)
    }

    /**
     * `follow`'s `followOf` part (:563-577). Follow.PIP can't come here: pipStep took every PiP (mode 2) first - kept as
     * in WebWindows (same effect as pipIn; followOf is a pinned rule), see the plan's 3.3 suspect 5.
     */
    private fun followOf(
        s: WinState,
        e: TaskEvent.TaskSeen,
    ): Step {
        val own = e.at == WebWindows.Companion.At.OWN
        val act = WebWindows.followOf(own, e.at == WebWindows.Companion.At.MAIN, e.mode)
        if (act == null) return if (own) Step(s.copy(facts = s.facts.copy(followed = null))) else Step(s)
        val key = "${e.at}/${e.mode}"
        if (s.facts.followed == key) return Step(s)
        val next = s.copy(facts = s.facts.copy(followed = key))
        return when (act) {
            WebWindows.Companion.Follow.BACK -> Step(next, listOf(Effect(Fx.FOLLOW_BACK)))
            // followNow FULL (:603): hidden, mapped, announced full - its `minimised` kept.
            WebWindows.Companion.Follow.FULL -> Step(next.copy(phase = Phase.FullAndroid()), listOf(Effect(Fx.HIDE_FRAME), Effect(Fx.MARK_FULL_TASK, true), Effect(Fx.EMIT_FULL, true)))
            WebWindows.Companion.Follow.PIP -> pipIn(next)
        }
    }

    /** `followBack` (:612): moved = the page shows it; not = [Facts.followed] cleared (tried again on the next change). */
    private fun followedBack(
        s: WinState,
        ok: Boolean,
    ): Step = if (ok) Step(s, listOf(Effect(Fx.EMIT_SHOW))) else Step(s.copy(facts = s.facts.copy(followed = null)))

    /** `fullScreenNow` (:3580) + `announce` (:3618). */
    private fun fullMoved(
        s: WinState,
        e: TaskEvent.FullMoved,
    ): Step {
        val p = s.phase as? Phase.FullAndroid
        if (p?.moving != true) return Step(s)
        val facts = if (e.task) s.facts.copy(landed = true) else s.facts
        if (e.task && e.ok) {
            val back = if (p.back) listOf(Effect(Fx.BACK_FROM_FULL)) else emptyList()
            return Step(s.copy(phase = Phase.FullAndroid(), facts = facts), listOf(Effect(Fx.FILL_SCREEN), Effect(Fx.EMIT_FULL, true)) + back)
        }
        val unmark = if (e.task) listOf(Effect(Fx.MARK_FULL_TASK, false)) else emptyList()
        return Step(s.copy(phase = Phase.Live, facts = facts), unmark + Effect(Fx.EMIT_FULL, false) + Effect(Fx.RESEND))
    }

    /** `toWindowNow` (:3991): moved back (or relaunched when gone), unmapped, "webwindows.full" off. */
    private fun backMoved(
        s: WinState,
        e: TaskEvent.BackMoved,
    ): Step {
        if (s.phase != Phase.FullAndroid(moving = false) || (e.alive && !e.ok)) return Step(s)
        val relaunch = if (e.alive) emptyList() else listOf(Effect(Fx.RELAUNCH))
        val fx = relaunch + listOf(Effect(Fx.MARK_FULL_TASK, false), Effect(Fx.EMIT_FULL, false), Effect(Fx.RESEND))
        return Step(s.copy(phase = Phase.Live), fx)
    }

    /** `leaveNow` (:3336): moved = minimised as a home gesture, waiting for the task in front; else "just hidden". */
    private fun leaveMoved(
        s: WinState,
        ok: Boolean,
    ): Step {
        if (s.phase != Phase.Live || !s.minimised) return Step(s)
        if (!ok) return Step(s, listOf(Effect(Fx.MARK_FULL_TASK, false)))
        return Step(s.copy(phase = Phase.MinimisedAsPip), listOf(Effect(Fx.MARK_FULL_TASK, true)))
    }

    /** `checkLeft` (:3496): gone = the window closes with it (`leftGone`); in front = back in its window, shown. */
    private fun leftSettled(
        s: WinState,
        e: TaskEvent.LeftTaskSettled,
    ): Step {
        if (s.phase != Phase.MinimisedAsPip) return Step(s)
        if (!e.alive) return taskGone(s.copy(phase = Phase.Live))
        if (!e.front) return Step(s)
        val r = restore(s)
        return Step(r.state, r.effects + Effect(Fx.EMIT_SHOW))
    }

    // ---- KWin and timers ----------------------------------------------------------------------------------------------

    private fun kwin(
        s: WinState,
        e: KwinEvent,
    ): Step =
        when (e) {
            is KwinEvent.FullScreen -> if (e.on) kwinOn(s, e) else linuxFullOff(s.copy(held = false))
            KwinEvent.ConfirmTimeout -> confirmed(s)
            // hideUnclaimed (:170): not a full-screen Linux window.
            KwinEvent.ClaimTimeout -> if (s.facts.claimed || s.phase is Phase.FullLinux) Step(s) else Step(s, listOf(Effect(Fx.HIDE_UNCLAIMED)))
        }

    /** `fullScreenConfirmed` (:3848): KWin answered (or never did): sized now. */
    private fun confirmed(s: WinState): Step {
        val p = s.phase as? Phase.FullLinux ?: return Step(s)
        if (!p.asked) return Step(s)
        return Step(s.copy(phase = p.copy(asked = false)), listOf(Effect(Fx.RESIZE_TO_SCREEN)))
    }

    /** KWin's "fullscreen <id> 1" (:3863): confirms an ask, else covers the screen only if the window is the user's. */
    private fun kwinOn(
        s: WinState,
        e: KwinEvent.FullScreen,
    ): Step {
        if (!s.kind.linux) return Step(s)
        if (s.phase is Phase.FullLinux) return confirmed(s)
        if (WebWindows.selfFullScreenNow(s.kind.id, e.focused, e.open, e.coming)) return linuxFullOn(s, asked = false)
        return Step(s.copy(held = true))
    }

    /** Closed: only a full-screen move answering late still acts - its app goes with the closed window (:3597). */
    private fun afterClose(
        s: WinState,
        e: Event,
    ): Step =
        if (e is TaskEvent.FullMoved && e.task) Step(s, listOf(Effect(Fx.REMOVE_TASK))) else Step(s)

    // ---- names --------------------------------------------------------------------------------------------------------

    private fun nameOf(s: WinState): String =
        when (val p = s.phase) {
            Phase.Closed -> "Closing"
            is Phase.FullLinux -> "FullLinux"
            is Phase.FullAndroid -> if (p.moving) liveName(s) else "FullAndroid"
            Phase.Pip -> "Pip"
            Phase.MinimisedAsPip -> "MinimisedAsPip"
            Phase.Live -> liveName(s)
        }

    private fun liveName(s: WinState): String =
        when {
            s.minimised -> "Minimised"
            s.facts.adopt || (!s.kind.linux && !s.facts.landed) -> "Opening"
            else -> "Live"
        }

    /** `listedState` (:245): full first, then pip, then minimised (leftAt or the dock flag), else floating. */
    private fun listedOf(s: WinState): String =
        when (s.phase) {
            is Phase.FullLinux -> "full"
            Phase.FullAndroid() -> "full"
            Phase.Pip -> "pip"
            Phase.MinimisedAsPip -> "minimised"
            else -> if (s.minimised) "minimised" else "floating"
        }
}
