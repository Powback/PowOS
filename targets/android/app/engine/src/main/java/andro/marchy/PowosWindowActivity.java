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
    /** KWin closed the window: nothing to hand back on finishing. */
    private boolean closedByKWin;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        id = parseId();
        if (id <= 0) {
            finish();
            return;
        }
        WindowTasks.tasks.put(id, this);
        SurfaceView view = new SurfaceView(this);
        view.setFocusable(true);
        view.setFocusableInTouchMode(true);
        view.getHolder().addCallback(this);
        view.setOnTouchListener((v, e) -> {
            sendTouch(e);
            return true;
        });
        setContentView(view);
        view.requestFocus();
        if (getIntent().getBooleanExtra(EXTRA_FULLSCREEN, false))
            immersive();
        setTitleText(getIntent().getStringExtra(EXTRA_TITLE));
    }

    private int parseId() {
        try {
            return getIntent().getData() != null ? Integer.parseInt(getIntent().getData().getHost()) : 0;
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /** A full-screen application (a game, Steam Big Picture): the whole screen, system bars only on a swipe. */
    private void immersive() {
        getWindow().getAttributes().layoutInDisplayCutoutMode =
                android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        getWindow().setDecorFitsSystemWindows(false);
        android.view.WindowInsetsController c = getWindow().getInsetsController();
        if (c != null) {
            c.hide(android.view.WindowInsets.Type.systemBars());
            c.setSystemBarsBehavior(android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
    }

    /** The task's label (the window's caption) and icon (the app's, as PowOS shows it: powos-apps-export). */
    void setTitleText(String title) {
        String appId = getIntent().getStringExtra(EXTRA_APP_ID);
        Bitmap icon = null;
        if (appId != null && !appId.isEmpty()) {
            File png = new File(SessionService.runDir(this), "powos-apps/icons/" + appId + ".png");
            if (png.isFile())
                icon = BitmapFactory.decodeFile(png.getPath());
        }
        setTaskDescription(new ActivityManager.TaskDescription(title == null || title.isEmpty() ? null : title, icon));
    }

    /** The size of the consumer's buffers (buffersFor), while [handle] is set. */
    private int buffersW;
    private int buffersH;

    /** KWin closed the window ("close"). */
    void closedByKWin() {
        closedByKWin = true;
        finishAndRemoveTask();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
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
        // A window's buffers are the screen's size (a full-screen application's: the surface's - KWin scales it to
        // fit them). A new size inside them - a floating window resized, step by step while its frame is dragged - is
        // no new buffers: KWin resizes the window to it ("size", the client lays itself out and commits) and the
        // surface shows that part of them, 1:1 from the top left (the crop) - live, never stretched. Buffers of
        // another size (rotation, fold, full screen) reconnect.
        int[] buffers = buffersFor(width, height);
        if (WindowTasks.kwinCan("size"))
            WindowTasks.sendLine("size\t" + id + "\t" + width + "\t" + height);
        long running = handle;
        if (running != 0 && buffers[0] == buffersW && buffers[1] == buffersH) {
            Native.nativeSetWindowCrop(running, width, height);
            return;
        }
        Log.i(TAG, "surface " + id + ": " + width + "x" + height + " in " + buffers[0] + "x" + buffers[1]);
        stopConsumer();
        long h = Native.nativeStartWindow(holder.getSurface(), id, buffers[0], buffers[1]);
        if (h == 0) {
            Log.e(TAG, "window consumer did not start");
            return;
        }
        Native.nativeSetWindowCrop(h, width, height);
        if (getDisplay() != null)
            Native.nativeSetWindowRefreshRate(h, getDisplay().getRefreshRate());
        buffersW = buffers[0];
        buffersH = buffers[1];
        handle = h;
    }

    /** The consumer's buffer size for a surface of [width] x [height]: the screen's (as large as it can get). */
    private int[] buffersFor(int width, int height) {
        // An older KWin (no "size") fits the window to the buffers: the surface's size, as before.
        if (getIntent().getBooleanExtra(EXTRA_FULLSCREEN, false) || !WindowTasks.kwinCan("size"))
            return new int[] {width, height};
        android.graphics.Rect max = getWindowManager().getMaximumWindowMetrics().getBounds();
        return new int[] {Math.max(width, max.width()), Math.max(height, max.height())};
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        stopConsumer();
    }

    private void stopConsumer() {
        long h = handle;
        handle = 0;
        if (h != 0)
            Native.nativeStopWindow(h);
    }

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
        stopConsumer();
        if (id > 0) {
            WindowTasks.tasks.remove(id, this);
            // Closed for good (swiped from Recents, Back): KWin shows the window on the desktop again.
            if (isFinishing() && !closedByKWin)
                WindowTasks.closed(this, id);
        }
        super.onDestroy();
    }
}
