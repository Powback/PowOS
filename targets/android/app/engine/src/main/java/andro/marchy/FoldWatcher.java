package andro.marchy;

import android.content.Context;
import android.content.SharedPreferences;
import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Display;

/**
 * PowOS on a foldable (OnePlus Open): keeps Android's default home on the alias HomeScreen picks for the hinge. With
 * Plasma's desktop as home (the "desktop" setting) opening the phone also shows that desktop - with the running apps
 * in its taskbar - wherever the cover screen was; with the web home (auto, launcher) fold and unfold are Android's
 * own (the app in front stays in front). Runs with the PowOS session (SessionService).
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
    /**
     * Desktop mode (docs/DESKTOP-KWIN-NATIVE.md phase 1): Settings.Global {@code powos_desktop_mode} = 1. Unfolded,
     * KWin's desktop (HomeDesktop, the Plasma app) is the home, full screen, and KWin exports no window as an Android
     * task for the whole mode ("desktop 1" + "export-new 0", WindowTasks); folded, the phone home (the PowOS shell)
     * and the frozen session as before. 0 (the default) = exactly the behaviour without it.
     * Set with `settings put global powos_desktop_mode 1`; watched live.
     */
    static final String DESKTOP_MODE = "powos_desktop_mode";
    /** The setting, as last read (rooted mode only: the fold reaction needs root). */
    private static volatile boolean desktopMode;
    /** When the last unfold in desktop mode was seen (uptime ms; 0 = none pending): MainActivity logs the time to its first frame. */
    static volatile long unfoldAt;

    /** Desktop mode is on (the setting, rooted). */
    static boolean desktopMode() {
        return desktopMode;
    }

    /** Desktop mode is on and the phone is open: KWin's desktop is the home and holds every Linux window. */
    static boolean desktopModeActive() {
        return desktopMode && !folded;
    }

    private void readDesktopMode() {
        boolean on = RootMode.enabled()
            && android.provider.Settings.Global.getInt(ctx.getContentResolver(), DESKTOP_MODE, 0) == 1;
        if (on != desktopMode)
            Log.i(TAG, "desktop mode " + (on ? "on" : "off"));
        desktopMode = on;
        WindowTasks.modeChanged(ctx);
        // The session's own side (powos-shell's roles, Plasma's panels, Meta): the session start read the setting
        // (powos-session.sh); a change while it runs goes there too, once it settles (a toggle flipped twice = none).
        if (!modeRead) {
            modeRead = true;
            shellApplied = on;
            return;
        }
        handler.removeCallbacks(applyShell);
        handler.postDelayed(applyShell, SHELL_DEBOUNCE_MS);
    }

    /** The first read is the session's own (powos-session.sh applied it at start); later ones are changes. */
    private boolean modeRead;
    /** The mode the session was last told ("powos-desktop-shell desktop on|off"). */
    private boolean shellApplied;
    private static final long SHELL_DEBOUNCE_MS = 400;
    private final Runnable applyShell = () -> {
        boolean on = desktopMode;
        if (on == shellApplied)
            return;
        java.util.function.Consumer<Boolean> hook = WindowTasks.desktopShellHook;
        if (hook == null) {
            Log.w(TAG, "desktop mode " + (on ? "on" : "off") + ": no session hook, the session keeps its mode");
            return;
        }
        shellApplied = on;
        hook.accept(on);
    };

    private android.database.ContentObserver modeObserver;

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
            readDesktopMode();
            preferHome(HomeScreen.apply(ctx, wasBig));
            Log.i(TAG, "watching the hinge (open=" + wasBig + ", desktop mode=" + desktopMode + ")");
        });
        dm.registerDisplayListener(this, handler);
        modeObserver = new android.database.ContentObserver(handler) {
            @Override
            public void onChange(boolean selfChange) {
                readDesktopMode();
                preferHome(HomeScreen.apply(ctx, wasBig));
            }
        };
        ctx.getContentResolver().registerContentObserver(
            android.provider.Settings.Global.getUriFor(DESKTOP_MODE), false, modeObserver);
    }

    void stop() {
        if (dm != null)
            dm.unregisterDisplayListener(this);
        if (modeObserver != null)
            ctx.getContentResolver().unregisterContentObserver(modeObserver);
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
        // Desktop mode, unfolding: the desktop first - before the default-home switch below (a root round trip) - so
        // unfold is a thaw plus one frame (its surface kept its inner size through the fold, MainActivity.onCoverScreen).
        if (desktopMode && big && Boolean.FALSE.equals(wasBig)) {
            unfoldAt = android.os.SystemClock.uptimeMillis();
            startDesktop();
        }
        WindowTasks.modeChanged(ctx); // "desktop"/"export-new" follow the hinge in desktop mode
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
        // The web home (auto, launcher): Android's own fold - the app in front stays in front on the cover screen.
        if (!desktopMode && (!enabled() || !HomeScreen.desktopIsHome()))
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
        // Desktop mode: folded is always the phone home (the desktop steps aside even with a Linux app in use).
        if (carried == null && (desktopMode || !desktopAppActive(ctx))) {
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
        if (desktopMode) {
            // The desktop is up already (check, startDesktop); only the carried app goes back to its window.
            if (carried != null) {
                su("am display move-stack " + carried[0] + " " + carried[1]);
                carried = null;
            }
            return;
        }
        // The web home is the desktop unfolded: nothing to bring up (a HomeDesktop started over it fought it).
        if (!enabled() || !HomeScreen.desktopIsHome())
            return;
        // The home alias when it is the desktop: the same activity instance Home opens. By class name it was a
        // second instance of the desktop beside the home one, and the two fought over the one connection.
        // (Rooted, both aliases stay enabled - HomeScreen: which one is home is the one it made the default.)
        su("am start --display 0 -n " + ctx.getPackageName() + "/andro.marchy.HomeDesktop");
        if (carried != null) {
            su("am display move-stack " + carried[0] + " " + carried[1]); // fails harmlessly if the window closed
            carried = null;
        }
    }

    /**
     * Desktop mode's unfold: HomeDesktop (the same instance Home opens, see unfolded) started from the app's own
     * process - no `su am start` round trip. The app may start activities from the background while it holds "display
     * over other apps" (SYSTEM_ALERT_WINDOW); should Android refuse anyway (it does so silently), root starts it once
     * the desktop isn't on screen 400 ms later.
     */
    private void startDesktop() {
        long t0 = android.os.SystemClock.uptimeMillis();
        try {
            android.content.Intent i = new android.content.Intent()
                .setComponent(new android.content.ComponentName(ctx.getPackageName(), "andro.marchy.HomeDesktop"))
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
            android.app.ActivityOptions o = android.app.ActivityOptions.makeBasic().setLaunchDisplayId(Display.DEFAULT_DISPLAY);
            ctx.startActivity(i, o.toBundle());
            Log.i(TAG, "desktop mode: unfold started the desktop in-process (" + (android.os.SystemClock.uptimeMillis() - t0) + " ms)");
        } catch (RuntimeException e) {
            Log.w(TAG, "desktop mode: in-process start refused: " + e);
        }
        handler.postDelayed(() -> {
            if (!folded && !WindowTasks.desktopOnScreen()) {
                Log.w(TAG, "desktop mode: the desktop is not up 400 ms after unfold, starting it as root");
                su("am start --display 0 -n " + ctx.getPackageName() + "/andro.marchy.HomeDesktop");
            }
        }, 400);
    }
}
