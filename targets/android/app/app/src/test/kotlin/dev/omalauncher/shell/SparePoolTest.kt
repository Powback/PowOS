package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The display helper's pool of one ([SparePool]): made ahead, refilled after a take, resized, dropped when off. */
class SparePoolTest {
    private val made = mutableListOf<String>()
    private val dropped = mutableListOf<String>()
    private val resized = mutableListOf<String>()
    private val queue = ArrayDeque<() -> Unit>()
    private var n = 0
    private var duringMake: (() -> Unit)? = null

    private val pool: SparePool<String> =
        SparePool(
            make = { w, h, dpi -> duringMake?.invoke(); "d${++n}@${w}x$h/$dpi".also { made += it } },
            resize = { v, w, h, dpi -> resized += "$v->${w}x$h/$dpi" },
            drop = { dropped += it },
            post = { queue.addLast(it) },
        )

    private fun run() {
        while (queue.isNotEmpty()) queue.removeFirst()()
    }

    @Test
    fun nothingIsMadeUntilASizeIsSet() {
        assertNull(pool.take())
        run()
        assertTrue(made.isEmpty())
    }

    @Test
    fun aSizeFillsItAndATakeRefills() {
        pool.size(2268, 2440, 442)
        run()
        assertEquals(listOf("d1@2268x2440/442"), made)
        assertEquals("d1@2268x2440/442", pool.take())
        assertFalse(pool.ready)
        run()
        assertEquals("d2@2268x2440/442", pool.take())
    }

    @Test
    fun aTakeOnAnEmptyPoolIsColdAndStillRefills() {
        pool.size(10, 20, 300)
        assertNull(pool.take()) // nothing made yet: the caller makes its own
        run()
        assertEquals(1, made.size)
        assertTrue(pool.ready)
    }

    @Test
    fun aNewScreenSizeResizesTheSpareInPlace() {
        pool.size(2268, 2440, 442)
        run()
        pool.size(2440, 2268, 442) // rotated
        run()
        assertEquals(listOf("d1@2268x2440/442->2440x2268/442"), resized)
        assertEquals(1, made.size)
        assertTrue(pool.ready)
        pool.size(2440, 2268, 442) // the same again: nothing to do
        run()
        assertEquals(1, resized.size)
    }

    @Test
    fun offDropsTheSpareAndStopsRefilling() {
        pool.size(10, 20, 300)
        run()
        pool.off()
        run()
        assertEquals(listOf("d1@10x20/300"), dropped)
        assertNull(pool.take())
        run()
        assertEquals(1, made.size)
    }

    @Test
    fun aSpareMadeWhileTurningOffIsNotKept() {
        duringMake = { pool.off() } // web windows turned off while the display is being made
        pool.size(10, 20, 300)
        run()
        assertFalse(pool.ready)
        assertEquals(listOf("d1@10x20/300"), dropped)
    }

    /**
     * window-bench's leak count (WW_LAYERS) counts the pool's displays by name with the windows' - a taken spare keeps
     * its "powos-ww-spare-<n>" name - and relies on this: however many windows a storm opens on pool hits, once the
     * pool has refilled exactly one display is untaken, so every other live display is a window's.
     */
    @Test
    fun aStormKeepsExactlyOneUntakenSpare() {
        pool.size(2268, 2440, 442)
        run()
        val taken = mutableListOf<String>()
        repeat(20) {
            taken += pool.take()!!
            if (it % 2 == 0) taken += listOfNotNull(pool.take()) // a second open before the refill: a cold one
            run()
        }
        val live = made.filterNot { it in dropped }
        assertEquals(20, taken.size)
        assertEquals(21, live.size)
        assertEquals(1, live.filterNot { it in taken }.size)
        assertTrue(pool.ready)
    }

    @Test
    fun releaseAllDropsWhatIsHeld() {
        pool.size(10, 20, 300)
        run()
        pool.releaseAll()
        assertEquals(listOf("d1@10x20/300"), dropped)
        assertFalse(pool.ready)
    }
}
