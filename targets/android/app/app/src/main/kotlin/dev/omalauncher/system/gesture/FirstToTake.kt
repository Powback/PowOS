package dev.omalauncher.system.gesture

import android.view.MotionEvent

/**
 * Two consumers that both follow a finger down on the same place until one of them takes it: home's body, where a
 * drag down is the shade's pull ([dev.omalauncher.system.ShadeHost.pull]) and a drag up the launcher overlay's
 * ([dev.omalauncher.system.PullHost.homeLift]). [GestureMonitor] gives a gesture to the first consumer that follows it,
 * so the two are asked as one: the one that takes it gets the rest, the other hears a cancel.
 */
class FirstToTake(
    private vararg val consumers: GestureConsumer,
) : GestureConsumer {
    private val live = mutableListOf<GestureConsumer>()

    override fun onDown(e: MotionEvent): Boolean {
        live.clear()
        consumers.filterTo(live) { runCatching { it.onDown(e) }.getOrDefault(false) }
        return live.isNotEmpty()
    }

    override fun onEvent(e: MotionEvent): GestureConsumer.Verdict {
        if (live.size == 1) return live[0].onEvent(e)
        for (c in live.toList()) {
            when (runCatching { c.onEvent(e) }.getOrDefault(GestureConsumer.Verdict.DROP)) {
                GestureConsumer.Verdict.TAKE -> {
                    live.filter { it !== c }.forEach(::cancel)
                    live.clear()
                    live += c
                    return GestureConsumer.Verdict.TAKE
                }
                GestureConsumer.Verdict.DROP -> live.remove(c)
                GestureConsumer.Verdict.FOLLOW -> {}
            }
        }
        return if (live.isEmpty()) GestureConsumer.Verdict.DROP else GestureConsumer.Verdict.FOLLOW
    }

    private fun cancel(c: GestureConsumer) {
        val now = android.os.SystemClock.uptimeMillis()
        val e = MotionEvent.obtain(now, now, MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
        runCatching { c.onEvent(e) }
        e.recycle()
    }
}
