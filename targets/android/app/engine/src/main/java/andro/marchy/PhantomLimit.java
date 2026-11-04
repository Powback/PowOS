package andro.marchy;

/**
 * Android 12+'s limit on an app's child processes ("phantom processes") - pure, so the JVM tests cover it.
 *
 * The no-root session runs every Linux program as a child process of this app. Android 12 and later stop the app's
 * child processes past 32 (activity_manager max_phantom_processes) and ones using a lot of CPU in the background: KWin
 * and the session bus were killed (SIGKILL, signal 9) the moment Plasma started, so the desktop came and went. A
 * non-rooted phone can't change that itself; the owner turns it off once:
 * - Android 14+: Developer options > "Disable child process restrictions" (writes the global setting below);
 * - Android 12L/13: no switch in Settings; the adb commands below (12L+ also honour the global setting);
 * - Android 12 (API 31): only the device_config command (the global setting came with 12L).
 * The app detects it (a session process ended by SIGKILL that the app didn't end; the guest's process count against
 * the limit) and shows that one setup step (ChildProcessSetupActivity).
 */
final class PhantomLimit {
    private PhantomLimit() {}

    /** Android's default max_phantom_processes. */
    static final int ANDROID_LIMIT = 32;
    /** Global setting the Developer options switch (and the 12L/13 adb command) writes; "false" = restrictions off. */
    static final String MONITOR_SETTING = "settings_enable_monitor_phantom_procs";

    /** What the owner has to do once, if anything. */
    enum Fix { NONE, DEVELOPER_OPTIONS, ADB }

    /** The one adb command for Android 12 (API 31): the limit itself. */
    static final String ADB_LIMIT = "adb shell device_config put activity_manager max_phantom_processes 2147483647";
    /** Android 12L/13: the same switch Developer options has on 14+. */
    static final String ADB_MONITOR = "adb shell settings put global " + MONITOR_SETTING + " false";

    /**
     * The fix this phone needs: none before Android 12 (no limit) or when the restrictions are already off
     * (monitorSetting "false"); else the Developer options switch on 14+, the adb command(s) on 12-13.
     */
    static Fix fix(int sdk, String monitorSetting) {
        if (sdk < 31 || "false".equalsIgnoreCase(monitorSetting))
            return Fix.NONE;
        return sdk >= 34 ? Fix.DEVELOPER_OPTIONS : Fix.ADB;
    }

    /** The adb commands to copy (ADB fix): the limit, plus the global switch where it exists (12L+). */
    static String adbCommands(int sdk) {
        return sdk >= 32 ? ADB_LIMIT + "\n" + ADB_MONITOR : ADB_LIMIT;
    }

    /**
     * A session process's end that looks like Android's limit: killed by SIGKILL (Java's exit value 128 + 9), while
     * the app wasn't ending the session itself (endSession/onDestroy destroy their own processes with SIGKILL too).
     */
    static boolean killedByAndroid(int exitValue, boolean appEnding) {
        return exitValue == 128 + 9 && !appEnding;
    }

    /** The guest has as many child processes as Android allows, or more: the next ones (or older ones) get killed. */
    static boolean atLimit(int guestProcesses) {
        return guestProcesses >= ANDROID_LIMIT;
    }

    /** The setup step's text. */
    static String message(Fix fix, int sdk, int guestProcesses, boolean killed) {
        String android = sdk >= 34 ? "14+" : sdk >= 33 ? "13" : "12";
        String why = (killed ? "Android stopped part of the PowOS desktop" : "The PowOS desktop runs "
                + guestProcesses + " Linux processes") + ": Android " + android + " stops an app's child processes"
                + " past " + ANDROID_LIMIT + ", so Linux apps and the desktop can close by themselves. Turn this limit"
                + " off once:";
        switch (fix) {
            case DEVELOPER_OPTIONS:
                return why + "\n\nSettings > System > Developer options > \"Disable child process restrictions\": on."
                        + "\n\n(No Developer options? Settings > About phone > tap \"Build number\" 7 times.)";
            case ADB:
                return why + "\n\nFrom a computer with adb (USB debugging on), run:";
            default:
                return why;
        }
    }
}
