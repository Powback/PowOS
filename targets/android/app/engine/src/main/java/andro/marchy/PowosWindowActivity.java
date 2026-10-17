package andro.marchy;

import android.app.Activity;
import android.app.ActivityManager;
import android.os.Bundle;
import android.util.Log;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

/**
 * PowOS: a PowOS (KWin) window as its own Android task - its own card in Recents, split screen and floating windows.
 * This activity's surface is KWin's output "anland-2": a consumer on the second display daemon
 * (SessionService.windowDaemonSocket, ANLAND_SOCKET_2 in the session), pixels and input only; audio, clipboard and
 * the keyboard stay with the desktop (MainActivity). KWin places the window on that output (a KWin script for now).
 *
 * Slice 1 of docs/powos-window-tasks.md: one such task (one second output), so singleTask in its own affinity.
 * Extra "title": the task's label.
 */
public class PowosWindowActivity extends Activity implements SurfaceHolder.Callback {
    private static final String TAG = "PowosWindow";
    public static final String EXTRA_TITLE = "title";

    static {
        System.loadLibrary("andromarchy_consumer");
    }

    /** The consumer (Native.nativeStartWindow), 0 while none: input is only sent while it's set. */
    private volatile long handle;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
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
        applyTitle();
    }

    @Override
    protected void onNewIntent(android.content.Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        applyTitle();
    }

    private void applyTitle() {
        String title = getIntent().getStringExtra(EXTRA_TITLE);
        if (title != null)
            setTaskDescription(new ActivityManager.TaskDescription(title));
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        // A new size (split screen, floating, fold) reconnects with buffers of that size; KWin resizes the output to
        // them (AnlandEglLayer).
        Log.i(TAG, "surfaceChanged: " + width + "x" + height);
        stopConsumer();
        long h = Native.nativeStartWindow(holder.getSurface(), SessionService.windowDaemonSocket(this).getPath());
        if (h == 0) {
            Log.e(TAG, "window consumer did not start");
            return;
        }
        if (getDisplay() != null)
            Native.nativeSetWindowRefreshRate(h, getDisplay().getRefreshRate());
        handle = h;
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
            } else if (i != index) {
                continue;
            } else if (masked == MotionEvent.ACTION_DOWN || masked == MotionEvent.ACTION_POINTER_DOWN) {
                action = 0;
            } else if (masked == MotionEvent.ACTION_UP || masked == MotionEvent.ACTION_POINTER_UP
                    || masked == MotionEvent.ACTION_CANCEL) {
                action = 1;
            } else {
                continue;
            }
            Native.nativeSendWindowTouch(h, action, e.getX(i), e.getY(i), e.getPointerId(i));
            if (masked == MotionEvent.ACTION_CANCEL)
                for (int j = 0; j < e.getPointerCount(); j++)
                    if (j != i)
                        Native.nativeSendWindowTouch(h, 1, e.getX(j), e.getY(j), e.getPointerId(j));
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
        super.onDestroy();
    }
}
