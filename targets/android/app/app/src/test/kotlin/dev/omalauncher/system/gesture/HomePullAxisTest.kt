package dev.omalauncher.system.gesture

import dev.omalauncher.system.gesture.HomePullAxis.Verdict
import org.junit.Assert.assertEquals
import org.junit.Test

/** The shade's pull on home's body: the page's axis lock (gesture.ts), never a mostly-sideways drag. */
class HomePullAxisTest {
    // The phone: ~2.75 px/dp; the page decides at 10 dp.
    private val at = HomePullAxis.DECIDE_DP * 2.75f

    @Test fun shortIsUndecided() = assertEquals(Verdict.UNDECIDED, HomePullAxis.decide(10f, 12f, at))

    @Test fun straightDownPulls() = assertEquals(Verdict.PULL, HomePullAxis.decide(4f, 40f, at))

    @Test fun steepDownPulls() = assertEquals(Verdict.PULL, HomePullAxis.decide(20f, 40f, at))

    // The report: a drag along the recents strip that dips down as much as it goes sideways - the old 45 deg rule pulled.
    @Test fun diagonalNeverPulls() = assertEquals(Verdict.NOT_A_PULL, HomePullAxis.decide(30f, 30f, at))

    @Test fun mostlySidewaysNeverPulls() = assertEquals(Verdict.NOT_A_PULL, HomePullAxis.decide(-40f, 25f, at))

    @Test fun upIsNotAPull() = assertEquals(Verdict.NOT_A_PULL, HomePullAxis.decide(0f, -20f, at))

    @Test fun claimedByThePageIsNotAPull() = assertEquals(Verdict.NOT_A_PULL, HomePullAxis.decide(2f, 60f, at, claimed = true))
}
