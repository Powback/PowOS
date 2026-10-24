package andro.marchy;

import android.app.Activity;
import android.app.ActivityManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Bundle;
import android.util.Log;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import java.io.File;

/**
 * PowOS: a PowOS (KWin) window as its own Android task - its own card in Recents, split screen and floating windows
 * (docs/powos-window-tasks.md). KWin exports the window to this activity's surface: the display daemon's surface
 * {@code id} (the intent's data, powos-window://id - a document task per window), pixels and input only; audio,
 * clipboard and the keyboard stay with the desktop (MainActivity).
 *
 * Started and finished by KWin over the control channel (WindowTasks: "open", "close"); tells it when it gets the
 * focus (KWin activates the window) and when it is closed for good (KWin shows the window on the desktop again).
 *
 * A launch window (LaunchWindows: powos-window://launch, opened at the tap on the app) shows the app's icon and name
 * until KWin opens the app's window, which it then becomes ([become]): the same task, where it already is.
 */
public class PowosWindowActivity extends Activity implements SurfaceHolder.Callback {
    private static final String TAG = "PowosWindow";
    static final String EXTRA_TITLE = "title";
    static final String EXTRA_APP_ID = "app_id";
    static final String EXTRA_FULLSCREEN = "fullscreen";

    static {
        System.loadLibrary("andromarchy_consumer");
    }

    private int id;
    /** The consumer (Native.nativeStartWindow), 0 while none: input is only sent while it's set. */
    private volatile long handle;
    /**
     * KWin closed the window, or the task is an earlier KWin's (staleSession): nothing to hand back on finishing - its
     * id may be another window's of the running KWin. Set from the control thread, read on finishing.
     */
    private volatile boolean closedByKWin;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        // A launch window that became a window ([become]), recreated (the app restarted): Android gives back the launch
        // intent, so the window's own data comes from the saved state; one recreated before its window came is over.
        String saved = state != null ? state.getString(STATE_WINDOW) : null;
        android.net.Uri became = saved != null ? android.net.Uri.parse(saved) : null;
        if (became != null)
            setIntent(new android.content.Intent(getIntent()).setData(became).putExtra(EXTRA_APP_ID, state.getString(EXTRA_APP_ID)));
        else if (state != null && LaunchWindows.isLaunch(getIntent().getData())) {
            finishAndRemoveTask();
            return;
        }
        id = parseId();
        if (id <= 0 && LaunchWindows.isLaunch(getIntent().getData())) {
            // Opened at the tap (LaunchWindows): the app's icon and name until its window comes ([become]).
            LaunchWindows.add(this);
            content(true);
            setTitleText(getIntent().getStringExtra(EXTRA_TITLE));
            return;
        }
        if (id <= 0) {
            finish();
            return;
        }
        String running = WindowTasks.session;
        if (running != null && !ofSession(running)) {
            // A card of an earlier KWin's window (Recents kept it through a session restart): that window is gone.
            Log.i(TAG, "window " + id + " is an earlier KWin's (session " + sessionOf(getIntent().getData()) + "): finished");
            closedByKWin = true;
            finishAndRemoveTask();
            return;
        }
        WindowTasks.tasks.put(id, this);
        // The consumer's daemon connection, also when the desktop (MainActivity, which set it before) never opened.
        MainActivity.configureConsumer(this);
        content(false);
        if (getIntent().getBooleanExtra(EXTRA_FULLSCREEN, false))
            immersive();
        setTitleText(getIntent().getStringExtra(EXTRA_TITLE));
    }

    /** The window's surface (KWin's pixels, its touches to KWin) - under a [splash] for a launch window. */
    private void content(boolean launch) {
        SurfaceView view = new SurfaceView(this);
        view.setFocusable(true);
        view.setFocusableInTouchMode(true);
        view.getHolder().addCallback(this);
        view.setOnTouchListener((v, e) -> {
            touch(e);
            return true;
        });
        if (launch) {
            android.widget.FrameLayout root = new android.widget.FrameLayout(this);
            root.addView(view);
            splash = LaunchWindows.splash(this, getIntent().getStringExtra(EXTRA_TITLE), icon());
            root.addView(splash);
            setContentView(root);
        } else {
            setContentView(view);
        }
        view.requestFocus();
    }

    private static final String STATE_WINDOW = "powos_window";

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        // A launch window that became window [id]: its window's data, for a recreation from the launch intent (onCreate).
        if (id > 0 && LaunchWindows.isLaunch(baseData())) {
            out.putString(STATE_WINDOW, String.valueOf(getIntent().getData()));
            out.putString(EXTRA_APP_ID, getIntent().getStringExtra(EXTRA_APP_ID));
        }
    }

    /** The data this task was started with (a launch window keeps its launch data after [become]). */
    private android.net.Uri baseData() {
        ActivityManager am = getSystemService(ActivityManager.class);
        if (am != null)
            for (ActivityManager.AppTask t : am.getAppTasks()) {
                try {
                    ActivityManager.RecentTaskInfo info = t.getTaskInfo();
                    if (info.taskId == getTaskId() && info.baseIntent != null)
                        return info.baseIntent.getData();
                } catch (IllegalArgumentException e) {
                    // gone meanwhile
                }
            }
        return null;
    }

    /** A launch window's icon and name over the surface until the window's first frames are there ([started]). */
    private android.view.View splash;

    /**
     * The launch window becomes window [windowId] (KWin's "open" for its app: [data], [appId], [title]) - in this task,
     * where it is: registered, the consumer on the surface it has, the splash gone once that runs. [orElse] if this
     * activity is finishing meanwhile (closed by hand): the window opens in a task of its own after all. Main thread.
     */
    void become(int windowId, android.net.Uri data, String appId, String title, Runnable orElse) {
        if (isFinishing() || isDestroyed()) {
            orElse.run();
            return;
        }
        setIntent(new android.content.Intent(getIntent()).setData(data).putExtra(EXTRA_APP_ID, appId).putExtra(EXTRA_TITLE, title));
        id = windowId;
        WindowTasks.tasks.put(id, this);
        MainActivity.configureConsumer(this);
        setTitleText(title);
        Log.i(TAG, "launch window: now window " + id + " (" + appId + ")");
        if (holder != null && cropW > 0 && cropH > 0)
            surfaceChanged(holder, 0, cropW, cropH);
        // Its frame again: the bar may go (a window with its own title bar, "decor 0").
        Runnable r = WindowTasks.barChanged;
        if (r != null)
            r.run();
    }

    /** The app's launch ended with no window for this launch window (LaunchWindows.done): it goes. */
    void launchEnded() {
        if (id <= 0)
            finishAndRemoveTask();
    }

    /** The splash off, faded, a moment after the consumer is up (its first frames on the surface). */
    private void dropSplash() {
        android.view.View s = splash;
        if (s == null)
            return;
        splash = null;
        s.animate().alpha(0f).setStartDelay(LaunchWindows.SPLASH_HOLD_MS).setDuration(LaunchWindows.SPLASH_FADE_MS)
                .withEndAction(() -> ((android.view.ViewGroup) s.getParent()).removeView(s)).start();
    }

    private int parseId() {
        return idOf(getIntent().getData());
    }

    /** The window id in a window task's data (powos-window://id?session=uuid), 0 if none. */
    static int idOf(android.net.Uri data) {
        try {
            return data != null && data.getHost() != null ? Integer.parseInt(data.getHost()) : 0;
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /** The KWin session in a window task's data, "" for none (an older KWin's, or one from before sessions). */
    static String sessionOf(android.net.Uri data) {
        String s = data != null && data.isHierarchical() ? data.getQueryParameter("session") : null;
        return s != null ? s : "";
    }

    int windowId() {
        return id;
    }

    /** This task shows a window of KWin session [session]. */
    boolean ofSession(String session) {
        return session.equals(sessionOf(getIntent().getData()));
    }

    /**
     * A window of the running KWin, still shown: not finishing, and of its session (when it says one) - what the
     * launcher and dock may bring back instead of opening the app.
     */
    boolean live() {
        String running = WindowTasks.session;
        return !isFinishing() && !closedByKWin && (running == null || ofSession(running));
    }

    /** An earlier KWin's window (WindowTasks.finishStale): the task goes, telling KWin nothing (callable from any thread). */
    void staleSession() {
        closedByKWin = true;
        Log.i(TAG, "window " + id + ": not the running KWin's, finished");
        runOnUiThread(this::finishAndRemoveTask);
    }

    /** A full-screen application (a game, Steam Big Picture): the whole screen, system bars only on a swipe. */
    private void immersive() {
        immersive(true);
    }

    /** System bars hidden (only on a swipe) and the content under them and the cutout [on], or back as a window's. */
    private void immersive(boolean on) {
        android.view.WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.layoutInDisplayCutoutMode = on ? android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                : android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT;
        getWindow().setAttributes(lp);
        getWindow().setDecorFitsSystemWindows(!on);
        // A full-screen application (a game played with a controller, a video) keeps the screen on while its task
        // shows, as Android games do: a controller's input goes to Linux, never Android's user-activity timer, so the
        // screen timed out mid-game - the task's surface went with it and KWin stopped drawing the game.
        if (on)
            getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else
            getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        android.view.WindowInsetsController c = getWindow().getInsetsController();
        if (c == null)
            return;
        if (on) {
            c.hide(android.view.WindowInsets.Type.systemBars());
            c.setSystemBarsBehavior(android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        } else {
            c.show(android.view.WindowInsets.Type.systemBars());
        }
    }

    /**
     * The window's application went full screen by itself while it floats ([on]; KWin's "fullscreen"), or left it:
     * immersive, and the task over the whole screen - then a floating window again at its bounds before
     * (WindowTasks.fullScreenTask: the app module's frames, which own the floating windows).
     */
    void appFullScreen(boolean on) {
        immersive(on);
        java.util.function.BiConsumer<Integer, Boolean> f = WindowTasks.fullScreenTask;
        if (f != null)
            f.accept(getTaskId(), on);
    }

    /** The task's label (the window's caption) and icon (the app's, as PowOS shows it: powos-apps-export). */
    void setTitleText(String title) {
        setTaskDescription(new ActivityManager.TaskDescription(title == null || title.isEmpty() ? null : title, icon()));
    }

    /** The app's icon as PowOS shows it (powos-apps-export), null if none. */
    private Bitmap icon() {
        String appId = getIntent().getStringExtra(EXTRA_APP_ID);
        if (appId == null || appId.isEmpty())
            return null;
        File png = new File(SessionService.runDir(this), "powos-apps/icons/" + appId + ".png");
        return png.isFile() ? BitmapFactory.decodeFile(png.getPath()) : null;
    }

    /** The size of the consumer's buffers (buffersFor), while [handle] is set. */
    private int buffersW;
    private int buffersH;

    /** KWin closed the window ("close"). */
    void closedByKWin() {
        closedByKWin = true;
        finishAndRemoveTask();
    }

    /** This window's task is the front one (Android's top resumed activity): a "show again" has nothing to raise. */
    private volatile boolean front;

    boolean inFront() {
        return front;
    }

    @Override
    public void onTopResumedActivityChanged(boolean isTop) {
        super.onTopResumedActivityChanged(isTop);
        front = isTop;
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && id > 0) {
            WindowTasks.send("focus", id);
            // PowOS: Android's clipboard to the session as this Linux window takes focus (the app can read it now;
            // the desktop's MainActivity does the same through KWin). Set by the app (PlasmaBridge.pushClip).
            Runnable hook = focusHook;
            if (hook != null)
                hook.run();
        }
    }

    /** Run as a Linux window's task gains focus (the app sets it: PlasmaBridge's clipboard push). */
    public static volatile Runnable focusHook;

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        this.holder = holder;
        if (id <= 0) {
            // A launch window: no window yet - the consumer starts on this surface once it has one ([become]).
            cropW = width;
            cropH = height;
            return;
        }
        // A window's buffers are the screen's size (a full-screen application's: the surface's - KWin scales it to
        // fit them). A new size inside them - a floating window resized, step by step while its frame is dragged - is
        // no new buffers: KWin resizes the window to it ("size", the client lays itself out and commits) and the
        // surface shows that part of them, 1:1 from the top left (the crop) - live, never stretched. Buffers of
        // another size (rotation, fold, full screen) reconnect.
        int[] buffers = buffersFor(width, height);
        if (WindowTasks.kwinCan("size"))
            WindowTasks.sendLine("size\t" + id + "\t" + width + "\t" + height);
        cropW = width;
        cropH = height;
        long running = handle;
        if ((running != 0 || starting) && buffers[0] == buffersW && buffers[1] == buffersH) {
            // Starting: the crop goes on as the consumer is there (started).
            if (running != 0)
                Native.nativeSetWindowCrop(running, width, height);
            return;
        }
        Log.i(TAG, "surface " + id + ": " + width + "x" + height + " in " + buffers[0] + "x" + buffers[1]);
        stopConsumer();
        final int gen = ++surfaceGen;
        final android.view.Surface surface = holder.getSurface();
        final float rate = getDisplay() != null ? getDisplay().getRefreshRate() : 0f;
        final int bw = buffers[0];
        final int bh = buffers[1];
        buffersW = bw;
        buffersH = bh;
        starting = true;
        onConsumerThread(() -> {
            // A newer surface (or none) by now: this one is not started at all.
            if (gen != surfaceGen)
                return;
            long h = Native.nativeStartWindow(surface, id, bw, bh);
            main.post(() -> started(gen, h, rate));
        });
    }

    /** The consumer for surface [gen] is up ([h], 0 = it failed): live, unless that surface is gone (main thread). */
    private void started(int gen, long h, float rate) {
        if (gen != surfaceGen || isDestroyed()) {
            if (h != 0)
                stopLater(h);
            return;
        }
        starting = false;
        if (h == 0) {
            Log.e(TAG, "window consumer did not start");
            return;
        }
        Native.nativeSetWindowCrop(h, cropW, cropH);
        if (rate > 0)
            Native.nativeSetWindowRefreshRate(h, rate);
        handle = h;
        dropSplash();
    }

    /** The consumer's buffer size for a surface of [width] x [height]: the screen's (as large as it can get). */
    private int[] buffersFor(int width, int height) {
        // An older KWin (no "size") fits the window to the buffers: the surface's size, as before.
        if (getIntent().getBooleanExtra(EXTRA_FULLSCREEN, false) || !WindowTasks.kwinCan("size"))
            return new int[] {width, height};
        android.graphics.Rect max = getWindowManager().getMaximumWindowMetrics().getBounds();
        return new int[] {Math.max(width, max.width()), Math.max(height, max.height())};
    }

    /** The surface now (surfaceChanged), null once it's gone: a launch window's consumer starts on it ([become]). */
    private SurfaceHolder holder;

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        this.holder = null;
        surfaceGen++;
        stopConsumer();
    }

    /** The consumer off: input stops at once (main thread), the consumer itself stops on its own thread. */
    private void stopConsumer() {
        long h = handle;
        handle = 0;
        starting = false;
        if (h != 0)
            stopLater(h);
    }

    private void stopLater(long h) {
        onConsumerThread(() -> Native.nativeStopWindow(h));
    }

    /**
     * The consumer's starts and stops, off the main thread, one at a time and in order (a stop before the next start on
     * a surface: one producer connection at a time). A stop joins the consumer's render thread, which can sit in a
     * daemon connect (polls of up to 30 s) or a buffer wait: on main that was an ANR (15:32, HomeShell's main thread in
     * Native.nativeStopWindow from surfaceDestroyed). After surfaceDestroyed the old consumer may touch its surface a
     * moment longer: it holds its own ANativeWindow reference, and an abandoned surface only fails its calls.
     */
    private final java.util.concurrent.ExecutorService consumerThread =
            java.util.concurrent.Executors.newSingleThreadExecutor(r -> new Thread(r, "PowosWindow consumer"));

    private void onConsumerThread(Runnable r) {
        try {
            consumerThread.execute(r);
        } catch (java.util.concurrent.RejectedExecutionException e) {
            // After onDestroy (a surface callback late): its own thread, still off main.
            new Thread(r, "PowosWindow consumer (late)").start();
        }
    }

    private final android.os.Handler main = new android.os.Handler(android.os.Looper.getMainLooper());
    /** The surface the consumer is for; bumped as it changes or goes, so a start for an older one never goes live. */
    private volatile int surfaceGen;
    /** A start is on its way for buffers [buffersW] x [buffersH] (main thread). */
    private boolean starting;
    /** The surface's size now: the consumer's crop (main thread). */
    private int cropW;
    private int cropH;

    /** A finger is on the window (from a DOWN to the last pointer's lift). */
    private boolean touching;
    /** KWin's "move" came: the rest of this touch moves the task ([moveTask]), not the window's content. */
    private boolean moving;

    /** A touch on the window: to KWin, or - once the window's own title bar asked to be moved ([appMove]) - to its task. */
    private void touch(MotionEvent e) {
        int a = e.getActionMasked();
        if (a == MotionEvent.ACTION_DOWN)
            touching = true;
        boolean last = a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_CANCEL;
        if (moving)
            moveTask(e, last);
        else
            sendTouch(e);
        if (last)
            touching = false;
    }

    /**
     * The window's own title bar is being dragged (KWin's "move", kwin 0026: a client-side bar - Steam's - asked for a
     * move, which KWin cancelled): the rest of the touch moves the task. A "move" after the finger lifted is ignored.
     */
    void appMove() {
        if (!touching || moving)
            return;
        moving = true;
        liftAll();
    }

    /** [e] to the task's frame (WindowTasks.moveTask: the app's WindowFrames) until the lift ([last]). */
    private void moveTask(MotionEvent e, boolean last) {
        java.util.function.BiPredicate<Integer, MotionEvent> m = WindowTasks.moveTask;
        boolean took = m != null && m.test(getTaskId(), e);
        if (last || !took)
            moving = false;
        if (!took)
            Log.i(TAG, "window " + id + ": its title bar's move not taken (no frame)");
    }

    /** Every pointer KWin has lifted (its touch ends there; the window's own press is over). */
    private void liftAll() {
        long h = handle;
        if (h == 0)
            return;
        for (int p = 0; p < MAX_POINTERS; p++)
            Native.nativeSendWindowTouch(h, 1, 0f, 0f, p);
        Native.nativeSendWindowTouchFrame(h);
    }

    private static final int MAX_POINTERS = 10;

    /** Every pointer of [e] as the desktop sends them (protocol.h INPUT_ACTION_DOWN/UP/MOVE), then a frame. */
    private void sendTouch(MotionEvent e) {
        long h = handle;
        if (h == 0)
            return;
        int masked = e.getActionMasked();
        int index = e.getActionIndex();
        for (int i = 0; i < e.getPointerCount(); i++) {
            int action;
            if (masked == MotionEvent.ACTION_MOVE) {
                action = 2;
            } else if (masked == MotionEvent.ACTION_CANCEL) {
                action = 1; // every pointer lifts
            } else if (i != index) {
                continue;
            } else if (masked == MotionEvent.ACTION_DOWN || masked == MotionEvent.ACTION_POINTER_DOWN) {
                action = 0;
            } else if (masked == MotionEvent.ACTION_UP || masked == MotionEvent.ACTION_POINTER_UP) {
                action = 1;
            } else {
                continue;
            }
            Native.nativeSendWindowTouch(h, action, e.getX(i), e.getY(i), e.getPointerId(i));
        }
        Native.nativeSendWindowTouchFrame(h);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        long h = handle;
        int code = event.getKeyCode();
        if (h == 0 || code == KeyEvent.KEYCODE_BACK || code == KeyEvent.KEYCODE_VOLUME_UP
                || code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_HOME)
            return super.dispatchKeyEvent(event);
        if (event.getAction() != KeyEvent.ACTION_DOWN && event.getAction() != KeyEvent.ACTION_UP)
            return super.dispatchKeyEvent(event);
        int evdev = event.getScanCode() != 0 ? event.getScanCode() : KeyCodeMapper.getScanCode(code);
        if (evdev == -1)
            return super.dispatchKeyEvent(event);
        Native.nativeSendWindowKey(h, event.getAction() == KeyEvent.ACTION_DOWN ? 0 : 1, evdev);
        return true;
    }

    @Override
    protected void onDestroy() {
        LaunchWindows.remove(this);
        surfaceGen++;
        stopConsumer();
        consumerThread.shutdown();
        if (id > 0) {
            WindowTasks.tasks.remove(id, this);
            // Closed for good (swiped from Recents, Back): KWin shows the window on the desktop again.
            if (isFinishing() && !closedByKWin)
                WindowTasks.closed(this, id);
        }
        super.onDestroy();
    }
}
