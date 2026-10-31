package dev.omalauncher.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** FreeformTasks.cached's snapshot: the caller's thread never reads (the binder calls), only the posted reader does. */
class TaskSnapshotTest {
    private var reads = 0
    private val posted = ArrayDeque<Runnable>()
    private val snap = TaskSnapshot({ ++reads }, { posted.addLast(it) })

    private fun drain() {
        while (posted.isNotEmpty()) posted.removeFirst().run()
    }

    @Test fun cachedNeverReadsOnTheCallersThread() {
        assertNull(snap.cached())
        assertEquals("the read is posted, not run inline", 0, reads)
        drain()
        assertEquals(1, snap.cached())
        assertEquals(1, snap.cached())
        assertEquals("a fresh snapshot is answered without reading", 1, reads)
        assertEquals(0, posted.size)
    }

    @Test fun anEventReadsAgainOffThread() {
        snap.cached()
        drain()
        snap.invalidate()
        assertEquals("stale value still answered at once", 1, snap.cached())
        assertEquals(1, reads)
        drain()
        assertEquals(2, snap.cached())
    }

    @Test fun eventsDuringAReadCoalesceIntoOneMore() {
        snap.cached()
        snap.invalidate()
        snap.invalidate()
        assertEquals("one read at a time", 1, posted.size)
        drain()
        assertEquals("the read in flight + one for the events after it", 2, reads)
    }

    @Test fun anOfferedReadingIsKept() {
        snap.offer(41)
        snap.cached()
        drain()
        snap.offer(99)
        assertEquals(99, snap.cached())
    }
}
