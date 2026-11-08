package andro.marchy;

/**
 * Setup steps the no-root session waits for before its FIRST start (SessionPlan.Action.WAIT_SETUP) - pure apart from
 * the clock the caller passes, so the JVM tests cover it.
 *
 * 11-09 razr (Android 16, no root): the session started while the storage permission dialog was up. The grant made
 * Android re-evaluate the app's processes, and its child process limit ("Trimming phantom processes", 32) killed the
 * session's first processes - D-Bus and the display daemon - one second in: a blank desktop on the very first start.
 * Now MainActivity asks for what the session needs (the child process setup step, shared storage) first, and the
 * session starts once those are answered. Each step expires (the activity may go away without an answer), so the
 * session never waits for good.
 */
final class SetupGate {
    private SetupGate() {}

    /** The longest the session waits for one step. */
    static final long MAX_WAIT_MS = 120_000;

    private static final java.util.Map<String, Long> steps = new java.util.HashMap<>();

    /** A step the session waits for, from now (uptime ms). */
    static synchronized void begin(String step, long now) {
        steps.put(step, now + MAX_WAIT_MS);
    }

    /** The step is answered. */
    static synchronized void end(String step) {
        steps.remove(step);
    }

    static synchronized boolean waiting(String step, long now) {
        Long until = steps.get(step);
        return until != null && now < until;
    }

    /** Any step still open (expired ones dropped). */
    static synchronized boolean pending(long now) {
        steps.values().removeIf(until -> now >= until);
        return !steps.isEmpty();
    }

    static synchronized void clear() {
        steps.clear();
    }
}
