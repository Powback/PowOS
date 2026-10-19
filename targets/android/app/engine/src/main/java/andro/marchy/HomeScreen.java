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
 *   auto      launcher on the cover screen (folded), desktop on the inner screen (FoldWatcher switches on fold)
 *   desktop   always the desktop
 *   launcher  always the launcher
 * Chosen in Settings (Home screen), {@link #KEY_HOME_SCREEN} in the engine's preferences.
 */
final class HomeScreen {
    private static final String TAG = "HomeScreen";
    static final String KEY_HOME_SCREEN = "home_screen";
    static final String[] HOME_SCREENS = {"auto", "desktop", "launcher"};
    /** The launcher's HOME alias (app module's manifest, on dev.omalauncher.shell.ShellActivity). */
    private static final String LAUNCHER = "HomeShell";
    /** Below this smallest width (dp) a screen is phone-sized: the Open's cover screen is 343 dp, its inner 698. */
    private static final int PHONE_MAX_DP = 600;

    private HomeScreen() {
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
            desktop = unfolded != null ? unfolded
                : ctx.getResources().getConfiguration().smallestScreenWidthDp >= PHONE_MAX_DP;
        String home = desktop ? "HomeDesktop" : LAUNCHER;
        // The new one first: never a moment without a home screen. Exactly one of them stays on.
        set(ctx, home, true);
        for (String alias : new String[] {"HomeDesktop", LAUNCHER})
            if (!alias.equals(home)) set(ctx, alias, false);
        return ctx.getPackageName() + "/andro.marchy." + home;
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
