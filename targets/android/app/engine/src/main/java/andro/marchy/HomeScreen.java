package andro.marchy;

import android.content.ComponentName;
import android.content.Context;
import android.content.pm.PackageManager;
import android.util.Log;

/**
 * PowOS: what Android's Home opens - the PowOS desktop (KDE Plasma) or the PowOS launcher (the web shell: apps,
 * widgets; shell/). Two HOME aliases (.HomeDesktop in the engine's manifest, .HomeShell in the app's); exactly one is
 * enabled, so Home opens it directly. (A trampoline activity picking one per press showed the wallpaper first and
 * cost half a second.)
 *   auto      the launcher on both screens: unfolded it is the PowOS desktop (wide home, apps in floating windows;
 *             docs/DESKTOP-WEB-SHELL.md, 2026-10-22). It made Plasma's desktop home on the inner screen before: each
 *             unfold then put HomeDesktop over the web home and Android's recents (the default home's task) and PowOS's
 *             Home (the web home) fought - home flipped between the two per gesture (2026-10-23 23:48).
 *   desktop   always the desktop (Plasma's)
 *   launcher  always the launcher
 * Chosen in Settings (Home screen), {@link #KEY_HOME_SCREEN} in the engine's preferences.
 */
final class HomeScreen {
    private static final String TAG = "HomeScreen";
    static final String KEY_HOME_SCREEN = "home_screen";
    static final String[] HOME_SCREENS = {"auto", "desktop", "launcher"};
    /** The launcher's HOME alias (app module's manifest, on dev.omalauncher.shell.ShellActivity). */
    private static final String LAUNCHER = "HomeShell";
    private HomeScreen() {
    }

    /** The alias last made home ("HomeDesktop" or "HomeShell"; null before the first apply). */
    static volatile String current;

    /** Plasma's desktop is Android's home now (the "desktop" setting): fold and unfold move it (FoldWatcher). */
    static boolean desktopIsHome() {
        return "HomeDesktop".equals(current);
    }

    /**
     * Enable the alias that fits now. {@code unfolded}: the hinge state when known (FoldWatcher), else null -
     * then the screen size decides. Returns the alias's component (FoldWatcher makes it the default home).
     */
    static String apply(Context ctx, Boolean unfolded) {
        String mode = ctx.getSharedPreferences("andromarchy_settings", Context.MODE_PRIVATE)
            .getString(KEY_HOME_SCREEN, HOME_SCREENS[0]);
        boolean desktop;
        if (mode.equals("desktop"))
            desktop = true;
        else if (mode.equals("launcher"))
            desktop = false;
        else
            desktop = false; // auto: the web home, wide when unfolded
        // Desktop mode (FoldWatcher.DESKTOP_MODE): KWin's desktop is the home unfolded, the phone home folded.
        if (FoldWatcher.desktopMode() && unfolded != null)
            desktop = unfolded;
        String home = desktop ? "HomeDesktop" : LAUNCHER;
        String component = ctx.getPackageName() + "/andro.marchy." + home;
        current = home;
        // The new one first: never a moment without a home screen.
        set(ctx, home, true);
        if (RootMode.enabled()) {
            // Rooted: both stay on, and the one that fits is made Android's default home. Disabling an alias finishes
            // every activity started through it - the web home (ShellActivity, started as .HomeShell) was destroyed on
            // each unfold and made again on each fold: its page reloaded, its Android widgets bound again (a flash).
            for (String alias : new String[] {"HomeDesktop", LAUNCHER}) set(ctx, alias, true);
            new Thread(() -> RootShell.run("cmd package set-home-activity --user 0 " + component), "home-default").start();
        } else {
            // Without root the default home can't be set: exactly one alias stays on, so Home opens it directly.
            for (String alias : new String[] {"HomeDesktop", LAUNCHER})
                if (!alias.equals(home)) set(ctx, alias, false);
        }
        return component;
    }

    /**
     * `am start` arguments for the launcher (FoldWatcher, on the cover screen, as root): by its HOME alias, as a home
     * launch - started by its activity's name it would be a second launcher, an app task beside the home one.
     */
    static String launcherStart(Context ctx) {
        return "-a android.intent.action.MAIN -c android.intent.category.HOME -n " + ctx.getPackageName() + "/andro.marchy." + LAUNCHER;
    }

    private static void set(Context ctx, String alias, boolean on) {
        PackageManager pm = ctx.getPackageManager();
        ComponentName c = new ComponentName(ctx.getPackageName(), "andro.marchy." + alias);
        int want = on ? PackageManager.COMPONENT_ENABLED_STATE_ENABLED : PackageManager.COMPONENT_ENABLED_STATE_DISABLED;
        if (pm.getComponentEnabledSetting(c) == want)
            return;
        pm.setComponentEnabledSetting(c, want, PackageManager.DONT_KILL_APP);
        Log.i(TAG, alias + (on ? " on" : " off"));
    }
}
