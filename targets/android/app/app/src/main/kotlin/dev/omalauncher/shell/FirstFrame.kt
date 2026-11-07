package dev.omalauncher.shell

/**
 * When a Linux web window may drop its placeholder ([WebWindows.liveWhenDrawn]), pure so the JVM tests drive it.
 *
 * 11-06 16:46 the user saw Dolphin "live but blank": the window log has "consumer up" then "live" 270 ms later and
 * nothing about a frame - live was the consumer up plus [WebWindows.LIVE_AFTER_MS], so the page dropped the placeholder
 * (the body paints nothing once live) over a content layer that had no buffer yet: a hole. Now live = the consumer's
 * first present (native_consumer.c count_present, [andro.marchy.WebWindowSource.presented] > 0): the user sees the
 * placeholder until the app's own picture is there, never an empty frame.
 *
 * No frame [NUDGE_MS] after the consumer came up: KWin is asked to lay the window out again ([Act.NUDGE], once: a
 * window that drew before its consumer connected - a re-adopt, a KWin restart - draws again on a configure). Still none
 * at [GIVE_UP_MS]: [Act.GIVE_UP], the wait ends (logged); the page's own LINUX_START (20 s) then says "Its window never
 * drew." with a close, never a placeholder forever.
 */
internal object FirstFrame {
    enum class Act { LIVE, WAIT, NUDGE, GIVE_UP }

    const val NUDGE_MS = 1_500L
    const val GIVE_UP_MS = 25_000L

    /** [waited] ms since the consumer came up, [presented] its frames so far, [nudged] whether KWin was asked already. */
    fun step(
        waited: Long,
        presented: Long,
        nudged: Boolean,
    ): Act =
        when {
            presented > 0 -> Act.LIVE
            waited >= GIVE_UP_MS -> Act.GIVE_UP
            !nudged && waited >= NUDGE_MS -> Act.NUDGE
            else -> Act.WAIT
        }
}
