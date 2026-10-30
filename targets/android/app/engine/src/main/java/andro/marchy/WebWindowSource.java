package andro.marchy;

import android.app.Activity;
import android.content.Context;
import android.util.Log;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.ViewGroup;

import java.lang.ref.WeakReference;

import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * PowOS: a Linux (KWin) window as a WEB WINDOW of home - the same window component as an Android app's
 * (docs/WEB_WINDOWS.md S6, the app module's shell/WebWindows.kt) - instead of a PowosWindowActivity task of its own.
 *
 * KWin exports each toplevel as a per-window buffer stream (the display daemon's surface [id], kwin 0013): today it
 * goes to a PowosWindowActivity's SurfaceView. With a [Host] (home, web windows on, unfolded) KWin's "open" goes to the
 * host instead ([offer]); the host makes a SurfaceControl in the window's container and starts the same consumer on
 * a Surface of it ([start]): pixels, input ([touch]), size ([size]), focus and quit go over the existing calls, so a
 * KWin of any version that exports windows works unchanged. No host, or the host declines: the task path, as before.
 *
 * The control channel's thread calls [offer], [title], [closed], [session]; the host answers on its own thread.
 */
public final class WebWindowSource {
    private static final String TAG = "WebWindowSource";

    static {
        // The consumer's natives (Native.*): loaded by MainActivity / PowosWindowActivity too, idempotent.
        System.loadLibrary("andromarchy_consumer");
    }

    /** Home's web windows: where KWin's windows go while it [wants] them. */
    public interface Host {
        /** Web windows take Linux windows now (the setting on, the unfolded home showing). Any thread, fast. */
        boolean wants();

        /** KWin opened (or showed again) window [id] of app [appId], caption [title]. Called only when [wants]. */
        void open(int id, String appId, String title);

        /** Window [id]'s caption changed. */
        void title(int id, String title);

        /** KWin closed window [id] (the app closed it, or it exited). */
        void closed(int id);

        /**
         * Window [id] is full screen now ([on]) or not: KWin's "fullscreen <id> 1|0" - the answer to [fullScreen], or
         * the window's own (F11, a video). Control channel's thread.
         */
        default void fullScreen(int id, boolean on) {}

        /** Window [id] draws its own complete frame ([own]: no PowOS bar over it) or not (kwin 0046 "decor ... own"). */
        default void ownFrame(int id, boolean own) {}

        /**
         * Window [id]'s own frame was dragged (kwin 0046 "moveresize"): [edges] "move" or the edges its resize drags
         * ("n", "se", ...). The touch that did it goes on moving the web window's frame. Control channel's thread.
         */
        default void moveResize(int id, String edges) {}

        /** Window [id]'s own frame's "maximize" or "minimize" button (or its double click). Control channel's thread. */
        default void control(int id, String action) {}
    }

    /** Set by home's bridge (ShellBridge) while it lives; null = every Linux window is a task (as before). */
    public static volatile Host host;

    /** The KWin window ids that are web windows now ([offer] .. [closed] / [fallback]). */
    private static final Set<Integer> ids = ConcurrentHashMap.newKeySet();

    private WebWindowSource() {}

    /** Web windows want Linux windows now: a launcher tap opens no launch window task (Runtime.openRooted). */
    public static boolean wanted() {
        Host h = host;
        // A KWin without "size" (before kwin 0018) lays a window out at its buffers' size (the screen's): no web window.
        return h != null && WindowTasks.kwinCan("size") && h.wants();
    }

    static void ownFrame(int id, boolean own) {
        Host h = host;
        if (h != null && ids.contains(id))
            h.ownFrame(id, own);
    }

    static void moveResize(int id, String edges) {
        Host h = host;
        if (h != null && ids.contains(id))
            h.moveResize(id, edges);
    }

    static void control(int id, String action) {
        Host h = host;
        if (h != null && ids.contains(id))
            h.control(id, action);
    }

    /** Window [id] draws its own complete frame (KWin's "decor <id> 0 own"; told before its "open"). */
    public static boolean ownFrame(int id) {
        return WindowTasks.drawsOwnFrame(id);
    }

    /** KWin's "open" for window [id]: true = the host took it (no task). Control channel's thread. */
    static boolean offer(int id, String appId, String title) {
        Host h = host;
        if (h == null || !WindowTasks.kwinCan("size") || !h.wants())
            return false;
        ids.add(id);
        Log.i(TAG, "open " + id + " (" + appId + "): a web window");
        h.open(id, appId, title);
        return true;
    }

    /** The web windows' ids shown full screen now ([shownFullScreen]): they cover every other web window. */
    private static final Set<Integer> full = ConcurrentHashMap.newKeySet();

    /** The host shows window [id] full screen ([on]) or not: a new window of its app opens as a task over it. */
    public static void shownFullScreen(int id, boolean on) {
        if (on)
            full.add(id);
        else
            full.remove(id);
    }

    /** Window [id] is a web window shown full screen (over every other web window). */
    static boolean coversScreen(int id) {
        return ids.contains(id) && full.contains(id);
    }

    /** Window [id] is a web window's (its control lines go to the host). */
    static boolean isWeb(int id) {
        return ids.contains(id);
    }

    static void title(int id, String title) {
        Host h = host;
        if (h != null && ids.contains(id))
            h.title(id, title);
    }

    /** KWin's "close" for a web window's [id]. */
    static void closed(int id) {
        ids.remove(id);
        full.remove(id);
        Host h = host;
        if (h != null)
            h.closed(id);
    }

    /** A new KWin ([live]: its windows): every web window of another is gone. */
    static void session(Set<Integer> live) {
        for (Integer id : ids.toArray(new Integer[0]))
            if (!live.contains(id)) {
                Log.i(TAG, "window " + id + ": not the running KWin's, its web window goes");
                closed(id);
            }
    }

    /**
     * The host could not show window [id] after all (no page took it, home went): it opens as its own task, the way it
     * would have without web windows. Any thread.
     */
    public static void fallback(Context context, int id, String appId, String title) {
        ids.remove(id);
        full.remove(id);
        Log.i(TAG, "window " + id + " (" + appId + "): no web window for it, a task instead");
        WindowTasks.openAsTask(context.getApplicationContext(), id, appId, title);
    }

    /** The consumer's daemon connection (also when the desktop never opened in this process). */
    public static void configure(Context context) {
        MainActivity.configureConsumer(context);
    }

    /**
     * The consumer for window [id] on [surface], buffers [buffersW] x [buffersH] (the screen's: a resize needs no new
     * ones). The handle, 0 = failed. Blocks (a daemon connect): never on the main thread.
     */
    public static long start(Surface surface, int id, int buffersW, int buffersH) {
        long handle = Native.nativeStartWindow(surface, id, buffersW, buffersH);
        if (handle != 0) {
            synchronized (IME_LOCK) {
                liveHandles.add(handle);
            }
        }
        return handle;
    }

    /** The part of the buffers shown: the window's body size (KWin draws the window from their top left). */
    public static void crop(long handle, int width, int height) {
        if (handle != 0)
            Native.nativeSetWindowCrop(handle, width, height);
    }

    public static void refreshRate(long handle, float hz) {
        if (handle != 0 && hz > 0)
            Native.nativeSetWindowRefreshRate(handle, hz);
    }

    /** Joins the consumer's thread: never on the main thread. */
    public static void stop(long handle) {
        if (handle == 0)
            return;
        // Home's keyboard bound to it lets go first: no text is sent to a freed consumer.
        boolean bound;
        synchronized (IME_LOCK) {
            liveHandles.remove(handle);
            bound = imeHandle == handle;
            if (bound)
                imeHandle = 0;
        }
        if (bound)
            onUi(() -> {
                SystemIME i = ime;
                if (i != null && i.ownsKeyboard())
                    i.hideKeyboard();
            });
        Native.nativeStopWindow(handle);
    }

    /**
     * KWin (cap window-ime, kwin 0043) gives window [id]'s keyboard to its consumer [handle]: show/hide arrive on it
     * ([nativeKeyboard]) and home's keyboard types into it. After [start]; older KWin: nothing, the desktop's path.
     */
    public static void ownKeyboard(int id, long handle) {
        if (handle != 0 && WindowTasks.kwinCan("window-ime"))
            WindowTasks.sendLine("ime\t" + id + "\t1");
    }

    // ---- The Android keyboard for Linux web windows (kwin 0043, docs/WEB_WINDOWS.md 3.1) ----

    private static final Object IME_LOCK = new Object();
    /** Home's activity, hosting the keyboard (ShellBridge, home only). */
    private static volatile WeakReference<Activity> imeHome;
    /** The keyboard's hidden input in home (made on the first show, main thread only). */
    private static SystemIME ime;
    private static Activity imeActivity;
    /** The consumer the keyboard types into now (0: none). Guarded by IME_LOCK for sends vs [stop]. */
    private static long imeHandle;
    /** Consumers between [start] and [stop] (IME_LOCK): a show that arrives late never binds a stopped one. */
    private static final Set<Long> liveHandles = new java.util.HashSet<>();

    /** Home's bridge: [home] hosts Linux web windows' keyboard ([nativeKeyboard]). null when it goes. */
    public static void hostIme(Activity home) {
        imeHome = home == null ? null : new WeakReference<>(home);
    }

    /** [home]'s bridge went: it hosts the keyboard no more (a newer home's registration is kept). */
    public static void unhostIme(Activity home) {
        WeakReference<Activity> ref = imeHome;
        if (ref != null && ref.get() == home)
            imeHome = null;
    }

    /** Text and keys of home's keyboard: to the bound window's consumer, on its own connection. */
    private static final SystemIME.Sink WINDOW_SINK = new SystemIME.Sink() {
        @Override
        public void text(byte[] utf8) {
            synchronized (IME_LOCK) {
                if (imeHandle != 0)
                    Native.nativeSendWindowTextInput(imeHandle, utf8);
            }
        }

        @Override
        public void key(int action, int evdevCode) {
            synchronized (IME_LOCK) {
                if (imeHandle != 0)
                    Native.nativeSendWindowKey(imeHandle, action, evdevCode);
            }
        }
    };

    private static void onUi(Runnable r) {
        WeakReference<Activity> ref = imeHome;
        Activity a = ref == null ? null : ref.get();
        if (a != null)
            a.runOnUiThread(r);
    }

    /**
     * Called by native_consumer.c's window event thread: KWin's OUTPUT_TYPE_KEYBOARD on window consumer [handle] (a
     * Linux text field in that web window gained / lost the focus). Name and signature are fixed by the JNI side.
     */
    static void nativeKeyboard(long handle, boolean visible) {
        WeakReference<Activity> ref = imeHome;
        Activity a = ref == null ? null : ref.get();
        if (a == null) {
            Log.w(TAG, "keyboard " + (visible ? "show" : "hide") + " for a web window: no home to host it");
            return;
        }
        a.runOnUiThread(() -> keyboard(a, handle, visible));
    }

    /** Main thread: [nativeKeyboard]'s show or hide. */
    private static void keyboard(Activity a, long handle, boolean visible) {
        if (visible) {
            SystemIME i = imeFor(a);
            if (i == null)
                return;
            synchronized (IME_LOCK) {
                if (!liveHandles.contains(handle))
                    return;
                imeHandle = handle;
            }
            Log.i(TAG, "keyboard up for a web window (its consumer types)");
            i.showKeyboard();
            return;
        }
        boolean bound;
        synchronized (IME_LOCK) {
            bound = imeHandle == handle;
            if (bound)
                imeHandle = 0;
        }
        SystemIME i = ime;
        // Only ours: home's own page may have the keyboard now (the user tapped the launcher's search).
        if (bound && i != null && i.ownsKeyboard()) {
            Log.i(TAG, "keyboard down for a web window");
            i.hideKeyboard();
        }
    }

    /** Home's keyboard input, made once per activity: a 1x1 hidden view on its decor (as MainActivity's). */
    private static SystemIME imeFor(Activity a) {
        if (ime != null && imeActivity == a)
            return ime;
        if (ime != null) {
            android.view.View old = ime.getInputView();
            if (old.getParent() instanceof ViewGroup)
                ((ViewGroup) old.getParent()).removeView(old);
        }
        android.view.View decor = a.getWindow() == null ? null : a.getWindow().getDecorView();
        if (!(decor instanceof ViewGroup)) {
            Log.w(TAG, "home has no decor view for the keyboard's input");
            return null;
        }
        SystemIME i = new SystemIME(a, new SystemIME.Host() {
            @Override
            public ExtraKeysBar getExtraKeysBar() {
                return null;
            }

            @Override
            public void onImeVisibilityChanged(boolean visible) {}
        }, WINDOW_SINK);
        ((ViewGroup) decor).addView(i.getInputView(), new ViewGroup.LayoutParams(1, 1));
        ime = i;
        imeActivity = a;
        return i;
    }

    // ---- Full screen for Linux web windows (kwin 0043 "fullscreen-request") ----

    /** KWin puts a web window's window itself full screen on request ([fullScreen]). */
    public static boolean canFullScreen() {
        return WindowTasks.kwinCan("fullscreen-request");
    }

    /** Window [id] full screen ([on]) or back: KWin calls setFullScreen; its "fullscreen <id> 1|0" answers. */
    public static void fullScreen(int id, boolean on) {
        if (canFullScreen())
            WindowTasks.sendLine("fullscreen\t" + id + "\t" + (on ? 1 : 0));
    }

    /** KWin's "fullscreen <id> 1|0" for a web window's [id]. Control channel's thread. */
    static void fullScreened(int id, boolean on) {
        Host h = host;
        if (h != null && ids.contains(id))
            h.fullScreen(id, on);
    }

    /** KWin resizes window [id] to [width] x [height] px (its client: PowOS draws the bar). Older KWin: nothing. */
    public static void size(int id, int width, int height) {
        if (WindowTasks.kwinCan("size"))
            WindowTasks.sendLine("size\t" + id + "\t" + width + "\t" + height);
    }

    /** Window [id] has the focus (a touch on it): KWin activates it; the clipboard goes to the session. */
    public static void focus(int id) {
        WindowTasks.send("focus", id);
        Runnable hook = PowosWindowActivity.focusHook;
        if (hook != null)
            hook.run();
    }

    /** Its close button: KWin closes the window, then ends the app if it stays (kwin 0041 "quit"; older: "closed"). */
    public static void quit(Context context, int id) {
        ids.remove(id);
        full.remove(id);
        WindowTasks.quit(context.getApplicationContext(), id);
    }

    private static final int MAX_POINTERS = 10;

    /**
     * Every pointer of [e] to window [handle] (protocol.h DOWN 0 / UP 1 / MOVE 2, then a frame), as PowosWindowActivity
     * sends a task's: pointer i at ((getX(i) + dx) / scale, (getY(i) + dy) / scale) - the body's own px.
     */
    public static void touch(long handle, MotionEvent e, float dx, float dy, float scale) {
        if (handle == 0)
            return;
        int masked = e.getActionMasked();
        int index = e.getActionIndex();
        for (int i = 0; i < e.getPointerCount(); i++) {
            int action;
            if (masked == MotionEvent.ACTION_MOVE)
                action = 2;
            else if (masked == MotionEvent.ACTION_CANCEL)
                action = 1;
            else if (i != index)
                continue;
            else if (masked == MotionEvent.ACTION_DOWN || masked == MotionEvent.ACTION_POINTER_DOWN)
                action = 0;
            else if (masked == MotionEvent.ACTION_UP || masked == MotionEvent.ACTION_POINTER_UP)
                action = 1;
            else
                continue;
            int id = e.getPointerId(i);
            if (id >= MAX_POINTERS)
                continue;
            Native.nativeSendWindowTouch(handle, action, (e.getX(i) + dx) / scale, (e.getY(i) + dy) / scale, id);
        }
        Native.nativeSendWindowTouchFrame(handle);
    }
}
