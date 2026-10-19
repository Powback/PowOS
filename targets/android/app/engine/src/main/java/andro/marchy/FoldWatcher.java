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
        handler.post(() -> {
            wasBig = isBig();
            if (wasBig != null)
                folded = !wasBig;
            preferHome(HomeScreen.apply(ctx, wasBig));
            Log.i(TAG, "watching the hinge (open=" + wasBig + ")");
        });
        dm.registerDisplayListener(this, handler);
    }

    void stop() {
        if (dm != null)
            dm.unregisterDisplayListener(this);
        if (thread != null)
            thread.quitSafely();
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

    // One root shell (RootShell, the app's): a new `su` per command took long enough that, on unfold, the cover
    // screen's app showed on the inner screen before the desktop came up.
    /**
     * The enabled home alias as Android's default home: switching aliases drops the remembered choice, and Home
     * (or a fold) then asked "open with" PowOS or OnePlus's launcher every time, "always" or not.
     */
    private void preferHome(String component) {
        if (component.equals(preferredHome))
            return;
        root("cmd package set-home-activity --user 0 " + component);
        preferredHome = component;
        Log.i(TAG, "default home: " + component);
    }

    private String preferredHome;

    /** [cmd] as root, its output: through the app's one root shell, shared with everything else (RootShell). */
    private String root(String cmd) {
        return RootShell.run(cmd).output + "\n";
    }

    @Override
    public void onDisplayChanged(int displayId) {
        if (displayId != Display.DEFAULT_DISPLAY)
            return;
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
        Log.i(TAG, big ? "unfolded" : "folded");
        preferHome(HomeScreen.apply(ctx, big)); // auto: desktop on the inner screen, launcher on the cover
        if (big && Boolean.FALSE.equals(wasBig))
            unfolded();
        else if (!big && Boolean.TRUE.equals(wasBig))
            folded();
        wasBig = big;
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
            // A HOME intent with our alias as its component: without one Android asked which home app (ours or
            // OnePlus's) every time - the home alias switches with the fold, so "remember" never stuck; without HOME
            // it was a second launcher beside the home one.
            su("am start --display 0 " + HomeScreen.launcherStart(ctx));
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
        // The home alias when it is the desktop: the same activity instance Home opens. By class name it was a
        // second instance of the desktop beside the home one, and the two fought over the one connection.
        android.content.ComponentName home = new android.content.ComponentName(ctx, "andro.marchy.HomeDesktop");
        boolean homeIsDesktop = ctx.getPackageManager().getComponentEnabledSetting(home)
            == android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED;
        su("am start --display 0 -n " + ctx.getPackageName() + "/"
            + (homeIsDesktop ? "andro.marchy.HomeDesktop" : MainActivity.class.getName()));
        if (carried != null) {
            su("am display move-stack " + carried[0] + " " + carried[1]); // fails harmlessly if the window closed
            carried = null;
        }
    }
}
