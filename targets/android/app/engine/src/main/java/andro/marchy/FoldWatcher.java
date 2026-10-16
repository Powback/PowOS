package andro.marchy;

import android.content.Context;
import android.content.SharedPreferences;
import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Display;

/**
 * PowOS on a foldable (OnePlus Open): opening the phone shows the PowOS desktop - with the running apps in its
 * taskbar - wherever the cover screen was (the launcher, an Android app). Folding it is left to Android (the cover
 * screen shows the home screen). Runs with the PowOS session (SessionService).
 *
 * Unfolding = the main display (id 0, which Android moves between the cover and the inner panel) going from
 * the cover panel to the inner one (its physical mode). (Android's
 * DeviceStateManager, which reports the hinge directly, is not in the public SDK.)
 *
 * A service may not bring an activity to the front by itself (Android's background-activity-launch rules), so in
 * rooted mode it asks `am start` through root; without root it does nothing (the desktop is one tap away).
 * Settings key {@link #KEY_UNFOLD_DESKTOP} (default on).
 */
final class FoldWatcher implements DisplayManager.DisplayListener {
    private static final String TAG = "FoldWatcher";
    static final String KEY_UNFOLD_DESKTOP = "unfold_opens_desktop";

    private final Context ctx;
    private DisplayManager dm;
    private android.os.HandlerThread thread;
    private Handler handler;
    private Boolean wasBig;

    FoldWatcher(Context ctx) {
        this.ctx = ctx.getApplicationContext();
    }

    void start() {
        if (!RootMode.enabled())
            return; // both the hinge state and the reaction need root
        dm = ctx.getSystemService(DisplayManager.class);
        if (dm == null)
            return;
        // Its own thread: every check asks su (not on the main thread).
        thread = new android.os.HandlerThread("FoldWatcher");
        thread.start();
        handler = new Handler(thread.getLooper());
        veil = new FoldVeil(ctx);
        handler.post(() -> {
            grantOverlay();
            onCover = coverScreen();
            wasBig = isBig();
            if (wasBig != null)
                folded = !wasBig;
            HomeScreen.apply(ctx, wasBig);
            Log.i(TAG, "watching the hinge (open=" + wasBig + ")");
        });
        dm.registerDisplayListener(this, handler);
        watchHinge();
    }

    private android.hardware.SensorManager sensors;
    private android.hardware.SensorEventListener hingeListener;
    private float lastAngle = -1;
    private FoldVeil veil;
    private android.os.HandlerThread hingeThread;

    /** The hinge angle (0 = shut, 180 = flat; -1 unknown), for MainActivity: the sensor is ahead of the configuration. */
    static volatile float hingeAngle = -1;

    /** Display 0 is on the cover screen (its physical panel, read through root - this app sees adjusted display info). */
    static volatile boolean onCover;

    /** Fully open / shut: no veil beyond these. */
    private static final float OPEN_REST = 165f, SHUT_REST = 3f;

    /**
     * Where the screens switch, ours (the device-state override below): Android alone switches to the cover only
     * once the phone is shut (measured: the cover lit ~0.2 s after the hinge read 0) - dark for most of a fold.
     * Closing below CLOSE_SWITCH, the cover takes over; opening past OPEN_SWITCH, the inner screen does.
     */
    private static final float CLOSE_SWITCH = 40f, OPEN_SWITCH = 35f;
    /** Only a deliberate fold (degrees per second) switches early: a phone held half open doesn't flip. */
    private static final float MIN_SPEED = 60f;
    /** An override never outlives this: a stuck one would keep the wrong screen on. */
    private static final long OVERRIDE_MAX_MS = 1500;

    private float speed, prevAngle = -1;
    private long prevTime;
    /** The device state we're holding (0 = CLOSED, 3 = OPENED), -1 none; since overrideAt. Hinge thread only. */
    private int override = -1;
    private long overrideAt;

    /** The hinge at [a] (hinge thread): the veil, and switching the screens early. */
    private void follow(float a, long nowMs) {
        if (prevAngle >= 0 && nowMs > prevTime) {
            float v = (a - prevAngle) * 1000f / (nowMs - prevTime);
            speed = speed * 0.5f + v * 0.5f;
        }
        prevAngle = a;
        prevTime = nowMs;
        steer(a, nowMs);
        // The veil peaks where the screen in use switches off; eased in, barely there while the hinge just moves.
        float p = onCover
            ? (a - SHUT_REST) / (OPEN_SWITCH - SHUT_REST)
            : (OPEN_REST - a) / (OPEN_REST - CLOSE_SWITCH);
        p = Math.max(0f, Math.min(1f, p));
        veil.set(p * p);
    }

    /** Switches the screens at our angles (device-state override), and lets go once the hinge is where it goes. */
    private void steer(float a, long nowMs) {
        if (override == -1) {
            if (!onCover && a < CLOSE_SWITCH && a > SHUT_REST && speed < -MIN_SPEED)
                hold(0, nowMs);
            else if (onCover && a > OPEN_SWITCH && a < OPEN_REST && speed > MIN_SPEED)
                hold(3, nowMs);
            return;
        }
        boolean done = override == 0
            ? a <= SHUT_REST || (a > CLOSE_SWITCH + 15 && speed > 0) // shut, or opened again
            : a >= OPEN_REST - 15 || (a < OPEN_SWITCH - 15 && speed < 0); // open, or closed again
        if (done || nowMs - overrideAt > OVERRIDE_MAX_MS)
            letGo();
    }

    private void hold(int state, long nowMs) {
        override = state;
        overrideAt = nowMs;
        Log.i(TAG, "switching early to " + (state == 0 ? "cover" : "inner") + " at hinge " + prevAngle + " (" + Math.round(speed) + "°/s)");
        overrideShell("cmd device_state state " + state);
    }

    private void letGo() {
        override = -1;
        overrideShell("cmd device_state state reset");
    }

    // The override's own root shell: the watcher thread's one can be busy with a dumpsys for ~0.2 s.
    private Process overrideSu;
    private java.io.Writer overrideIn;

    private void overrideShell(String cmd) {
        try {
            if (overrideSu == null || !overrideSu.isAlive()) {
                overrideSu = new ProcessBuilder("su").redirectErrorStream(true)
                    .redirectOutput(new java.io.File("/dev/null")).start();
                overrideIn = new java.io.OutputStreamWriter(overrideSu.getOutputStream());
            }
            overrideIn.write(cmd + "\n");
            overrideIn.flush();
        } catch (java.io.IOException e) {
            Log.w(TAG, "override: " + e);
            overrideSu = null;
        }
    }

    private void grantOverlay() {
        if (!android.provider.Settings.canDrawOverlays(ctx))
            root("appops set " + ctx.getPackageName() + " SYSTEM_ALERT_WINDOW allow");
    }

    /** Whether display 0 is the cover panel: the physical panel Android has it on, by its unique id. */
    private boolean coverScreen() {
        String out = root("dumpsys display | grep -m1 -o 'Display 0 \\[id=local:[0-9]*'");
        return out.contains(COVER_PANEL);
    }

    /** The OnePlus Open's cover panel (dumpsys display: local:<id>); the inner one is local:4630946704981769859. */
    private static final String COVER_PANEL = "local:4630946316123810436";

    /**
     * The hinge angle (0 = shut, 180 = flat), logged as it moves: the timings to make folding smooth - switch what
     * the cover shows before Android swaps the screens, fade instead of a cut - come from real folds.
     */
    private void watchHinge() {
        sensors = ctx.getSystemService(android.hardware.SensorManager.class);
        android.hardware.Sensor hinge = sensors == null ? null : sensors.getDefaultSensor(android.hardware.Sensor.TYPE_HINGE_ANGLE);
        if (hinge == null) {
            Log.i(TAG, "no hinge angle sensor");
            return;
        }
        hingeListener = new android.hardware.SensorEventListener() {
            @Override
            public void onSensorChanged(android.hardware.SensorEvent e) {
                float a = e.values[0];
                hingeAngle = a;
                if (Math.abs(a - lastAngle) < 1f)
                    return;
                lastAngle = a;
                Log.d(TAG, "hinge " + a + " t=" + e.timestamp / 1_000_000);
                if (enabled())
                    follow(a, e.timestamp / 1_000_000);
            }

            @Override
            public void onAccuracyChanged(android.hardware.Sensor s, int accuracy) {
            }
        };
        // Its own thread: the panel check on a display change (a root dumpsys, ~0.2 s) mustn't hold up the veil.
        hingeThread = new android.os.HandlerThread("FoldHinge");
        hingeThread.start();
        sensors.registerListener(hingeListener, hinge, android.hardware.SensorManager.SENSOR_DELAY_FASTEST, new Handler(hingeThread.getLooper()));
    }

    void stop() {
        if (dm != null)
            dm.unregisterDisplayListener(this);
        if (sensors != null && hingeListener != null)
            sensors.unregisterListener(hingeListener);
        if (hingeThread != null) {
            // Never leave the screens pinned.
            new Handler(hingeThread.getLooper()).post(() -> {
                if (override != -1)
                    letGo();
            });
            hingeThread.quitSafely();
        }
        if (thread != null)
            thread.quitSafely();
        if (shell != null)
            shell.destroy();
    }

    private Boolean isBig() {
        // The hinge state as Android commits it, through root (rooted mode only, as the reaction below). The app's
        // own view of display 0 (metrics, configuration, even its mode) didn't change through a fold: this app
        // targets SDK 28, and Android hands it compatibility-adjusted display info.
        String out = root("cmd device_state state");
        if (out.contains("name='OPENED'"))
            return true;
        if (out.contains("name='CLOSED'"))
            return false;
        return null; // in between (tent, half open) or unknown: no change
    }

    // One root shell for the whole session: a new `su` per command took long enough that, on unfold, the cover
    // screen's app showed on the inner screen before the desktop came up.
    private Process shell;
    private java.io.BufferedWriter shellIn;
    private java.io.BufferedReader shellOut;
    private static final String END = "__powos_fold_end__";

    /** Runs a command as root and returns its output (on this watcher's thread only). */
    private String root(String cmd) {
        try {
            if (shell == null || !shell.isAlive()) {
                shell = new ProcessBuilder("su").redirectErrorStream(true).start();
                shellIn = new java.io.BufferedWriter(new java.io.OutputStreamWriter(shell.getOutputStream()));
                shellOut = new java.io.BufferedReader(new java.io.InputStreamReader(shell.getInputStream()));
            }
            shellIn.write(cmd + "; echo " + END + "\n");
            shellIn.flush();
            StringBuilder out = new StringBuilder();
            for (String line; (line = shellOut.readLine()) != null && !line.equals(END); )
                out.append(line).append('\n');
            return out.toString();
        } catch (java.io.IOException e) {
            Log.w(TAG, "root shell: " + e);
            shell = null;
            return "";
        }
    }

    @Override
    public void onDisplayChanged(int displayId) {
        if (displayId != Display.DEFAULT_DISPLAY)
            return;
        boolean cover = coverScreen();
        if (cover != onCover) {
            onCover = cover;
            switched(cover);
        }
        check();
        handler.postDelayed(this::check, 500); // the hinge state can commit just after the display changes
    }

    /** The hinge, as last read: true = folded (closed). For MainActivity: a phone-sized window alone doesn't mean
     *  folded - half the inner screen in split view is phone-sized too. */
    static volatile boolean folded;

    private void check() {
        Boolean big = isBig();
        if (big != null)
            folded = !big;
        Log.d(TAG, "display 0 changed: big=" + big + " was=" + wasBig);
        if (big == null || big.equals(wasBig))
            return;
        Log.i(TAG, (big ? "unfolded" : "folded") + " at hinge " + lastAngle + " t=" + android.os.SystemClock.elapsedRealtimeNanos() / 1_000_000);
        HomeScreen.apply(ctx, big); // auto: desktop on the inner screen, launcher on the cover
        if (big && Boolean.FALSE.equals(wasBig))
            unfolded();
        else if (!big && Boolean.TRUE.equals(wasBig))
            folded();
        wasBig = big;
    }

    /**
     * Android moved display 0 to the other screen: it starts under the full veil, which clears once what it shows
     * is in place (check(): the launcher, the carried app, the desktop).
     */
    private void switched(boolean toCover) {
        Log.i(TAG, "screen switch to " + (toCover ? "cover" : "inner") + " at hinge " + lastAngle);
        if (enabled())
            veil.cover(350);
    }

    /** The Android app taken onto the cover screen at the last fold: its task and the PowOS window's display. */
    private String[] carried;

    /**
     * Folded: the Android app focused in PowOS (a PowOS window = a virtual display; powos-android-tasks writes which,
     * run dir file android-active) comes onto the cover screen, so the cover shows what was being used - not the
     * empty phone screen under the desktop (which steps aside, MainActivity.onConfigurationChanged). A PowOS (Linux)
     * app in use: the desktop comes onto the cover with it (desktopAppActive). Neither: the cover shows the launcher.
     */
    private void folded() {
        if (!enabled())
            return;
        carried = null;
        try {
            String[] a = new String(java.nio.file.Files.readAllBytes(
                    new java.io.File(SessionService.runDir(ctx), "android-active").toPath())).trim().split(" ");
            if (a.length == 2 && !a[0].isEmpty()) {
                su("am display move-stack " + a[0] + " 0");
                carried = a;
                Log.i(TAG, "carried task " + a[0] + " from display " + a[1] + " onto the cover screen");
            }
        } catch (java.io.IOException e) {
            Log.d(TAG, "nothing to carry: " + e);
        }
        if (carried == null && !desktopAppActive(ctx)) {
            // The launcher (HomeScreen.apply made it home for the cover screen), not whatever was below the desktop.
            su("am start --display 0 -a android.intent.action.MAIN -c android.intent.category.HOME");
            Log.i(TAG, "nothing in use: the launcher on the cover screen");
        }
    }

    /** A PowOS (Linux) app is what's in use (powos-android-tasks, run dir file desktop-active). */
    static boolean desktopAppActive(Context ctx) {
        try {
            return "1".equals(new String(java.nio.file.Files.readAllBytes(
                    new java.io.File(SessionService.runDir(ctx), "desktop-active").toPath())).trim());
        } catch (java.io.IOException e) {
            return false;
        }
    }

    private boolean enabled() {
        SharedPreferences prefs = ctx.getSharedPreferences("andromarchy_settings", Context.MODE_PRIVATE);
        return prefs.getBoolean(KEY_UNFOLD_DESKTOP, true) && RootMode.enabled();
    }

    private void su(String cmd) {
        root(cmd);
    }

    @Override
    public void onDisplayAdded(int displayId) {
    }

    @Override
    public void onDisplayRemoved(int displayId) {
    }

    /**
     * Unfolded: the desktop first (Android shows the cover screen's app on the inner screen until then), then the
     * app carried onto the cover goes back into its PowOS window behind it.
     */
    private void unfolded() {
        if (!enabled())
            return;
        su("am start --display 0 -n " + ctx.getPackageName() + "/" + MainActivity.class.getName());
        if (carried != null) {
            su("am display move-stack " + carried[0] + " " + carried[1]); // fails harmlessly if the window closed
            carried = null;
        }
    }
}
