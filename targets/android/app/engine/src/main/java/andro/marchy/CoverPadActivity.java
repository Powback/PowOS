package andro.marchy;

import android.app.Activity;
import android.app.ActivityOptions;
import android.content.Intent;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.Looper;
import android.view.Display;
import android.view.HapticFeedbackConstants;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.Bundle;
import android.util.Log;
import android.util.SparseIntArray;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;

/**
 * The cover (outer) screen as a controller surface while the phone is unfolded - it faces away, under the fingers
 * holding the phone. Tracks up to six fingers, three per hand (index, middle, ring), and learns where each one
 * rests: every touch is assigned to the nearest finger slot, and each slot's centre drifts toward where that finger
 * actually touches, so the zones follow the user's grip over time.
 *
 * Fingers resting on the back only hold the phone; a finger that lifts and presses again within PRESS_WINDOW
 * presses its button and holds it until it lifts. Default buttons (Steam Deck controller, powos-padd): index ->
 * L4/R4, middle -> L5/R5, ring -> LB/RB.
 *
 * {@link #start} turns both screens on (device state ALL, via root) and opens this on the cover display; closing it,
 * or starting to fold the phone (hinge sensor), puts the device state back - a forced state would otherwise keep
 * the phone from switching screens when folded.
 */
public class CoverPadActivity extends Activity implements SensorEventListener {

    private static final String TAG = "CoverPad";
    /** Slot -> button: L index, L middle, L ring, R index, R middle, R ring. */
    static final int[] BUTTONS = {PadHub.L4, PadHub.L5, PadSender.LB, PadHub.R4, PadHub.R5, PadSender.RB};
    static final String[] BUTTON_NAMES = {"L4", "L5", "LB", "R4", "R5", "RB"};
    /** A press: the finger was off for PRESS_MIN..PRESS_MAX ms and came back within PRESS_RADIUS (fraction of the
     *  short side) of where it lifted. Regripping fingers bounce back within a few ms or land elsewhere. */
    static final long PRESS_MIN = 60, PRESS_MAX = 300;
    static final float PRESS_RADIUS = 0.06f;

    /** Game pad (six finger zones -> Deck buttons) or desktop (right half = trackpad, left fingers = mouse buttons). */
    static final int MODE_GAME = 0, MODE_DESKTOP = 1;
    static final String EXTRA_MODE = "mode";
    /** The display it was opened on (the cover panel) and the one it was opened from (the inner screen). */
    static final String EXTRA_DISPLAY = "display", EXTRA_FROM_DISPLAY = "from_display";
    /** How often a running pad checks that what it serves is still on screen ([check]); the first check waits as long. */
    static final long CHECK_MS = 1500;

    private static CoverPadActivity current;
    private SensorManager sensors;
    int mode;
    private FingerView view;

    static boolean running() { return current != null; }

    /** The running mode, or -1. */
    static int mode() { return current == null ? -1 : current.mode; }

    static void start(Activity from) {
        start(from, MODE_GAME);
    }

    /** Both screens on, then this on the cover display (the built-in display that is not {@code from}'s); if it is
     *  already up, it just switches mode. */
    static void start(Activity from, int mode) {
        if (current != null) {
            current.mode = mode;
            current.view.modeChanged();
            return;
        }
        Display ownDisplay = from.getDisplay();
        int own = ownDisplay != null ? ownDisplay.getDisplayId() : Display.DEFAULT_DISPLAY;
        // The other panel: same kind of display as ours ("Built-in Screen"), not a virtual one (scrcpy...).
        String panelName = ownDisplay != null ? ownDisplay.getName() : "";
        Handler ui = new Handler(Looper.getMainLooper());
        Log.i(TAG, "start (" + (mode == MODE_DESKTOP ? "desktop" : "game") + ") from display " + own);
        SU.execute(() -> {
            su("cmd device_state state 99");
            DisplayManager dm = from.getSystemService(DisplayManager.class);
            for (int i = 0; i < 30; i++) { // the cover display comes up a moment after the state switch
                for (Display d : dm.getDisplays()) {
                    if (d.getDisplayId() != own && panelName.equals(d.getName()) && d.getState() == Display.STATE_ON) {
                        int id = d.getDisplayId();
                        Log.i(TAG, "cover display " + id + " is on, opening the pad there");
                        ui.post(() -> {
                            ActivityOptions o = ActivityOptions.makeBasic().setLaunchDisplayId(id);
                            from.startActivity(new Intent(from, CoverPadActivity.class).putExtra(EXTRA_MODE, mode)
                                .putExtra(EXTRA_DISPLAY, id).putExtra(EXTRA_FROM_DISPLAY, own)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_MULTIPLE_TASK), o.toBundle());
                        });
                        return;
                    }
                }
                try { Thread.sleep(100); } catch (InterruptedException e) { return; }
            }
            Log.w(TAG, "no cover display came up");
            su("cmd device_state state reset");
        });
    }

    /** Forget the learned grip. */
    static void relearn() {
        if (current != null) current.view.relearn();
    }

    static void stop() {
        if (current != null) current.finishAndRemoveTask();
        else SU.execute(() -> su("cmd device_state state reset"));
    }

    /**
     * Whether the pad in [mode] serves something on screen now: the finger pad a game whose controls show in front (a
     * full-screen Linux window's task, or the desktop with its controls up), the trackpad the desktop. Nothing shown -
     * the game ended, its process died and its task went, the user went home or to another app - and the pad is only a
     * black task holding both screens on.
     */
    static boolean wanted(int mode) {
        return mode == MODE_DESKTOP ? MainActivity.desktopShown()
            : PowosWindowActivity.gameShown() || MainActivity.gameShown();
    }

    /** A running pad that serves nothing on screen any more ([wanted]) goes, with its task (any thread). */
    static void check() {
        CoverPadActivity c = current;
        if (c == null) return;
        c.runOnUiThread(() -> {
            if (current != c || c.isFinishing() || wanted(c.mode)) return;
            Log.i(TAG, "nothing on screen for the " + (c.mode == MODE_DESKTOP ? "trackpad" : "game pad") + ": closing it");
            c.finishAndRemoveTask();
        });
    }

    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Runnable watchdog = new Runnable() {
        @Override
        public void run() {
            check();
            if (current == CoverPadActivity.this && !isFinishing()) ui.postDelayed(this, CHECK_MS);
        }
    };
    /** The cover display this pad belongs on, and the inner screen's (-1: unknown, an older start). */
    private int coverDisplay = -1, innerDisplay = -1;
    private DisplayManager displays;
    private final DisplayManager.DisplayListener displayListener = new DisplayManager.DisplayListener() {
        @Override public void onDisplayAdded(int id) { }
        @Override public void onDisplayRemoved(int id) { if (id == coverDisplay) offCover("its display went"); }
        @Override public void onDisplayChanged(int id) {
            if (id != coverDisplay) return;
            Display d = displays.getDisplay(id);
            if (d == null || d.getState() == Display.STATE_OFF) offCover("its display turned off");
        }
    };

    /**
     * The pad belongs on the cover panel only. When that display goes (the device state reset under it: a fold, the
     * system cancelling the both-screens state), Android moves its task to the inner screen, where it was an all-black
     * task on top of home - P0 2026-10-30, the user stuck on it for hours. It goes instead.
     */
    private void offCover(String why) {
        if (isFinishing()) return;
        Log.i(TAG, "the cover display is gone (" + why + "): closing the pad");
        finishAndRemoveTask();
    }

    /** Every device-state change and the start sequence, one at a time and in order: an "off" (reset) still running
     *  in the background after a quick "on" would switch the cover display off under the new pad and close it. */
    private static final java.util.concurrent.ExecutorService SU =
        java.util.concurrent.Executors.newSingleThreadExecutor(r -> new Thread(r, "CoverPadSu"));

    static void su(String cmd) {
        try {
            // The app's one root shell: no new su (and Magisk toast) per command.
            Log.i(TAG, "su " + cmd + " -> " + RootShell.run(cmd).code);
        } catch (Exception e) {
            Log.w(TAG, "su " + cmd + ": " + e);
        }
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        mode = getIntent().getIntExtra(EXTRA_MODE, MODE_GAME);
        coverDisplay = getIntent().getIntExtra(EXTRA_DISPLAY, -1);
        innerDisplay = getIntent().getIntExtra(EXTRA_FROM_DISPLAY, -1);
        Display at = getDisplay();
        int on = at != null ? at.getDisplayId() : -1;
        // Recreated (moved to another display, the process restarted) or opened anywhere but the cover panel: a pad
        // here would be a black task over the inner screen. It only ever comes up fresh, from start().
        if (b != null || (coverDisplay >= 0 && on != coverDisplay) || (coverDisplay < 0 && on == Display.DEFAULT_DISPLAY)) {
            Log.i(TAG, "opened on display " + on + (b != null ? " (recreated)" : "") + ", not the cover panel " + coverDisplay
                + ": closing it");
            finishAndRemoveTask();
            return;
        }
        current = this;
        Log.i(TAG, "opened on display " + (getDisplay() != null ? getDisplay().getDisplayId() : -1)
            + (mode == MODE_DESKTOP ? " (desktop trackpad)" : " (game pad)"));
        // Not focusable: touches still arrive, but the desktop on the inner screen keeps the focus (keyboard,
        // Android's "top" activity) - the back screen is only ever touched, never typed into.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
        view = new FingerView(this);
        setContentView(view);
        sensors = getSystemService(SensorManager.class);
        Sensor hinge = sensors.getDefaultSensor(Sensor.TYPE_HINGE_ANGLE);
        if (hinge != null) sensors.registerListener(this, hinge, SensorManager.SENSOR_DELAY_NORMAL);
        displays = getSystemService(DisplayManager.class);
        displays.registerDisplayListener(displayListener, ui);
        ui.postDelayed(watchdog, CHECK_MS);
    }

    /**
     * Opening this on the cover display makes it Android's top (focused) activity, but its window is not focusable:
     * Android then has a focused app with no focused window, and the next key event (power, volume, a gamepad
     * button, the keyboard) waits for one - after 5 s an ANR ("Application does not have a focused window") that
     * kills the whole app, and the PowOS session with it (2026-10-20, Broforce: a power press while the pad was up).
     * So whenever this becomes top, the focus goes back to the inner screen: keys stay with what is shown there, and
     * touches still reach this pad (a tap on a non-focusable window never takes the focus).
     *
     * The focus goes back to whatever is in front on the inner screen - the game's task, home, any app - never a fixed
     * task. It used to be the desktop's (MainActivity) always: in phone mode that raised the desktop's surface, black
     * with no Plasma on it, over the game or home every time the pad became top (a touch on the back, the assistant's
     * overlay coming or going, a game's task finishing). That was the black screen the user could not leave
     * (2026-10-30, ABZÛ: even a new task of the app was buried again), the game "minimised" and the flicker with the
     * assistant open.
     */
    @Override
    public void onTopResumedActivityChanged(boolean top) {
        super.onTopResumedActivityChanged(top);
        if (!top || isFinishing() || current != this) return;
        android.app.ActivityManager am = getSystemService(android.app.ActivityManager.class);
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) try { // TaskInfo.isVisible: API 31
            // PowOS is the recents provider: it sees every task, newest first; the newest visible one that isn't this
            // pad's is the one in front on the inner screen (an app, a game's task, a floating window).
            @SuppressWarnings("deprecation")
            java.util.List<android.app.ActivityManager.RecentTaskInfo> tasks =
                am.getRecentTasks(8, android.app.ActivityManager.RECENT_IGNORE_UNAVAILABLE);
            for (android.app.ActivityManager.RecentTaskInfo t : tasks) {
                if (t.taskId == getTaskId() || !t.isVisible()) continue;
                if (t.topActivity != null && CoverPadActivity.class.getName().equals(t.topActivity.getClassName())) continue;
                am.moveTaskToFront(t.taskId, 0); // in front already: only the focus moves, nothing is reordered
                Log.i(TAG, "focus back to the inner screen's front task " + t.taskId + " (" + t.topActivity + ")");
                return;
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "focus back to the inner screen: " + e);
        }
        // Nothing listed in front there: home is (home isn't a recent task). Home again on the inner screen takes the
        // focus back without changing what shows.
        try {
            ActivityOptions o = ActivityOptions.makeBasic();
            if (innerDisplay >= 0) o.setLaunchDisplayId(innerDisplay);
            startActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), o.toBundle());
            Log.i(TAG, "focus back to home on the inner screen");
        } catch (RuntimeException e) {
            Log.w(TAG, "focus back to home: " + e);
        }
    }

    @Override
    public void onSensorChanged(SensorEvent e) {
        if (e.values[0] < 150f) { // folding: give the screens back to the phone
            Log.i(TAG, "folding (" + e.values[0] + " deg), closing the cover pad");
            finishAndRemoveTask();
        }
    }

    @Override
    public void onAccuracyChanged(Sensor s, int a) {
    }

    @Override
    protected void onDestroy() {
        Log.i(TAG, "closed" + (isFinishing() ? "" : " by the system"));
        ui.removeCallbacks(watchdog);
        if (current != this) { // closed in onCreate (not on the cover panel): nothing of it was set up
            super.onDestroy();
            return;
        }
        if (displays != null) displays.unregisterDisplayListener(displayListener);
        sensors.unregisterListener(this);
        PadHub.get(this).setButtons(PadHub.COVER, 0);
        view.releaseMouseButtons();
        current = null;
        SU.execute(() -> su("cmd device_state state reset"));
        super.onDestroy();
    }

    /** Six finger slots, learned online; draws them and the live touches. */
    static final class FingerView extends View {
        static final String[] HAND = {"L", "R"};
        static final String[] FINGER = {"index", "middle", "ring"};
        static final int[] COLORS = {0xFFE57373, 0xFF81C784, 0xFF64B5F6, 0xFFFFB74D, 0xFFBA68C8, 0xFF4DD0E1};
        /** How far a slot moves toward each new touch of its finger (exponential moving average). */
        static final float LEARN = 0.25f, LEARN_FULL_HAND = 0.5f;

        final float[] sx = new float[6], sy = new float[6]; // slot centres, fractions of the view
        final boolean[] active = new boolean[6];
        final float[] tx = new float[6], ty = new float[6]; // live touch per slot, px
        final SparseIntArray pointerSlot = new SparseIntArray();
        final boolean[] pressed = new boolean[6];
        final long[] lastUp = new long[6];
        final float[] upX = new float[6], upY = new float[6];
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final SharedPreferences prefs;
        final CoverPadActivity act;
        boolean seeded;
        /** Desktop mode, left hand: index, middle, ring -> left, right, middle mouse button (held while pressed). */
        static final int[] MOUSE_BUTTONS = {0x110, 0x111, 0x112};
        static final String[] MOUSE_NAMES = {"left click", "right click", "middle click"};
        // Desktop mode, the trackpad half: its pointers, re-sent as their own event stream to the touchpad.
        final java.util.ArrayList<Integer> padIds = new java.util.ArrayList<>();

        FingerView(CoverPadActivity c) {
            super(c);
            act = c;
            prefs = c.getSharedPreferences("powos_coverpad", Context.MODE_PRIVATE);
            setBackgroundColor(Color.BLACK);
        }

        boolean desktop() { return act.mode == MODE_DESKTOP; }

        void modeChanged() {
            releaseMouseButtons();
            for (int s = 0; s < 6; s++) { pressed[s] = false; active[s] = false; }
            pointerSlot.clear();
            padIds.clear();
            sendButtons();
            invalidate();
        }

        void releaseMouseButtons() {
            if (!desktop()) return;
            for (int s = 0; s < 3; s++) if (pressed[s]) Native.nativeSendMouseButton(MOUSE_BUTTONS[s], false);
        }

        /** The trackpad half: the right hand's side (where the R slots sit along the screen). */
        boolean onPadHalf(float fx, float fy) {
            float split = (slotAlong(0) + slotAlong(1) + slotAlong(2) + 3 * 0.5f) / 6f; // between the L hand and the middle
            return along(fx, fy) > Math.max(0.4f, Math.min(0.6f, split + 0.1f));
        }


        /**
         * The trackpad half drives the game controls' trackball (GamepadOverlay.TrackballModule): the same feel and code
         * as the on-screen one - the cursor follows from the first pixel, tap = click, two-finger tap = right click,
         * hold then drag = drag, two fingers = scroll, a flick keeps rolling - on the same cursor. Its host is the
         * overlay in MainActivity (mouse output, haptics, frame callbacks); points arrive in screen directions.
         */
        GamepadOverlay.TrackballModule ball;
        final GamepadOverlay.PadState noPad = new GamepadOverlay.PadState(); // the trackball only moves the mouse

        GamepadOverlay.TrackballModule ball() {
            MainActivity main = MainActivity.sInstance;
            GamepadOverlay host = main != null ? main.gamepadOverlay() : null;
            if (host == null) return null;
            if (ball == null || ball.host != host) {
                ball = new GamepadOverlay.TrackballModule();
                ball.host = host;
            }
            return ball;
        }

        /**
         * Back-screen point -> screen directions. The back (cover) panel's top is the inner screen's top, but it faces
         * away from the user, so left and right are mirrored as seen from the front: with the inner screen in its
         * normal orientation, screen x = -back x, screen y = back y (a finger moving up on the back moved the cursor
         * up, measured by the user on the phone). When the inner screen is rotated, the screen's axes turn with it.
         * (The back screen itself is locked to portrait: its axes never change.)
         */
        float[] toScreen(float x, float y) {
            float nx = -x, ny = y; // in the inner screen's natural orientation
            MainActivity main = MainActivity.sInstance;
            int rot = main != null && main.getDisplay() != null ? main.getDisplay().getRotation() : 0;
            switch (rot) {
                case android.view.Surface.ROTATION_90: return new float[]{ny, -nx};
                case android.view.Surface.ROTATION_180: return new float[]{-nx, -ny};
                case android.view.Surface.ROTATION_270: return new float[]{-ny, nx};
                default: return new float[]{nx, ny};
            }
        }

        float screenX(float x, float y) { return toScreen(x, y)[0]; }

        float screenY(float x, float y) { return toScreen(x, y)[1]; }

        void padDown(int id, float x, float y) {
            GamepadOverlay.TrackballModule b = ball();
            if (b != null) b.down(id, screenX(x, y), screenY(x, y), noPad);
        }

        void padMove(MotionEvent e) {
            GamepadOverlay.TrackballModule b = ball();
            if (b == null) return;
            for (int id : padIds) {
                int i = e.findPointerIndex(id);
                if (i >= 0) b.move(id, screenX(e.getX(i), e.getY(i)), screenY(e.getX(i), e.getY(i)), noPad);
            }
        }

        void padUp(int id, boolean cancel) {
            GamepadOverlay.TrackballModule b = ball();
            if (b == null) return;
            if (cancel) b.reset();
            else b.up(id, noPad);
        }

        boolean wide() { return getWidth() >= getHeight(); }

        /** Hands sit along the long axis; each hand's fingers stack along the short one. */
        float along(float x, float y) { return wide() ? x : y; }

        float across(float x, float y) { return wide() ? y : x; }

        void seed() {
            seeded = true;
            for (int s = 0; s < 6; s++) {
                float a = prefs.getFloat("a" + s, -1), c = prefs.getFloat("c" + s, -1);
                if (a < 0) { // default: hands at 1/4 and 3/4 of the long axis, fingers at 1/4, 2/4, 3/4 across
                    a = (s < 3 ? 0.25f : 0.75f);
                    c = 0.25f * (1 + s % 3);
                }
                setSlot(s, a, c);
            }
        }

        void setSlot(int s, float a, float c) {
            if (wide()) { sx[s] = a; sy[s] = c; } else { sx[s] = c; sy[s] = a; }
        }

        float slotAlong(int s) { return along(sx[s], sy[s]); }

        float slotAcross(int s) { return across(sx[s], sy[s]); }

        void save() {
            SharedPreferences.Editor e = prefs.edit();
            for (int s = 0; s < 6; s++) e.putFloat("a" + s, slotAlong(s)).putFloat("c" + s, slotAcross(s));
            e.apply();
        }

        /** Nearest free slot to a touch (fractions); one finger per slot. */
        int nearestFree(float fx, float fy) {
            int best = -1;
            double bd = Double.MAX_VALUE;
            for (int s = 0; s < (desktop() ? 3 : 6); s++) {
                if (active[s]) continue;
                double d = Math.hypot(fx - sx[s], fy - sy[s]);
                if (d < bd) { bd = d; best = s; }
            }
            return best;
        }

        /** Move a slot toward where its finger touched, then keep each hand's fingers in order across the screen
         *  (index before middle before ring) and the hands apart along it, so the labels never swap. */
        void learn(int s, float fx, float fy, float rate) {
            sx[s] += (fx - sx[s]) * rate;
            sy[s] += (fy - sy[s]) * rate;
            for (int h = 0; h < 2; h++) {
                int b = h * 3;
                float[] a = new float[3], c = new float[3];
                for (int i = 0; i < 3; i++) { a[i] = slotAlong(b + i); c[i] = slotAcross(b + i); }
                Integer[] order = {0, 1, 2};
                java.util.Arrays.sort(order, (p, q) -> Float.compare(c[p], c[q]));
                for (int i = 0; i < 3; i++) setSlot(b + i, a[order[i]], c[order[i]]);
            }
            float left = (slotAlong(0) + slotAlong(1) + slotAlong(2)) / 3f;
            float right = (slotAlong(3) + slotAlong(4) + slotAlong(5)) / 3f;
            if (left > right) { // hands crossed over: swap them back
                for (int i = 0; i < 3; i++) {
                    float a0 = slotAlong(i), c0 = slotAcross(i);
                    setSlot(i, slotAlong(3 + i), slotAcross(3 + i));
                    setSlot(3 + i, a0, c0);
                }
            }
        }

        /**
         * A grip (four or more fingers down, game mode): assign every finger from scratch instead of trusting the
         * nearest-slot guesses - split the touches into two hands at the widest gap along the screen (3 + 3 when all
         * six are down), order each hand's fingers across it, remap, and learn strongly. Self-correcting: a finger
         * once filed under the wrong hand moves back as soon as the whole grip is seen.
         */
        void regrip() {
            if (desktop()) return;
            for (boolean p : pressed) if (p) return; // never re-label a held button
            int n = pointerSlot.size();
            if (n < 4) return;
            float w = getWidth(), ht = getHeight();
            float[][] t = new float[n][]; // {id, fx, fy}
            for (int k = 0; k < n; k++) {
                int s = pointerSlot.valueAt(k);
                t[k] = new float[]{pointerSlot.keyAt(k), tx[s] / w, ty[s] / ht};
            }
            java.util.Arrays.sort(t, (a, b) -> Float.compare(along(a[1], a[2]), along(b[1], b[2])));
            int split = 3;
            if (n != 6) { // the widest gap along the screen separates the hands
                float best = -1;
                for (int k = 1; k < n; k++) {
                    float gap = along(t[k][1], t[k][2]) - along(t[k - 1][1], t[k - 1][2]);
                    if (gap > best && k <= 3 && n - k <= 3) { best = gap; split = k; }
                }
            }
            pointerSlot.clear();
            for (int s = 0; s < 6; s++) active[s] = false;
            for (int hand = 0; hand < 2; hand++) {
                int from = hand == 0 ? 0 : split, to = hand == 0 ? split : n;
                float[][] f = java.util.Arrays.copyOfRange(t, from, to);
                java.util.Arrays.sort(f, (a, b) -> Float.compare(across(a[1], a[2]), across(b[1], b[2])));
                // With fewer than three fingers of a hand down, keep them on the slots nearest across.
                int[] slots = new int[f.length];
                if (f.length == 3) { slots[0] = 0; slots[1] = 1; slots[2] = 2; }
                else {
                    boolean[] used = new boolean[3];
                    for (int i = 0; i < f.length; i++) {
                        int bestS = 0;
                        float bd = Float.MAX_VALUE;
                        for (int j = 0; j < 3; j++) {
                            if (used[j]) continue;
                            float d = Math.abs(slotAcross(hand * 3 + j) - across(f[i][1], f[i][2]));
                            if (d < bd) { bd = d; bestS = j; }
                        }
                        used[bestS] = true;
                        slots[i] = bestS;
                    }
                }
                for (int i = 0; i < f.length; i++) {
                    int s = hand * 3 + slots[i];
                    pointerSlot.put((int) f[i][0], s);
                    active[s] = true;
                    tx[s] = f[i][1] * w;
                    ty[s] = f[i][2] * ht;
                    sx[s] += (f[i][1] - sx[s]) * LEARN_FULL_HAND;
                    sy[s] += (f[i][2] - sy[s]) * LEARN_FULL_HAND;
                }
            }
            save();
        }

        /** Forget the learned grip: back to the default zones. */
        void relearn() {
            prefs.edit().clear().apply();
            for (int s = 0; s < 6; s++) setSlot(s, s < 3 ? 0.25f : 0.75f, 0.25f * (1 + s % 3));
            invalidate();
        }

        @Override
        public boolean onTouchEvent(MotionEvent e) {
            if (!seeded) seed();
            float w = getWidth(), h = getHeight();
            int idx = e.getActionIndex();
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                case MotionEvent.ACTION_POINTER_DOWN: {
                    if (desktop() && onPadHalf(e.getX(idx) / w, e.getY(idx) / h)) {
                        int id = e.getPointerId(idx);
                        padIds.add(id);
                        padDown(id, e.getX(idx), e.getY(idx));
                        break;
                    }
                    int s = nearestFree(e.getX(idx) / w, e.getY(idx) / h);
                    if (s >= 0) {
                        pointerSlot.put(e.getPointerId(idx), s);
                        active[s] = true;
                        tx[s] = e.getX(idx);
                        ty[s] = e.getY(idx);
                        // Lifted and pressed again quickly: a press, held until this finger lifts.
                        long off = e.getEventTime() - lastUp[s];
                        float near = Math.min(w, h) * PRESS_RADIUS;
                        if (off >= PRESS_MIN && off <= PRESS_MAX
                                && Math.hypot(e.getX(idx) - upX[s], e.getY(idx) - upY[s]) < near) {
                            pressed[s] = true;
                            performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY);
                            sendButtons();
                        }
                        // t= is the touch's own timestamp (uptime ms, CLOCK_MONOTONIC: comparable with powos-padd's).
                        regrip();
                        Log.i(TAG, "down " + HAND[s / 3] + " " + FINGER[s % 3] + (pressed[s] ? " -> " + BUTTON_NAMES[s] : "")
                            + " t=" + e.getEventTime());
                    }
                    break;
                }
                case MotionEvent.ACTION_MOVE:
                    if (!padIds.isEmpty()) padMove(e);
                    for (int i = 0; i < e.getPointerCount(); i++) {
                        int s = pointerSlot.get(e.getPointerId(i), -1);
                        if (s >= 0) { tx[s] = e.getX(i); ty[s] = e.getY(i); }
                    }
                    break;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_POINTER_UP:
                case MotionEvent.ACTION_CANCEL: {
                    boolean all = e.getActionMasked() == MotionEvent.ACTION_CANCEL;
                    for (int i = 0; i < e.getPointerCount(); i++) {
                        if (!all && i != idx) continue;
                        int pid = e.getPointerId(i);
                        if (padIds.contains(pid)) { // the trackpad half
                            padUp(pid, all);
                            padIds.remove(Integer.valueOf(pid));
                            continue;
                        }
                        int s = pointerSlot.get(e.getPointerId(i), -1);
                        if (s < 0) continue;
                        learn(s, e.getX(i) / w, e.getY(i) / h, LEARN);
                        active[s] = false;
                        lastUp[s] = e.getEventTime();
                        upX[s] = e.getX(i);
                        upY[s] = e.getY(i);
                        if (pressed[s]) {
                            pressed[s] = false;
                            sendButtons();
                        }
                        pointerSlot.delete(e.getPointerId(i));
                        Log.i(TAG, "up " + HAND[s / 3] + " " + FINGER[s % 3]);
                    }
                    save();
                    break;
                }
            }
            invalidate();
            return true;
        }

        final boolean[] sentMouse = new boolean[3];

        void sendButtons() {
            if (desktop()) {
                for (int s = 0; s < 3; s++) {
                    if (pressed[s] != sentMouse[s]) {
                        Native.nativeSendMouseButton(MOUSE_BUTTONS[s], pressed[s]);
                        sentMouse[s] = pressed[s];
                    }
                }
                return;
            }
            int bits = 0;
            for (int s = 0; s < 6; s++) if (pressed[s]) bits |= BUTTONS[s];
            PadHub.get(getContext()).setButtons(PadHub.COVER, bits);
        }

        @Override
        protected void onDraw(Canvas c) {
            if (!seeded) seed();
            float w = getWidth(), h = getHeight(), u = Math.min(w, h);
            // Zones: each pixel belongs to its nearest slot (Voronoi), drawn coarsely as a grid of cells.
            int step = Math.max(8, (int) (u / 40));
            paint.setStyle(Paint.Style.FILL);
            for (int y = 0; y < h; y += step) {
                for (int x = 0; x < w; x += step) {
                    int best = 0;
                    double bd = Double.MAX_VALUE;
                    for (int s = 0; s < 6; s++) {
                        double d = Math.hypot(x / w - sx[s], y / h - sy[s]);
                        if (d < bd) { bd = d; best = s; }
                    }
                    paint.setColor((COLORS[best] & 0x00FFFFFF) | (active[best] ? 0x66000000 : 0x22000000));
                    c.drawRect(x, y, x + step, y + step, paint);
                }
            }
            paint.setTextAlign(Paint.Align.CENTER);
            if (desktop()) {
                // The trackpad half, over the zones.
                paint.setColor(0xEE101418);
                for (int y = 0; y < h; y += step)
                    for (int x = 0; x < w; x += step)
                        if (onPadHalf(x / w, y / h)) c.drawRect(x, y, x + step, y + step, paint);
                paint.setColor(0xFFB0BEC5);
                paint.setTextSize(u * 0.06f);
                float cx = wide() ? w * 0.75f : w / 2f, cy = wide() ? h / 2f : h * 0.75f;
                c.drawText("trackpad", cx, cy, paint);
            }
            for (int s = 0; s < (desktop() ? 3 : 6); s++) {
                float cx = sx[s] * w, cy = sy[s] * h;
                paint.setColor(COLORS[s]);
                c.drawCircle(cx, cy, u * 0.03f, paint);
                paint.setColor(Color.WHITE);
                paint.setTextSize(u * 0.045f);
                // Two lines: the finger, then what it does (one line overlapped the next zone's label).
                c.drawText(HAND[s / 3] + " " + FINGER[s % 3], cx, cy - u * 0.10f, paint);
                c.drawText(desktop() ? MOUSE_NAMES[s] : BUTTON_NAMES[s], cx, cy - u * 0.05f, paint);
                if (active[s]) {
                    paint.setColor(pressed[s] ? Color.WHITE : COLORS[s]);
                    c.drawCircle(tx[s], ty[s], u * (pressed[s] ? 0.09f : 0.07f), paint);
                }
            }
        }
    }
}
