package andro.marchy;

import android.content.Context;
import android.content.Intent;
import android.net.LocalSocket;
import android.net.Uri;
import android.util.Log;

import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * PowOS: the app's end of the window control channel - PowOS windows KWin shows as their own Android tasks
 * (docs/powos-window-tasks.md). A connection to the display daemon in the control role ("app"); the daemon relays
 * one-line messages to and from KWin: {@code open <id> <app id> <caption> [fullscreen]}, {@code title <id> <caption>},
 * {@code close <id>}, {@code android <package>} from KWin; {@code closed <id>}, {@code focus <id>} to it
 * (tab-separated).
 *
 * Runs for the session's life (SessionService), reconnecting while the daemon or KWin restart.
 */
public final class WindowTasks {
    private static final String TAG = "WindowTasks";
    // protocol.h
    private static final int CTRL_MSG_CONTROL_HELLO = 20;
    private static final int CTRL_MSG_CONTROL = 21;
    private static final int CONTROL_ROLE_APP = 1;
    private static final int CONTROL_MAX_PAYLOAD = 4096;

    private static volatile OutputStream out;
    /** What KWin said it understands ("caps": " size export-new "); empty for an older KWin, or not connected. */
    private static volatile String caps = "";
    /** The "export-new" state KWin has (null: not told on this connection). */
    private static volatile Boolean exportNewSent;

    /**
     * Whether apps float now (the app module's AppWindows.floating, set by App through setFloating: the unfolded home). KWin is told
     * ("export-new"), so every new application window opens as its own task - a floating window - not on the desktop
     * nothing shows then.
     */
    public static volatile java.util.function.Predicate<Context> floating = null;
    private static Thread thread;
    /** The window tasks on screen, by surface id: KWin's "close" and "title" reach them here. */
    static final Map<Integer, PowosWindowActivity> tasks = new ConcurrentHashMap<>();

    private WindowTasks() {}

    static synchronized void start(Context context) {
        if (thread != null)
            return;
        Context app = context.getApplicationContext();
        String socket = SessionService.daemonSocket(app);
        // Folded and unfolded: KWin told whether new windows float.
        app.registerComponentCallbacks(new android.content.ComponentCallbacks() {
            @Override
            public void onConfigurationChanged(android.content.res.Configuration c) {
                tellExportNew(app);
            }

            @Override
            public void onLowMemory() {}
        });
        thread = new Thread(() -> run(app, socket), "window-tasks");
        thread.setDaemon(true);
        thread.start();
    }

    /** Sets [floating] and tells KWin at once (it may have said "caps" before the app module was up). */
    public static void setFloating(Context context, java.util.function.Predicate<Context> f) {
        floating = f;
        tellExportNew(context.getApplicationContext());
    }

    /** Whether KWin understands [cap] (its "caps" line on this connection). */
    static boolean kwinCan(String cap) {
        return caps.contains(" " + cap + " ");
    }

    /** KWin told whether apps float now ("export-new 1/0"), when it changed or KWin hasn't been told. */
    static void tellExportNew(Context context) {
        java.util.function.Predicate<Context> f = floating;
        if (!kwinCan("export-new") || f == null)
            return;
        boolean on = f.test(context);
        if (Boolean.valueOf(on).equals(exportNewSent))
            return;
        exportNewSent = on;
        sendLine("export-new\t" + (on ? 1 : 0));
        Log.i(TAG, "export-new " + (on ? 1 : 0) + (out == null ? ": channel down, dropped" : ""));
    }

    /**
     * Task [id] closed for good (its card swiped, its title bar's close). KWin closes the window only while it has
     * "export-new 1" (the unfolded home: nothing shows the desktop), else it puts the window back on the desktop. KWin's
     * state is re-told first, unconditionally, on the same channel: a stale "0" there left Dolphin running on the
     * hidden desktop after its card closed (linux-dock.sh, 2026-10-23).
     */
    static void closed(Context context, int id) {
        exportNewSent = null;
        tellExportNew(context.getApplicationContext());
        send("closed", id);
        Log.i(TAG, "closed " + id + " (caps:" + caps + "export-new " + exportNewSent + ")" + (out == null ? ": channel down, dropped" : ""));
    }

    /** The control channel reached the display daemon. */
    static boolean connected() {
        return out != null;
    }

    private static void run(Context context, String socket) {
        while (true) {
            try (LocalSocket s = new LocalSocket()) {
                s.connect(SessionService.localAddress(socket));
                if (!SessionService.trustedPeer(s, socket))
                    throw new IOException("display socket " + socket + " is not this app's daemon");
                OutputStream o = s.getOutputStream();
                o.write(frame(CTRL_MSG_CONTROL_HELLO, le32(CONTROL_ROLE_APP)));
                caps = "";
                exportNewSent = null;
                out = o;
                Log.i(TAG, "control channel up");
                read(context, s.getInputStream());
            } catch (IOException e) {
                // the daemon isn't there (yet / any more): retry
            } finally {
                out = null;
            }
            try {
                Thread.sleep(1000);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    private static void read(Context context, InputStream in) throws IOException {
        DataInputStream d = new DataInputStream(in);
        byte[] header = new byte[8];
        while (true) {
            d.readFully(header);
            ByteBuffer h = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN);
            int type = h.getInt();
            int size = h.getInt();
            if (size < 0 || size > CONTROL_MAX_PAYLOAD)
                throw new IOException("bad control message size " + size);
            byte[] payload = new byte[size];
            d.readFully(payload);
            if (type == CTRL_MSG_CONTROL)
                handle(context, new String(payload, StandardCharsets.UTF_8));
        }
    }

    private static void handle(Context context, String line) {
        String[] f = line.split("\t", -1);
        if (f[0].equals("android") && f.length > 1) {
            showAndroidApp(context, f[1]);
            return;
        }
        if (f[0].equals("caps")) {
            // KWin's first line on a connection: what it understands (an older one says nothing).
            caps = f.length > 1 ? " " + f[1] + " " : "";
            Log.i(TAG, "KWin caps:" + caps);
            exportNewSent = null;
            tellExportNew(context);
            return;
        }
        int id;
        try {
            id = Integer.parseInt(f.length > 1 ? f[1] : "");
        } catch (NumberFormatException e) {
            Log.w(TAG, "bad control message: " + line);
            return;
        }
        switch (f[0]) {
            case "open": {
                // A document task per surface id: its own card in Recents, split screen, floating window.
                boolean fullScreen = f.length > 4 && f[4].equals("fullscreen");
                String appId = f.length > 2 ? f[2] : "";
                // One task per KWin window: a window that has one already (KWin's show again - the launcher, the
                // dock, a window activated the desktop way) brings that one back, never a second activity; one that
                // is full screen floats then on the unfolded home (it opened folded, or before apps floated).
                PowosWindowActivity existing = tasks.get(id);
                if (existing != null && !existing.isFinishing() && !existing.getIntent().getBooleanExtra(PowosWindowActivity.EXTRA_FULLSCREEN, false)
                        && raise(context, existing.getTaskId())) {
                    Log.i(TAG, "open " + id + " (" + appId + "): its task " + existing.getTaskId() + " back");
                    break;
                }
                android.os.Bundle options = fullScreen ? null : floatingOptions(context);
                Log.i(TAG, "open " + id + " (" + appId + "): " + (fullScreen ? "full screen (the app's own)" : options != null ? "floating" : "full screen"));
                Intent i = new Intent(context, PowosWindowActivity.class)
                        .setData(Uri.parse("powos-window://" + id))
                        .putExtra(PowosWindowActivity.EXTRA_APP_ID, f.length > 2 ? f[2] : "")
                        .putExtra(PowosWindowActivity.EXTRA_TITLE, f.length > 3 ? f[3] : "")
                        // The application went full screen (a game, Steam Big Picture): an immersive task.
                        .putExtra(PowosWindowActivity.EXTRA_FULLSCREEN, fullScreen)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NEW_DOCUMENT);
                context.startActivity(i, options);
                break;
            }
            case "title": {
                PowosWindowActivity a = tasks.get(id);
                if (a != null && f.length > 2)
                    a.runOnUiThread(() -> a.setTitleText(f[2]));
                break;
            }
            case "close": {
                PowosWindowActivity a = tasks.get(id);
                if (a != null)
                    a.runOnUiThread(a::closedByKWin);
                break;
            }
            default:
                Log.w(TAG, "unknown control message: " + line);
        }
    }

    /**
     * On the unfolded home (the PowOS desktop) a PowOS window's task floats like an Android app's - the same launch
     * options (AppWindows: freeform, cascaded, above home's bar), so it gets PowOS's frame, the dock, the home pages and
     * the running dot too. Every way one opens comes here: the launcher and dock (powos-open-task -> KWin's show),
     * `android-request`, a window KWin exports. Folded, or a full-screen application (a game): null, full screen.
     */
    private static android.os.Bundle floatingOptions(Context context) {
        java.util.function.Function<Context, android.os.Bundle> options = AndroidRequests.openOptions;
        return options != null ? options.apply(context) : null;
    }

    /**
     * Brings Android task [taskId] (a PowOS window's) to the front: the app module's (AppWindows.taskOptions through
     * Tasks.open, set by App) - floating on the unfolded home even when it is full screen now. False: not set or failed.
     */
    public static volatile java.util.function.BiPredicate<Context, Integer> raiseTask = null;

    private static boolean raise(Context context, int taskId) {
        java.util.function.BiPredicate<Context, Integer> r = raiseTask;
        return r != null && taskId > 0 && r.test(context, taskId);
    }

    /** The PowOS app id (desktop id / app id KWin gave "open") of the window shown in Android task [taskId], or null. */
    public static String appIdOfTask(int taskId) {
        for (PowosWindowActivity a : tasks.values())
            if (a.getTaskId() == taskId)
                return a.getIntent().getStringExtra(PowosWindowActivity.EXTRA_APP_ID);
        return null;
    }

    /**
     * An Android app the user maximized in its PowOS window (powos-android-app): KWin closed that window, which handed
     * the app back to the phone's screen; bring it to the front there - the app itself, full screen.
     */
    private static void showAndroidApp(Context context, String pkg) {
        Intent launch = context.getPackageManager().getLaunchIntentForPackage(pkg);
        if (launch == null) {
            Log.w(TAG, "no launcher activity for " + pkg);
            return;
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        android.app.ActivityOptions options = android.app.ActivityOptions.makeBasic()
                .setLaunchDisplayId(android.view.Display.DEFAULT_DISPLAY);
        try {
            context.startActivity(launch, options.toBundle());
        } catch (RuntimeException e) {
            Log.w(TAG, "could not bring " + pkg + " to the front: " + e.getMessage());
        }
    }

    /** Sends {@code <verb>\t<id>} to KWin; dropped while the channel is down (KWin knows nothing to act on then). */
    static void send(String verb, int id) {
        sendLine(verb + "\t" + id);
    }

    /** Sends one control line (tab-separated fields) to KWin; dropped while the channel is down. */
    static void sendLine(String text) {
        OutputStream o = out;
        if (o == null)
            return;
        byte[] line = text.getBytes(StandardCharsets.UTF_8);
        try {
            synchronized (WindowTasks.class) {
                o.write(frame(CTRL_MSG_CONTROL, line));
            }
        } catch (IOException e) {
            Log.w(TAG, "control send failed: " + e.getMessage());
        }
    }

    private static byte[] frame(int type, byte[] payload) {
        return ByteBuffer.allocate(8 + payload.length).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(type).putInt(payload.length).put(payload).array();
    }

    private static byte[] le32(int v) {
        return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array();
    }
}
