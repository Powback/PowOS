package andro.marchy;

/**
 * When the no-root session (SessionService) starts, waits or retries - pure, so the JVM tests cover it.
 *
 * The 11-04 emulator run: the session started while the base image was still being installed and never tried again
 * (splash stuck at "Starting D-Bus..." until a force-stop). Now: no start before the image is complete (rootfs in place
 * AND InstallActivity finished, packs included); a start whose D-Bus or compositor doesn't come up is ended and made
 * again after a growing pause, a few times, every state shown on the splash (SessionService.status).
 */
public final class SessionPlan {
    private SessionPlan() {}

    enum Action { WAIT_IMAGE, WAIT_SETUP, START, UP, RETRY, GIVE_UP }

    /** What a start that came up looks like so far. */
    enum Health { NOT_STARTED, STARTING, UP, FAILED }

    /** Tries before the session gives up (the splash then says so; reopening the app tries again). */
    static final int MAX_ATTEMPTS = 5;
    /** A start whose session bus and compositor socket aren't there by then has failed. */
    static final long START_TIMEOUT_MS = 90_000;

    static Action next(boolean rootMode, boolean imageReady, boolean installing, Health health, int attempts) {
        return next(rootMode, imageReady, installing, false, health, attempts);
    }

    /** setupPending: a setup step the first start waits for (SetupGate); a running session never waits for one. */
    static Action next(boolean rootMode, boolean imageReady, boolean installing, boolean setupPending, Health health,
            int attempts) {
        if (!rootMode && (!imageReady || installing))
            return Action.WAIT_IMAGE;
        if (!rootMode && setupPending && health == Health.NOT_STARTED)
            return Action.WAIT_SETUP;
        switch (health) {
            case UP:
                return Action.UP;
            case STARTING:
                return Action.UP; // still within its timeout: nothing to do yet
            case FAILED:
                return attempts >= MAX_ATTEMPTS ? Action.GIVE_UP : Action.RETRY;
            default:
                return Action.START;
        }
    }

    /** Pause before try number attempts+1: 5 s, 10 s, 20 s, 40 s, then 60 s. */
    static long retryDelayMs(int attempts) {
        return Math.min(60_000L, 5_000L << Math.max(0, Math.min(attempts - 1, 4)));
    }

    /**
     * The session's processes it can't work without (SessionService.spawn names): the session bus, the display
     * daemon, the system bus and the session itself (KWin + Plasma). One of them ending is a failed try, at once.
     */
    static final java.util.Set<String> CORE = java.util.Set.of("dbus", "andromarchy", "system-dbus", "hyprland");

    static Health health(boolean started, boolean busUp, boolean waylandUp, long sinceStartMs) {
        return health(started, busUp, waylandUp, sinceStartMs, null);
    }

    /**
     * A start is up once the session bus and the compositor's Wayland socket exist; failed past the timeout, or at
     * once when a CORE process ended (lostCore: its name) - the bus socket file outlives a killed dbus-daemon.
     */
    static Health health(boolean started, boolean busUp, boolean waylandUp, long sinceStartMs, String lostCore) {
        if (!started)
            return Health.NOT_STARTED;
        if (lostCore != null)
            return Health.FAILED;
        if (busUp && waylandUp)
            return Health.UP;
        return sinceStartMs >= START_TIMEOUT_MS ? Health.FAILED : Health.STARTING;
    }

    /** The splash's line for a state other than a normal start. */
    static String status(Action a, int attempts, long retryInMs) {
        switch (a) {
            case WAIT_IMAGE:
                return "Waiting for the PowOS image to finish installing...";
            case WAIT_SETUP:
                return "Finish the setup step, then the desktop starts...";
            case RETRY:
                return "The desktop didn't start (try " + attempts + " of " + MAX_ATTEMPTS + "), trying again in "
                        + (retryInMs / 1000) + " s...";
            case GIVE_UP:
                return "The desktop didn't start after " + attempts + " tries. Reopen PowOS to try again.";
            default:
                return null;
        }
    }

    /**
     * The session's [powos]-repo update (SessionService step 0b): upgrades only. The old command installed every
     * package of the repo with `-S --needed`, which DOWNGRADES whatever the repo has older: the stale repo's kwin
     * 6.7.5-3.3 replaced the base image's 3.31, built against an older libKScreenLocker - KWin then died at start
     * ("undefined symbol ScreenLocker::KSldApp::lock") and no Linux app found a display. -Su (without -uu) never
     * downgrades; packages the image doesn't have come with the packs (Packs), not with every session start.
     *
     * The image's own updater when it has one (lib/phone-update.sh, from the powos-core package: the same run as
     * `powos update` and the app's Settings, docs/PHONE-UPDATES.md). An image without it yet: this bootstrap - the
     * stale lock a killed pacman left removed (every later start failed "unable to lock database", razr 11-09), the
     * upgrade, then powos-core installed once over the files the base image put there unowned (--overwrite), which
     * brings the updater for every later start.
     */
    public static String packagesCommand() {
        return "C=/etc/pacman.d/powos-repo.conf; exec >\"$XDG_RUNTIME_DIR/powos-packages.log\" 2>&1;"
                + " U=/usr/lib/powos/phone-update.sh; [ -f $U ] && exec sh $U --session;"
                + " [ -e /var/lib/pacman/db.lck ] && ! pgrep -x pacman >/dev/null && rm -f /var/lib/pacman/db.lck;"
                + " sudo pacman --config $C -Syu --noconfirm;"
                + " pacman -Q powos-core >/dev/null 2>&1 || sudo pacman --config $C -S --noconfirm --overwrite '*' powos-core;"
                + " exit 0";
    }
}
