package andro.marchy;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.HashSet;
import java.util.Set;

/**
 * Which apps have the on-screen controller enabled. The controller is per app: enabling it (Controller tile, 🎮 button)
 * applies to the app in front (powos-focus-watch's run-dir "focused-window": l:&lt;app&gt; / steam_app_&lt;id&gt; on Linux,
 * the package on Android); it shows only while that app is in front and is remembered across restarts. The old global
 * boolean "gamepad_shown" is migrated once: on becomes "the app in front at that moment", off becomes the empty set.
 */
final class PadApps {
    private static final String PREFS = "andromarchy_settings", KEY = "gamepad_apps", OLD = "gamepad_shown";

    private PadApps() { }

    static String front(Context c) {
        return MainActivity.readFocusedWindow(SessionService.runDir(c));
    }

    static synchronized boolean on(Context c, String app) {
        if (app == null || app.isEmpty()) return false;
        return read(c).contains(app);
    }

    static synchronized void set(Context c, String app, boolean on) {
        if (app == null || app.isEmpty()) return;
        SharedPreferences p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        Set<String> s = read(c);
        if (on) s.add(app); else s.remove(app);
        p.edit().putStringSet(KEY, s).apply();
    }

    private static Set<String> read(Context c) {
        SharedPreferences p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        if (!p.contains(KEY)) {
            Set<String> s = new HashSet<>();
            String f = front(c);
            if (p.getBoolean(OLD, false) && !f.isEmpty()) s.add(f);
            p.edit().putStringSet(KEY, s).remove(OLD).apply();
            return s;
        }
        return new HashSet<>(p.getStringSet(KEY, new HashSet<>()));
    }
}
