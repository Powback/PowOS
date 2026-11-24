package dev.omalauncher.system.gesture

import kotlin.math.abs
import kotlin.math.hypot

/**
 * Whether a finger on home's body is the shade's pull - the same axis lock as home's page (shell ui/gesture.ts claimOnHome,
 * VERTICAL_RATIO and SLOP), so the host and the page never both take one drag. The user, 11-23: "scrolling the
 * recent-apps bar on home SOMETIMES activates the notification screen": the host took any move past the touch slop
 * that was down by at least as much as sideways (45 deg), earlier (8 dp) than the page decided (10 CSS px) - a drag
 * along a strip that dipped first, or a diagonal the page read as sideways, became a pull.
 *
 * Now: undecided until the finger is [decideAt] px from its down (the page's SLOP, in device px); then locked - a pull
 * only when down by more than [VERTICAL_RATIO] x sideways, anything else never (a sideways drag, a scroller's, the
 * page's swipe). Locked means locked (hysteresis): a drag that turns down later stays not-a-pull. The page can also
 * decide first ([claimed]: shade.homeClaim, a scroller or the pages took it sideways) - never a pull then.
 */
object HomePullAxis {
    /** gesture.ts VERTICAL_RATIO: vertical only when clearly so (> ~54 deg off the horizontal). */
    const val VERTICAL_RATIO = 1.4f

    /** gesture.ts SLOP (CSS px = dp): where the page decides; the host decides at the same distance. */
    const val DECIDE_DP = 10f

    enum class Verdict { UNDECIDED, PULL, NOT_A_PULL }

    fun decide(
        dx: Float,
        dy: Float,
        decideAt: Float,
        claimed: Boolean = false,
    ): Verdict {
        if (claimed) return Verdict.NOT_A_PULL
        // Up past the slop is never a pull (the launcher's, or the page's); short of the decision, wait.
        if (dy < -decideAt / 2) return Verdict.NOT_A_PULL
        if (hypot(dx, dy) < decideAt) return Verdict.UNDECIDED
        return if (dy > abs(dx) * VERTICAL_RATIO) Verdict.PULL else Verdict.NOT_A_PULL
    }
}
