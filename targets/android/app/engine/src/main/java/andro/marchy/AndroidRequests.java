package andro.marchy;

import android.content.Context;
import android.content.Intent;
import android.os.FileObserver;
import android.provider.Settings;
import android.util.Log;

import java.io.File;
import java.nio.file.Files;

/**
 * Requests from the Linux session for things only Android can do, written to run/android-request by the
 * android-request helper (atomically, by rename): "wifi-panel", "open <package>" (full screen; a floating window on the unfolded home, [openOptions]), "split <package>" (beside Andromarchy), "float <package>" (floating window).
 */
public final class AndroidRequests implements DirWatch.Listener {
    private static final String TAG = "AndroidRequests";

    /**
     * Launch options for "open <package>": the app module's (dev.omalauncher.system.AppWindows, set by App) - a
     * floating window on the unfolded home like every app opened there, null (full screen) folded. The engine can't
     * see the app module, so it hands it in. A PowOS window's own task (WindowTasks "open") takes the same.
     */
    public static volatile java.util.function.Function<Context, android.os.Bundle> openOptions = null;
    private final Context ctx;
    private final File file;
    private DirWatch.Handle watch;

    AndroidRequests(Context ctx, File runDir) {
        this.ctx = ctx;
        this.file = new File(runDir, "android-request");
    }

    /** The run dir is watched by others too (focused-window, ...): through DirWatch, never a FileObserver of its own. */
    void startWatching() {
        if (watch == null)
            watch = DirWatch.watch(file.getParentFile(), FileObserver.MOVED_TO | FileObserver.CLOSE_WRITE, this);
    }

    void stopWatching() {
        if (watch != null)
            watch.stop();
        watch = null;
    }

    /**
     * A floating window centred on the screen: launch bounds (public API, honoured where freeform windows exist) plus
     * the freeform windowing mode (hidden API, by reflection: ignored where it is refused).
     */
    private android.app.ActivityOptions floating() {
        android.util.DisplayMetrics m = ctx.getResources().getDisplayMetrics();
        int w = m.widthPixels * 2 / 5, h = m.heightPixels * 3 / 5;
        int x = (m.widthPixels - w) / 2, y = (m.heightPixels - h) / 2;
        android.app.ActivityOptions o = android.app.ActivityOptions.makeBasic()
                .setLaunchBounds(new android.graphics.Rect(x, y, x + w, y + h));
        try {
            // Looked up through reflection itself ("meta-reflection"): the hidden-API check then sees a system caller.
            java.lang.reflect.Method lookup = Class.class.getDeclaredMethod("getDeclaredMethod", String.class, Class[].class);
            java.lang.reflect.Method set = (java.lang.reflect.Method) lookup.invoke(android.app.ActivityOptions.class,
                    "setLaunchWindowingMode", new Class<?>[] {int.class});
            set.invoke(o, 5); // WINDOWING_MODE_FREEFORM
        } catch (ReflectiveOperationException e) {
            Log.i(TAG, "freeform windowing mode unavailable: " + e);
        }
        return o;
    }

    /**
     * PowOS (temporary, for docs/android-windows.md): which direction a local socket between this app
     * (untrusted_app) and the shell helper passes SELinux. app -> shell: connect to @powos-shellhelper;
     * shell -> app: listen on @powos-app for 20 s. Results in run/socket-test.log.
     */
    private void socketTest() {
        File log = new File(file.getParentFile(), "socket-test.log");
        new Thread(() -> {
            StringBuilder out = new StringBuilder();
            try (android.net.LocalSocket s = new android.net.LocalSocket()) {
                s.connect(new android.net.LocalSocketAddress("powos-shellhelper"));
                out.append("app->shell: connected\n");
            } catch (Exception e) {
                out.append("app->shell: FAILED ").append(e).append('\n');
            }
            try (android.net.LocalServerSocket server = new android.net.LocalServerSocket("powos-app")) {
                out.append("shell->app: listening on @powos-app\n");
                write(log, out.toString());
                Thread closer = new Thread(() -> {
                    try { Thread.sleep(20_000); server.close(); } catch (Exception ignored) {}
                });
                closer.start();
                try (android.net.LocalSocket c = server.accept()) {
                    out.append("shell->app: accepted from uid ").append(c.getPeerCredentials().getUid()).append('\n');
                } catch (Exception e) {
                    out.append("shell->app: no connection (").append(e.getMessage()).append(")\n");
                }
            } catch (Exception e) {
                out.append("shell->app: listen FAILED ").append(e).append('\n');
            }
            write(log, out.toString());
        }).start();
    }

    private static void write(File f, String s) {
        try (java.io.FileWriter w = new java.io.FileWriter(f)) {
            w.write(s);
        } catch (java.io.IOException ignored) {
        }
    }

    @Override
    public void onEvent(int event, String path) {
        if (!"android-request".equals(path))
            return;
        String line;
        try {
            line = new String(Files.readAllBytes(file.toPath())).trim();
        } catch (Exception e) {
            return;
        }
        String[] req = line.split(" ", 2);
        Intent intent = null;
        if (req[0].equals("wifi-panel"))
            intent = new Intent(Settings.Panel.ACTION_WIFI); // apps may not switch Wi-Fi themselves
        else if ((req[0].equals("open") || req[0].equals("split")) && req.length == 2) {
            intent = ctx.getPackageManager().getLaunchIntentForPackage(req[1].trim());
            // split: beside Andromarchy (Android's split screen; a tablet enters it from full screen)
            if (intent != null && req[0].equals("split"))
                intent.addFlags(Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT | Intent.FLAG_ACTIVITY_MULTIPLE_TASK);
        }
        if (req[0].equals("socket-test")) { // PowOS (temporary): can the app and the shell helper (ShellHelper) talk?
            socketTest();
            return;
        }
        if (req[0].equals("power") && req.length == 2) { // Omarchy's shutdown / reboot / log out / suspend
            Restarter.power(ctx, req[1].trim());
            return;
        }
        java.util.function.Function<Context, android.os.Bundle> open = openOptions;
        android.os.Bundle options = req[0].equals("open") && open != null ? open.apply(ctx) : null;
        if (req[0].equals("float") && req.length == 2) {
            intent = ctx.getPackageManager().getLaunchIntentForPackage(req[1].trim());
            options = floating().toBundle();
            if (intent != null)
                intent.addFlags(Intent.FLAG_ACTIVITY_MULTIPLE_TASK);
        }
        if (intent == null) {
            Log.w(TAG, "unknown request: " + line);
            return;
        }
        try {
            ctx.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), options);
        } catch (Exception e) {
            Log.w(TAG, "request failed: " + line, e);
        }
    }
}
