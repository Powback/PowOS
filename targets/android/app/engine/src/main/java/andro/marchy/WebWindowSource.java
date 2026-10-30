package andro.marchy;

import android.content.Context;
import android.util.Log;
import android.view.MotionEvent;
import android.view.Surface;

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
        return Native.nativeStartWindow(surface, id, buffersW, buffersH);
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
        if (handle != 0)
            Native.nativeStopWindow(handle);
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
