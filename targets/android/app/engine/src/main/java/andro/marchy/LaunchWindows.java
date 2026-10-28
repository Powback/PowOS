package andro.marchy;

import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.net.Uri;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.function.Consumer;

/**
 * Launch windows (board "Launch window: instant placeholder/splash until the app's window appears"): a tap on a PowOS
 * (Linux) app opens its window's task AT ONCE - where the app's window will be (the same launch options as KWin's
 * "open": floating on the unfolded home), its icon and name on it - and the app's first window KWin opens for it
 * becomes that task ([adopt] -> PowosWindowActivity.become): no second task, no jump to another place. A cold Steam
 * takes 25-40 s to its first window; before, nothing showed meanwhile.
 *
 * An Android app has this from the system already: its starting window (the splash screen) shows in its own task at
 * its launch bounds the moment it starts, and becomes the app.
 */
public final class LaunchWindows {
    private static final String TAG = "LaunchWindows";
    /** The ids a launch window's app's windows may carry (the .desktop id, StartupWMClass): KWin's app id is one. */
    static final String EXTRA_IDS = "launch_ids";
    /** The splash stays this long after the window's consumer is up (its first frames), then fades. */
    static final long SPLASH_HOLD_MS = 250;
    static final long SPLASH_FADE_MS = 180;
    private static final int ICON_DP = 72;

    /** The launch windows waiting for their app's window, oldest first. */
    private static final List<PowosWindowActivity> waiting = new CopyOnWriteArrayList<>();

    private LaunchWindows() {}

    /**
     * Opens the launch window of app [appId] (its windows' ids [ids]), named [label]. False when none opens: no window
     * tasks (KWin not connected, an older KWin) or one is waiting for that app already.
     */
    public static boolean open(Context context, String appId, String[] ids, String label) {
        if (!WindowTasks.connected() || !WindowTasks.kwinCan("export-new") || waitingFor(ids) != null)
            return false;
        // The Plasma app is on screen: the app's window opens ON the desktop (KWin: "desktop 1"), nothing is a task. A
        // floating launch task started over it moves home (the dock) up behind/over the desktop until it ends (PowosDock
        // log: home started while desktop=true), the flash seen launching inside Plasma.
        if (WindowTasks.desktopOnScreen() && WindowTasks.kwinCan("desktop")) {
            Log.i(TAG, "no launch window for " + appId + ": the desktop is on screen (its window opens there)");
            return false;
        }
        java.util.function.Function<Context, android.os.Bundle> options = AndroidRequests.openOptions;
        Log.i("PowosDock", "launch window task for " + appId + " (desktop on screen=" + WindowTasks.desktopOnScreen() + ")");
        Intent i = new Intent(context, PowosWindowActivity.class)
                // Its own document each time (documentLaunchMode intoExisting would bring an old one back).
                .setData(Uri.parse("powos-window://launch?app=" + Uri.encode(appId) + "&at=" + android.os.SystemClock.uptimeMillis()))
                .putExtra(PowosWindowActivity.EXTRA_APP_ID, appId)
                .putExtra(PowosWindowActivity.EXTRA_TITLE, label)
                .putExtra(EXTRA_IDS, ids)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NEW_DOCUMENT);
        context.startActivity(i, options != null ? options.apply(context) : null);
        Log.i(TAG, "launch window for " + appId);
        return true;
    }

    /** [data] is a launch window's (open's). */
    static boolean isLaunch(Uri data) {
        return data != null && "powos-window".equals(data.getScheme()) && "launch".equals(data.getHost());
    }

    static void add(PowosWindowActivity a) {
        waiting.add(a);
    }

    static void remove(PowosWindowActivity a) {
        waiting.remove(a);
    }

    /**
     * KWin opens a window of app [appId]: the launch window waiting for that app, if any, is handed to [become] (it
     * shows the window from now on) - true. A full-screen window (a game's own) gets an immersive task of its own: the
     * launch window goes, false.
     */
    static boolean adopt(String appId, boolean fullScreen, Consumer<PowosWindowActivity> become) {
        PowosWindowActivity a = waitingFor(new String[] {appId});
        if (a == null || appId.isEmpty())
            return false;
        waiting.remove(a);
        if (fullScreen) {
            a.runOnUiThread(a::launchEnded);
            return false;
        }
        become.accept(a);
        return true;
    }

    /** App [appId]'s launch is over (its helper exited, or it opened on the desktop): a launch window still waiting goes. */
    public static void done(String appId) {
        for (PowosWindowActivity a : waiting) {
            if (appId.equals(a.getIntent().getStringExtra(PowosWindowActivity.EXTRA_APP_ID))) {
                waiting.remove(a);
                Log.i(TAG, "launch of " + appId + " ended with no window: its launch window goes");
                a.runOnUiThread(a::launchEnded);
            }
        }
    }

    /** The tasks of launch windows still waiting (WindowTasks.finishStale keeps them). */
    static Set<Integer> taskIds() {
        Set<Integer> ids = new java.util.HashSet<>();
        for (PowosWindowActivity a : waiting)
            ids.add(a.getTaskId());
        return ids;
    }

    /** The waiting launch window one of whose app's ids matches one of [ids] (LinuxApp.matches' rules), or null. */
    private static PowosWindowActivity waitingFor(String[] ids) {
        for (PowosWindowActivity a : waiting) {
            if (a.isFinishing())
                continue;
            String[] mine = a.getIntent().getStringArrayExtra(EXTRA_IDS);
            for (String id : ids)
                if (matches(mine, id))
                    return a;
        }
        return null;
    }

    /** KWin's app id [id] is one of [ids]: the same, or an id's last dotted part (org.kde.kate ~ kate), any case. */
    static boolean matches(String[] ids, String id) {
        if (ids == null || id == null || id.isEmpty())
            return false;
        String k = id.toLowerCase(Locale.ROOT);
        for (String i : ids) {
            if (i == null || i.isEmpty())
                continue;
            String m = i.toLowerCase(Locale.ROOT);
            if (m.equals(k) || m.substring(m.lastIndexOf('.') + 1).equals(k) || k.substring(k.lastIndexOf('.') + 1).equals(m))
                return true;
        }
        return false;
    }

    /** A launch window's face: the app's icon and name in the middle, on the window's plain background. */
    static View splash(Context context, String label, Bitmap icon) {
        boolean night = (context.getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
                == android.content.res.Configuration.UI_MODE_NIGHT_YES;
        float d = context.getResources().getDisplayMetrics().density;
        FrameLayout root = new FrameLayout(context);
        root.setBackgroundColor(night ? 0xFF1C1C20 : 0xFFF3F3F6);
        LinearLayout col = new LinearLayout(context);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setGravity(Gravity.CENTER_HORIZONTAL);
        if (icon != null) {
            ImageView v = new ImageView(context);
            v.setImageBitmap(icon);
            col.addView(v, new LinearLayout.LayoutParams((int) (ICON_DP * d), (int) (ICON_DP * d)));
        }
        if (label != null && !label.isEmpty()) {
            TextView t = new TextView(context);
            t.setText(label);
            t.setTextSize(16);
            t.setTextColor(night ? 0xDDFFFFFF : 0xDD000000);
            t.setPadding(0, (int) (12 * d), 0, 0);
            col.addView(t);
        }
        root.addView(col, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        return root;
    }
}
