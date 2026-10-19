package andro.marchy;

import android.content.ComponentName;
import android.content.Context;
import android.content.pm.PackageManager;
import android.util.Log;

/**
 * PowOS: what Android's Home opens - the PowOS desktop (KDE Plasma) or the PowOS launcher (Omalauncher's home: apps,
 * widgets). Two HOME aliases (.HomeDesktop in the engine's manifest, .HomeLauncher in the app's); exactly one is
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
    /** Which launcher is "the launcher": the Compose one, or the web shell (shell/, its .HomeShell alias). */
    static final String KEY_WEB_LAUNCHER = "web_launcher";
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
        String launcher = web(ctx) ? "HomeShell" : "HomeLauncher";
        String home = desktop ? "HomeDesktop" : launcher;
        // The new one first: never a moment without a home screen. Exactly one of them stays on.
        set(ctx, home, true);
        for (String alias : new String[] {"HomeDesktop", "HomeLauncher", "HomeShell"})
            if (!alias.equals(home)) set(ctx, alias, false);
        return ctx.getPackageName() + "/andro.marchy." + home;
    }

    /** The web shell is the launcher (Settings › Home screen). */
    static boolean web(Context ctx) {
        return ctx.getSharedPreferences("andromarchy_settings", Context.MODE_PRIVATE).getBoolean(KEY_WEB_LAUNCHER, false);
    }

    /** The launcher's activity, to start it by component (FoldWatcher, on the cover screen). */
    static String launcherActivity(Context ctx) {
        return ctx.getPackageName() + "/" + (web(ctx) ? "dev.omalauncher.shell.ShellActivity" : "dev.omalauncher.MainActivity");
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
