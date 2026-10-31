package dev.omalauncher.system

/**
 * Apps launched full screen on purpose (a dock tap, DB1 - Tasks.fullScreenOptions): WindowFrames' adopt must leave
 * their new task full screen. It floated every new full-screen task of display 0 into a web window ~300 ms after it
 * showed - the user, 10-31 15:16: "When I open Android apps, they show immediately in full screen and then they show
 * desktop mode" (logcat: dockTap -> "task 2663 (com.android.chrome) was full screen: now a web window"). Pure; [now]
 * is uptime ms so the JVM tests drive it.
 */
internal object FullScreenLaunch {
    /** How long after its launch a task of the app counts as the full-screen launch's (a cold start's task shows late). */
    const val CLAIM_MS = 10_000L

    private val launched = HashMap<String, Long>()

    @Synchronized
    fun mark(
        pkg: String,
        now: Long,
    ) {
        launched[pkg] = now
    }

    /** [pkg]'s full-screen task showed at [now]: true (once) when it is a full-screen launch's - leave it full screen. */
    @Synchronized
    fun claim(
        pkg: String,
        now: Long,
    ): Boolean {
        val at = launched.remove(pkg) ?: return false
        return now - at in 0..CLAIM_MS
    }
}
