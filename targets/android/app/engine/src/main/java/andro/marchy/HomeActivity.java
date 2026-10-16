package andro.marchy;

import android.app.Activity;
import android.app.ActivityOptions;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;

/**
 * PowOS: Android's home screen. Opens either the PowOS launcher (Omalauncher's home: apps, widgets) or the PowOS
 * desktop (KDE Plasma), on the screen Home was pressed on, then gets out of the way.
 *   auto      launcher on a phone-sized screen (the Open's cover screen), desktop on a big one (its inner screen)
 *   desktop   always the desktop
 *   launcher  always the launcher
 * Chosen in Settings (Home screen); stored as {@link #KEY_HOME_SCREEN} in the engine's preferences.
 */
public class HomeActivity extends Activity {
    static final String KEY_HOME_SCREEN = "home_screen";
    static final String[] HOME_SCREENS = {"auto", "desktop", "launcher"};
    /** Below this smallest width (dp) a screen is phone-sized: the Open's cover screen is 343 dp, its inner 698. */
    private static final int PHONE_MAX_DP = 600;
    private static final String LAUNCHER = "dev.omalauncher.MainActivity";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        open();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        open();
    }

    private void open() {
        Intent target = new Intent(Intent.ACTION_MAIN)
            .setClassName(this, showLauncher(this) ? LAUNCHER : MainActivity.class.getName())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ActivityOptions options = ActivityOptions.makeBasic();
        if (getDisplay() != null) options.setLaunchDisplayId(getDisplay().getDisplayId());
        startActivity(target, options.toBundle());
        finish();
        overridePendingTransition(0, 0);
    }

    static boolean showLauncher(Activity a) {
        String mode = a.getSharedPreferences("andromarchy_settings", Context.MODE_PRIVATE)  // the engine's settings
            .getString(KEY_HOME_SCREEN, HOME_SCREENS[0]);
        if (mode.equals("desktop")) return false;
        if (mode.equals("launcher")) return true;
        return a.getResources().getConfiguration().smallestScreenWidthDp < PHONE_MAX_DP;
    }
}
