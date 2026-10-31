package dev.omalauncher.system

/**
 * The last reading of something slow to read (binder calls: FreeformTasks' task list), for callers that mustn't wait
 * for one - the main thread mid-gesture (NavGesture.quickSwitch -> Tasks.open blocked 250 ms in getAllRootTaskInfos,
 * perf-1793456386286). [cached] never reads itself: it answers the last reading (null before the first) and, when
 * that is stale ([invalidate]: a task stack event), asks one fresh read on [post]'s thread. One read at a time; an
 * invalidation while one runs reads again after it, so the snapshot is never older than the last event + one read.
 */
class TaskSnapshot<T : Any>(
    private val read: () -> T,
    private val post: (Runnable) -> Unit,
) {
    @Volatile private var value: T? = null
    private val lock = Any()
    private var reading = false
    private var stale = true
    private var again = false

    /** The last reading, or null before the first; a stale one asks a fresh read (on [post]'s thread) and is still answered. */
    fun cached(): T? {
        if (synchronized(lock) { stale }) refresh()
        return value
    }

    /** Something changed (a task stack event): read again. */
    fun invalidate() {
        synchronized(lock) { stale = true }
        refresh()
    }

    /** A reading made elsewhere (off the main thread) that is at least as new: kept as the snapshot. */
    fun offer(v: T) {
        value = v
    }

    private fun refresh() {
        synchronized(lock) {
            if (reading) {
                again = true
                return
            }
            reading = true
            stale = false
        }
        post(Runnable { readNow() })
    }

    private fun readNow() {
        val v = runCatching(read).getOrNull()
        if (v != null) value = v
        val more =
            synchronized(lock) {
                reading = false
                if (v == null) stale = true
                again.also { again = false }
            }
        if (more) refresh()
    }
}
