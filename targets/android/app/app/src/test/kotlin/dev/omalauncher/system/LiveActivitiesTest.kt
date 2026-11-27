package dev.omalauncher.system

import dev.omalauncher.system.LiveActivities.Clock
import dev.omalauncher.system.LiveActivities.Item
import dev.omalauncher.system.LiveActivities.Progress
import dev.omalauncher.system.LiveActivities.Signals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Which ongoing notifications become live activities round the camera ring, and in what order (LiveActivities.kt). */
class LiveActivitiesTest {
    private fun item(key: String, s: Signals, title: String? = "t") = Item(key, "pkg", null, title, null, s)

    @Test fun kinds() {
        assertEquals("media", LiveActivities.kind(item("m", Signals(ongoing = false, playing = true))))
        assertNull(LiveActivities.kind(item("paused", Signals(ongoing = true, playing = false, clock = Clock(1, false)))))
        assertEquals("call", LiveActivities.kind(item("c", Signals(ongoing = true, category = "call", clock = Clock(1, false)))))
        assertEquals("timer", LiveActivities.kind(item("t", Signals(ongoing = true, clock = Clock(1, true)))))
        assertEquals("progress", LiveActivities.kind(item("p", Signals(ongoing = true, progress = Progress(3, 10, false)))))
        assertEquals("progress", LiveActivities.kind(item("i", Signals(ongoing = true, progress = Progress(0, 0, true)))))
        assertEquals("live", LiveActivities.kind(item("l", Signals(ongoing = true, promoted = true))))
    }

    @Test fun notLive() {
        // A plain ongoing one (a VPN, the launcher's own service), a finished download, a dismissable timer.
        assertNull(LiveActivities.kind(item("vpn", Signals(ongoing = true))))
        assertNull(LiveActivities.kind(item("done", Signals(ongoing = true, progress = Progress(10, 10, false)))))
        assertNull(LiveActivities.kind(item("old", Signals(ongoing = false, clock = Clock(1, false)))))
        assertNull(LiveActivities.kind(item("untitled", Signals(ongoing = true, promoted = true), title = null)))
    }

    @Test fun callFirstMediaLast() {
        val picked =
            LiveActivities.pick(
                listOf(
                    item("music", Signals(ongoing = true, playing = true)),
                    item("dl", Signals(ongoing = true, progress = Progress(1, 2, false))),
                    item("vpn", Signals(ongoing = true)),
                    item("timer", Signals(ongoing = true, clock = Clock(5, true))),
                    item("call", Signals(ongoing = true, category = "call")),
                    item("dl2", Signals(ongoing = true, progress = Progress(0, 0, true))),
                ),
            )
        assertEquals(listOf("call", "timer", "dl", "dl2", "music"), picked.map { it.key })
        assertEquals("progress", picked[2].kind)
    }
}
