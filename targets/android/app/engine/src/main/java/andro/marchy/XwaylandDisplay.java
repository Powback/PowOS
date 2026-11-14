package andro.marchy;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * The desktop's X server (KWin's Xwayland) for programs the app starts in the no-root session: DISPLAY and XAUTHORITY,
 * as the desktop's own apps get them from KWin. Read from KWin's command line (it starts Xwayland itself:
 * --xwayland-display, --xwayland-xauthority; a new auth file each session start), the same source rooted mode's
 * powos-run.sh uses. Without it every X11 program the launcher opened had no display: Steam's updater window
 * ("XOpenDisplay failed", "Check your DISPLAY environment variable", razr fold 11-14) and its client never showed.
 * Pure apart from {@link #find()}, so the JVM tests cover it.
 */
final class XwaylandDisplay {
    private XwaylandDisplay() {}

    /** DISPLAY + XAUTHORITY from one process's /proc/<pid>/cmdline (NUL-separated); empty unless it is KWin's. */
    static Map<String, String> fromKwinCmdline(byte[] cmdline) {
        Map<String, String> env = new HashMap<>();
        String[] args = new String(cmdline, StandardCharsets.UTF_8).split("\0");
        // KWin runs through the engine's loader: argv[0] is ld-linux-*.so.1, the program one of the next arguments.
        boolean kwin = false;
        for (int i = 0; i < Math.min(args.length, 3) && !kwin; i++)
            kwin = args[i].equals("kwin_wayland") || args[i].endsWith("/kwin_wayland");
        if (!kwin)
            return env;
        for (int i = 0; i + 1 < args.length; i++) {
            if (args[i].equals("--xwayland-display") && !args[i + 1].isEmpty())
                env.put("DISPLAY", args[i + 1]);
            else if (args[i].equals("--xwayland-xauthority") && !args[i + 1].isEmpty())
                env.put("XAUTHORITY", args[i + 1]);
        }
        if (!env.containsKey("DISPLAY"))
            env.clear(); // an auth file without a display is no use
        return env;
    }

    /** The KWin pid found last: every widget command starts a guest process, so the /proc scan runs once per KWin. */
    private static volatile String lastPid;

    /** The running KWin's X display in [proc] (a /proc), or empty: no session, or KWin without Xwayland. */
    static Map<String, String> find(File proc) {
        String last = lastPid;
        if (last != null) {
            try {
                Map<String, String> env = fromKwinCmdline(java.nio.file.Files.readAllBytes(new File(proc, last + "/cmdline").toPath()));
                if (!env.isEmpty())
                    return env;
            } catch (Exception e) {
                // that KWin is gone (a session restart): scan again
            }
        }
        File[] procs = proc.listFiles((d, n) -> !n.isEmpty() && n.chars().allMatch(Character::isDigit));
        if (procs != null) {
            for (File p : procs) {
                try {
                    Map<String, String> env = fromKwinCmdline(java.nio.file.Files.readAllBytes(new File(p, "cmdline").toPath()));
                    if (!env.isEmpty()) {
                        lastPid = p.getName();
                        return env;
                    }
                } catch (Exception e) {
                    // gone meanwhile, or not ours
                }
            }
        }
        return new HashMap<>();
    }

    static Map<String, String> find() {
        return find(new File("/proc"));
    }
}
