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

    private static CoverPadActivity current;
    private SensorManager sensors;

    static boolean running() { return current != null; }

    /** Both screens on, then this on the cover display (the built-in display that is not {@code from}'s). */
    static void start(Activity from) {
        Display ownDisplay = from.getDisplay();
        int own = ownDisplay != null ? ownDisplay.getDisplayId() : Display.DEFAULT_DISPLAY;
        // The other panel: same kind of display as ours ("Built-in Screen"), not a virtual one (scrcpy...).
        String panelName = ownDisplay != null ? ownDisplay.getName() : "";
        Handler ui = new Handler(Looper.getMainLooper());
        new Thread(() -> {
            su("cmd device_state state 99");
            DisplayManager dm = from.getSystemService(DisplayManager.class);
            for (int i = 0; i < 30; i++) { // the cover display comes up a moment after the state switch
                for (Display d : dm.getDisplays()) {
                    if (d.getDisplayId() != own && panelName.equals(d.getName()) && d.getState() == Display.STATE_ON) {
                        int id = d.getDisplayId();
                        ui.post(() -> {
                            ActivityOptions o = ActivityOptions.makeBasic().setLaunchDisplayId(id);
                            from.startActivity(new Intent(from, CoverPadActivity.class)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_MULTIPLE_TASK), o.toBundle());
                        });
                        return;
                    }
                }
                try { Thread.sleep(100); } catch (InterruptedException e) { return; }
            }
            Log.w(TAG, "no cover display came up");
            su("cmd device_state state reset");
        }, "CoverPadStart").start();
    }

    static void stop() {
        if (current != null) current.finish();
        else new Thread(() -> su("cmd device_state state reset"), "CoverPadStop").start();
    }

    static void su(String cmd) {
        try {
            new ProcessBuilder("su", "-c", cmd).redirectErrorStream(true).start().waitFor();
        } catch (Exception e) {
            Log.w(TAG, "su " + cmd + ": " + e);
        }
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        current = this;
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        setContentView(new FingerView(this));
        sensors = getSystemService(SensorManager.class);
        Sensor hinge = sensors.getDefaultSensor(Sensor.TYPE_HINGE_ANGLE);
        if (hinge != null) sensors.registerListener(this, hinge, SensorManager.SENSOR_DELAY_NORMAL);
    }

    @Override
    public void onSensorChanged(SensorEvent e) {
        if (e.values[0] < 150f) { // folding: give the screens back to the phone
            Log.i(TAG, "folding (" + e.values[0] + " deg), closing the cover pad");
            finish();
        }
    }

    @Override
    public void onAccuracyChanged(Sensor s, int a) {
    }

    @Override
    protected void onDestroy() {
        sensors.unregisterListener(this);
        PadHub.get(this).setButtons(PadHub.COVER, 0);
        if (current == this) current = null;
        new Thread(() -> su("cmd device_state state reset"), "CoverPadStop").start();
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
        boolean seeded;

        FingerView(Context c) {
            super(c);
            prefs = c.getSharedPreferences("powos_coverpad", Context.MODE_PRIVATE);
            setBackgroundColor(Color.BLACK);
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
            for (int s = 0; s < 6; s++) {
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

        /** All three fingers of one hand down at once: assign them by order across the screen, learn faster. */
        void recalibrateHands() {
            for (int h = 0; h < 2; h++) {
                int b = h * 3;
                if (!(active[b] && active[b + 1] && active[b + 2])) continue;
                float w = getWidth(), ht = getHeight();
                float[][] f = new float[3][];
                for (int i = 0; i < 3; i++) f[i] = new float[]{tx[b + i] / w, ty[b + i] / ht};
                java.util.Arrays.sort(f, (p, q) -> Float.compare(across(p[0], p[1]), across(q[0], q[1])));
                for (int i = 0; i < 3; i++) learn(b + i, f[i][0], f[i][1], LEARN_FULL_HAND);
            }
        }

        @Override
        public boolean onTouchEvent(MotionEvent e) {
            if (!seeded) seed();
            float w = getWidth(), h = getHeight();
            int idx = e.getActionIndex();
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                case MotionEvent.ACTION_POINTER_DOWN: {
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
                        Log.i(TAG, "down " + HAND[s / 3] + " " + FINGER[s % 3] + (pressed[s] ? " -> " + BUTTON_NAMES[s] : "")
                            + " t=" + e.getEventTime());
                    }
                    break;
                }
                case MotionEvent.ACTION_MOVE:
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
                        int s = pointerSlot.get(e.getPointerId(i), -1);
                        if (s < 0) continue;
                        recalibrateHands(); // before the lift breaks up a full hand
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

        void sendButtons() {
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
            for (int s = 0; s < 6; s++) {
                float cx = sx[s] * w, cy = sy[s] * h;
                paint.setColor(COLORS[s]);
                c.drawCircle(cx, cy, u * 0.03f, paint);
                paint.setColor(Color.WHITE);
                paint.setTextSize(u * 0.045f);
                c.drawText(HAND[s / 3] + " " + FINGER[s % 3] + "  " + BUTTON_NAMES[s], cx, cy - u * 0.05f, paint);
                if (active[s]) {
                    paint.setColor(pressed[s] ? Color.WHITE : COLORS[s]);
                    c.drawCircle(tx[s], ty[s], u * (pressed[s] ? 0.09f : 0.07f), paint);
                }
            }
        }
    }
}
