package andro.marchy;

import android.app.Activity;
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
 * Step 1 (this): the screen and the finger detection, with the live zones drawn for checking. Mapping fingers to
 * controller inputs comes next (design: targets/android/docs/controller-overlay.md).
 *
 * Started on the cover display (am start --display <id>, or ActivityOptions.setLaunchDisplayId) while both
 * screens are on (device state ALL).
 */
public class CoverPadActivity extends Activity {

    private static final String TAG = "CoverPad";

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        setContentView(new FingerView(this));
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
                        Log.i(TAG, "down " + HAND[s / 3] + " " + FINGER[s % 3]);
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
                c.drawText(HAND[s / 3] + " " + FINGER[s % 3], cx, cy - u * 0.05f, paint);
                if (active[s]) {
                    paint.setColor(COLORS[s]);
                    c.drawCircle(tx[s], ty[s], u * 0.07f, paint);
                }
            }
        }
    }
}
