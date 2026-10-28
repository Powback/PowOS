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
 * {@code close <id>}, {@code android <package>}, {@code caps <words>}, {@code session <uuid> <id,id,...>},
 * {@code decor <id> 1|0} (KWin's title bar or the window's own, kwin 0026), {@code move <id>} (its own bar dragged) from KWin;
 * {@code closed <id>}, {@code focus <id>}, {@code hello 1} to it (tab-separated).
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
    /**
     * The running KWin's session ("session": a uuid per KWin process, kwin 0023), null while not told or for an older
     * KWin. Window ids restart at 1 with each KWin: a window task belongs to the session in its intent's data
     * (powos-window://id?session=uuid), and one of another session is finished, never shown or raised again.
     */
    static volatile String session;
    /** The "export-new" state KWin has (null: not told on this connection). */
    private static volatile Boolean exportNewSent;
    /**
     * The desktop's activities on screen (MainActivity and its home alias HomeDesktop, started..stopped): the Plasma
     * app is showing KWin's desktop, so windows belong there - KDE windows with KDE's decoration, opened from Kickoff,
     * maximized the KDE way. KWin is told ("desktop 1|0", kwin 0025); an older KWin gets "export-new 0" meanwhile.
     */
    private static int desktopStarted;
    /** The "desktop" state KWin has (null: not told on this connection). */
    private static volatile Boolean desktopSent;

    /**
     * Whether apps float now (the app module's AppWindows.floating, set by App through setFloating: the unfolded home). KWin is told
     * ("export-new"), so every new application window opens as its own task - a floating window - not on the desktop
     * nothing shows then.
     */
    public static volatile java.util.function.Predicate<Context> floating = null;
    private static Thread thread;
    /** The window tasks on screen, by surface id: KWin's "close" and "title" reach them here. */
    static final Map<Integer, PowosWindowActivity> tasks = new ConcurrentHashMap<>();
    /**
     * The windows an "open" is making a task for (startActivity, or a launch window's become posted to its UI thread)
     * until that task registers ([register]): KWin's second "open" for the same window ~50-80 ms later then finds it
     * here, not nothing - it started a second task for Kate (2026-10-24: the launch window became window 2 and a
     * fresh task 2970 opened for it too; one of the two stayed black). Reader thread puts, any thread removes.
     */
    private static final Map<Integer, Long> opening = new ConcurrentHashMap<>();
    /** An "open" whose task never registered (startActivity refused, the app died) stops holding its window after this. */
    private static final long OPENING_MS = 5000;

    /**
     * [a] shows window [id] now: false when another live task shows it already - then [a] must go (one task per KWin
     * window, always). Every registration comes here (onCreate, a launch window's become).
     */
    static boolean register(int id, PowosWindowActivity a) {
        opening.remove(id);
        PowosWindowActivity prev = tasks.putIfAbsent(id, a);
        if (prev == null || prev == a)
            return true;
        boolean live = prev.live() && !prev.isDestroyed();
        // A full-screen task's window floating again on the unfolded home ([open]: not reusable) moves to [a]'s task.
        boolean refloat = fullScreen(prev) && !fullScreen(a);
        if (live && !refloat)
            return false;
        tasks.put(id, a);
        if (live)
            prev.replaced(); // never left behind black
        return true;
    }

    private static boolean fullScreen(PowosWindowActivity a) {
        return a.getIntent().getBooleanExtra(PowosWindowActivity.EXTRA_FULLSCREEN, false);
    }
    /**
     * Who draws each window's title bar, by surface id ("decor", kwin 0026): true KWin's decoration (which a task
     * doesn't show - PowOS's frame adds its bar), false the window's own (client-side: Steam, GTK header bars - no
     * second bar). Told before "open"; none for an older KWin (a bar, as before).
     */
    static final Map<Integer, Boolean> kwinBar = new ConcurrentHashMap<>();
    /** A window's "decor" changed for a task that may be framed already (the app's frames refresh). */
    public static volatile Runnable barChanged = null;
    /**
     * The rest of a touch on a window's own title bar moves its task [taskId] ("move", kwin 0026): the app's frames
     * (WindowFrames.appMove) get each event, the first one as the drag's start; false = no frame to move it.
     */
    public static volatile java.util.function.BiPredicate<Integer, android.view.MotionEvent> moveTask = null;

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

    /** The desktop's activity [started] (true) or stopped (false): KWin told whether the desktop is on screen. */
    static void desktopShown(Context context, boolean started) {
        synchronized (WindowTasks.class) {
            desktopStarted = Math.max(0, desktopStarted + (started ? 1 : -1));
        }
        Context app = context.getApplicationContext();
        tellDesktop();
        tellExportNew(app);
    }

    /** Whether the desktop (the Plasma app) is on screen now. */
    public static boolean desktopOnScreen() {
        synchronized (WindowTasks.class) {
            return desktopStarted > 0;
        }
    }

    /** KWin told whether the desktop is on screen ("desktop 1/0", kwin 0025), when it changed or KWin hasn't been told. */
    static void tellDesktop() {
        if (!kwinCan("desktop"))
            return;
        boolean on = desktopOnScreen();
        if (Boolean.valueOf(on).equals(desktopSent))
            return;
        desktopSent = on;
        sendLine("desktop\t" + (on ? 1 : 0));
        Log.i(TAG, "desktop " + (on ? 1 : 0) + (out == null ? ": channel down, dropped" : ""));
    }

    /** KWin told whether apps float now ("export-new 1/0"), when it changed or KWin hasn't been told. */
    static void tellExportNew(Context context) {
        java.util.function.Predicate<Context> f = floating;
        if (!kwinCan("export-new") || f == null)
            return;
        // A KWin without "desktop" (before 0025) would take new windows out of the Plasma app into floating tasks: it
        // gets "export-new 0" while the desktop is on screen.
        boolean on = f.test(context) && (kwinCan("desktop") || !desktopOnScreen());
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
                session = null;
                exportNewSent = null;
                desktopSent = null;
                out = o;
                // KWin says "caps" + "session" when it connects; if it came first, the daemon dropped them: ask again
                // (an older KWin ignores it).
                sendLine("hello\t1");
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
            desktopSent = null;
            tellDesktop();
            tellExportNew(context);
            return;
        }
        if (f[0].equals("session") && f.length > 1) {
            session = f[1];
            java.util.Set<Integer> live = liveIds(f);
            Log.i(TAG, "KWin session " + session + ", its tasks " + live);
            kwinBar.keySet().retainAll(live);
            finishStale(context, session, live);
            return;
        }
        int id;
        try {
            id = Integer.parseInt(f.length > 1 ? f[1] : "");
        } catch (NumberFormatException e) {
            Log.w(TAG, "bad control message: " + line);
            return;
        }
        if (f[0].equals("open"))
            open(context, id, f);
        else
            onWindow(id, f);
    }

    /** The ids in a "session" line's third field. */
    private static java.util.Set<Integer> liveIds(String[] f) {
        java.util.Set<Integer> live = new java.util.HashSet<>();
        for (String s : (f.length > 2 ? f[2] : "").split(",")) {
            try {
                live.add(Integer.parseInt(s));
            } catch (NumberFormatException e) {
                // empty: no tasks
            }
        }
        return live;
    }

    /** KWin's "open <id> <app id> <caption> [fullscreen]": the window in a task of its own, or back in the one it has. */
    private static void open(Context context, int id, String[] f) {
        // A document task per surface id: its own card in Recents, split screen, floating window.
        boolean fullScreen = f.length > 4 && f[4].equals("fullscreen");
        String appId = f.length > 2 ? f[2] : "";
        String title = f.length > 3 ? f[3] : "";
        // One task per KWin window: a window that has one already (KWin's show again - the launcher, the
        // dock, a window activated the desktop way) brings that one back, never a second activity; one that
        // is full screen floats then on the unfolded home (it opened folded, or before apps floated).
        PowosWindowActivity existing = tasks.get(id);
        boolean reusable = existing != null && existing.live() && !existing.getIntent().getBooleanExtra(PowosWindowActivity.EXTRA_FULLSCREEN, false);
        // Already the front task (KWin shows a window again right after it opened in its launch window): nothing to
        // raise. A raise is startActivityFromRecents, which sent every other floating task to the back (TO_BACK in
        // the TO_FRONT transition): opening Kate after Dolphin minimised Dolphin.
        if (reusable && existing.inFront()) {
            Log.i(TAG, "open " + id + " (" + appId + "): its task " + existing.getTaskId() + " is in front already");
            return;
        }
        if (reusable && raise(context, existing.getTaskId())) {
            Log.i(TAG, "open " + id + " (" + appId + "): its task " + existing.getTaskId() + " back");
            return;
        }
        // A task for this window is on its way already (KWin's repeat "open" before it registered): no second one.
        Long since = opening.get(id);
        long now = android.os.SystemClock.uptimeMillis();
        if (existing == null && since != null && now - since < OPENING_MS) {
            Log.i(TAG, "open " + id + " (" + appId + "): its task is opening already");
            return;
        }
        opening.put(id, now);
        Uri data = windowData(id);
        // The launch window of its app (LaunchWindows: opened at the tap) becomes this window: same task, same place.
        Runnable orElse = () -> {
            opening.remove(id);
            open(context, id, f);
        };
        if (LaunchWindows.adopt(appId, fullScreen, a -> a.runOnUiThread(() -> a.become(id, data, appId, title, orElse)))) {
            Log.i(TAG, "open " + id + " (" + appId + "): in its launch window");
            return;
        }
        android.os.Bundle options = fullScreen ? null : floatingOptions(context);
        Log.i(TAG, "open " + id + " (" + appId + "): " + (fullScreen ? "full screen (the app's own)" : options != null ? "floating" : "full screen"));
        Intent i = new Intent(context, PowosWindowActivity.class)
                .setData(data)
                .putExtra(PowosWindowActivity.EXTRA_APP_ID, appId)
                .putExtra(PowosWindowActivity.EXTRA_TITLE, title)
                // The application went full screen (a game, Steam Big Picture): an immersive task.
                .putExtra(PowosWindowActivity.EXTRA_FULLSCREEN, fullScreen)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NEW_DOCUMENT);
        Log.i("PowosDock", "window task for " + id + " (" + appId + ") started over the " + (desktopOnScreen() ? "Plasma desktop" : "home"));
        context.startActivity(i, options);
    }

    /** Window [id]'s task data: the session in it too, so a new KWin's window 1 is a new task, not the old one's. */
    private static Uri windowData(int id) {
        String s = session;
        return Uri.parse("powos-window://" + id + (s != null ? "?session=" + Uri.encode(s) : ""));
    }

    /** KWin's lines about window [id] other than "open". */
    private static void onWindow(int id, String[] f) {
        switch (f[0]) {
            case "decor": {
                boolean kwin = !(f.length > 2 && f[2].equals("0"));
                Boolean was = kwinBar.put(id, kwin);
                Log.i(TAG, "decor " + id + ": " + (kwin ? "KWin's title bar (the frame's bar)" : "its own title bar (no frame bar)"));
                Runnable r = barChanged;
                if (r != null && was != null && was != kwin)
                    r.run();
                break;
            }
            case "move": {
                PowosWindowActivity a = tasks.get(id);
                Log.i(TAG, "move " + id + ": its own title bar dragged" + (a == null ? " (no task)" : ""));
                if (a != null)
                    a.runOnUiThread(a::appMove);
                break;
            }
            case "title": {
                PowosWindowActivity a = tasks.get(id);
                if (a != null && f.length > 2)
                    a.runOnUiThread(() -> a.setTitleText(f[2]));
                break;
            }
            case "close": {
                kwinBar.remove(id);
                PowosWindowActivity a = tasks.get(id);
                if (a != null)
                    a.runOnUiThread(a::closedByKWin);
                break;
            }
            case "fullscreen": {
                // A floating window's application went full screen by itself (a game, a video, F11) - "1" - or left
                // it ("0", KWin patch 0021): the same task covers the whole screen, then floats again where it was.
                PowosWindowActivity a = tasks.get(id);
                boolean on = f.length > 2 && f[2].equals("1");
                Log.i(TAG, "fullscreen " + id + ": " + (on ? "on" : "off") + (a == null ? " (no task)" : ""));
                if (a != null)
                    a.runOnUiThread(() -> a.appFullScreen(on));
                break;
            }
            default:
                Log.w(TAG, "unknown control message: " + String.join("\t", f));
        }
    }

    /**
     * Android task [taskId] shows a Linux window that draws its own title bar (KWin's "decor <id> 0": client-side
     * decorations): its frame adds none. False for every other task, and while KWin hasn't said (an older KWin).
     */
    public static boolean drawsOwnBar(int taskId) {
        for (PowosWindowActivity a : tasks.values())
            if (a.getTaskId() == taskId && a.live())
                return Boolean.FALSE.equals(kwinBar.get(a.windowId()));
        return false;
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

    /**
     * Android task [taskId] (a PowOS window's) covering the whole screen (true) or floating again at its bounds before
     * (false): the app module's (WindowFrames.appFullScreen, set by App). Null: the task stays as it is.
     */
    public static volatile java.util.function.BiConsumer<Integer, Boolean> fullScreenTask = null;

    private static boolean raise(Context context, int taskId) {
        java.util.function.BiPredicate<Context, Integer> r = raiseTask;
        return r != null && taskId > 0 && r.test(context, taskId);
    }

    /**
     * Every window task that isn't one of KWin [current]'s [live] tasks finished and removed (a session restart: KWin's
     * ids start at 1 again, so the old tasks would take the new windows' place - a launcher tap on Kate raised the old,
     * dead Kate task). Covers the tasks Android kept without an activity (an app restart) as well as live activities;
     * nothing is sent to KWin for them (their ids are this KWin's other windows' now).
     */
    private static void finishStale(Context context, String current, java.util.Set<Integer> live) {
        for (PowosWindowActivity a : tasks.values()) {
            if (!a.ofSession(current) || !live.contains(a.windowId())) {
                tasks.remove(a.windowId(), a);
                a.staleSession();
            }
        }
        android.app.ActivityManager am = context.getSystemService(android.app.ActivityManager.class);
        if (am == null)
            return;
        // A launch window's task keeps its launch data after it became a window (LaunchWindows): its activity says.
        java.util.Set<Integer> kept = new java.util.HashSet<>(LaunchWindows.taskIds());
        for (PowosWindowActivity a : tasks.values())
            kept.add(a.getTaskId());
        java.util.Set<Integer> seen = new java.util.HashSet<>();
        for (android.app.ActivityManager.AppTask t : am.getAppTasks()) {
            android.app.ActivityManager.RecentTaskInfo info;
            try {
                info = t.getTaskInfo();
            } catch (IllegalArgumentException e) {
                continue; // gone meanwhile
            }
            Intent base = info.baseIntent;
            Uri data = base != null ? base.getData() : null;
            if (data == null || !"powos-window".equals(data.getScheme()) || kept.contains(info.taskId))
                continue;
            int id = PowosWindowActivity.idOf(data);
            // One task per live window: a second (a duplicate "open" before this fix, kept by Recents) goes too.
            boolean dup = tasks.containsKey(id) || !seen.add(id);
            if (current.equals(PowosWindowActivity.sessionOf(data)) && live.contains(id) && !dup)
                continue;
            Log.i(TAG, "task " + info.taskId + " (window " + id + " of session " + PowosWindowActivity.sessionOf(data) + "): not this KWin's, finished");
            t.finishAndRemoveTask();
        }
    }

    /** One of the app ids [ids] has a window task now (a launch brings that back: no launch window). */
    public static boolean hasWindow(String[] ids) {
        for (PowosWindowActivity a : tasks.values())
            if (a.live() && LaunchWindows.matches(ids, a.getIntent().getStringExtra(PowosWindowActivity.EXTRA_APP_ID)))
                return true;
        return false;
    }

    /** The PowOS app id (desktop id / app id KWin gave "open") of the window shown in Android task [taskId], or null. */
    public static String appIdOfTask(int taskId) {
        for (PowosWindowActivity a : tasks.values())
            // HACK: no a.live() here (added by 1437a4b5): this names the app a window SHOWS (the dock's listing), not
            // whether the launcher may reuse it; a task that failed live() lost its app key, so dockTap's front filter
            // (desktops.ts) dropped a front Kate and the tap launched instead of minimising. Real fix: prove why live()
            // is false for a shown window (f240 evidence in e2e-desktop.sh put_away).
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
