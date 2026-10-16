package andro.marchy;

import java.io.BufferedReader;
import java.io.InputStreamReader;

/**
 * PowOS rooted mode: on a rooted phone (Magisk) PowOS runs as its own Linux system at /data/powos/root, installed and
 * flagged by targets/android/rooted/rooted.sh. This app then only provides what an Android app must: the screen
 * surface and the display daemon (buffers, touch, keyboard, audio relayed to KWin's Anland backend), and the phone's
 * state files in its run dir. The session itself is started as root (/data/powos/powos-session.sh) instead of
 * through the no-root engine (lotfix-run: patched loader + fakechroot + fakeroot), and the app needs no rootfs of its
 * own. Phones without root keep the no-root engine, unchanged.
 */
public final class RootMode {
    static final String SESSION = "/data/powos/powos-session.sh";

    private static Boolean cached;

    private RootMode() {
    }

    /**
     * The flag rooted.sh sets (persist.powos.root=1, with Magisk's resetprop). Read through getprop: no root prompt
     * and no blocking on the UI thread; the first `su` (the session start) asks Magisk for this app's grant.
     */
    public static synchronized boolean enabled() {
        if (cached == null) {
            cached = false;
            try {
                Process p = new ProcessBuilder("getprop", "persist.powos.root").redirectErrorStream(true).start();
                try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                    cached = "1".equals(r.readLine());
                }
                p.waitFor();
            } catch (Exception e) {
                Thread.currentThread().interrupt();
            }
        }
        return cached;
    }
}
