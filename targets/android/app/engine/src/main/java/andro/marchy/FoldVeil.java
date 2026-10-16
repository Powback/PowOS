package andro.marchy;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.Shader;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.view.animation.DecelerateInterpolator;

/**
 * The fold transition (as on the iPhone Duo): neither screen ever just turns on or off. Through the whole fold the
 * screen in use blurs and a dark front sweeps in from the hinge side, following the hinge; at the end (shut or fully
 * open, FoldWatcher holds the screens until then) the other screen comes up blurred and dark and clears.
 *
 * A window over everything on display 0 (which Android moves between the two screens), touch-through, using
 * Android's own blur-behind for the blur and drawing the sweep itself; only there during a fold. Needs "display over
 * other apps", which rooted mode grants itself.
 */
final class FoldVeil {
    private static final String TAG = "FoldVeil";
    /** At full strength: the blur radius (px) and the overall dim (the sweep does the rest). */
    private static final int MAX_BLUR = 90;
    private static final float MAX_DIM = 0.2f;
    /** How long the new screen takes to clear. */
    private static final long CLEAR_MS = 260;
    /** How veiled the new screen starts. */
    private static final float COVER_LEVEL = 0.75f;

    private final Context ctx;
    private final Handler main = new Handler(Looper.getMainLooper());
    private WindowManager wm;
    private Sweep view;
    private WindowManager.LayoutParams lp;
    private ValueAnimator clearing;
    private float level;
    /** Where the hinge is on the screen in use: its left edge (the cover screen) or its middle (the inner one). */
    private volatile boolean hingeAtEdge;

    FoldVeil(Context ctx) {
        this.ctx = ctx;
    }

    /** Veil at [l] (0 = none, 1 = full), following the hinge, on the cover or the inner screen; from any thread. */
    void set(float l, boolean cover) {
        hingeAtEdge = cover;
        main.post(() -> {
            if (clearing != null) {
                clearing.cancel();
                clearing = null;
            }
            apply(Math.max(0f, Math.min(1f, l)));
        });
    }

    /** The screen that just took over: from mostly veiled, cleared after [delayMs] (what it shows being put in place). */
    void cover(boolean cover, long delayMs) {
        set(COVER_LEVEL, cover);
        main.postDelayed(this::clear, delayMs);
    }

    /** Clears it, eased out. */
    void clear() {
        main.post(() -> {
            if (view == null || clearing != null)
                return;
            clearing = ValueAnimator.ofFloat(level, 0f);
            clearing.setDuration((long) (CLEAR_MS * Math.max(level, 0.3f)));
            clearing.setInterpolator(new DecelerateInterpolator(1.6f));
            clearing.addUpdateListener(a -> apply((float) a.getAnimatedValue()));
            clearing.start();
        });
    }

    private void apply(float l) {
        level = l;
        if (l <= 0.01f) {
            remove();
            return;
        }
        if (view == null && !add())
            return;
        view.invalidate();
        int blur = Math.round(l * MAX_BLUR);
        float dim = l * MAX_DIM;
        if (lp.getBlurBehindRadius() == blur && lp.dimAmount == dim)
            return;
        lp.setBlurBehindRadius(blur);
        lp.dimAmount = dim;
        try {
            wm.updateViewLayout(view, lp);
        } catch (RuntimeException e) {
            Log.w(TAG, "update: " + e);
        }
    }

    /** The dark front, sweeping in from the hinge side as the level rises; feathered so it reads as a fade. */
    private final class Sweep extends View {
        private final Paint paint = new Paint();

        Sweep(Context c) {
            super(c);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w == 0)
                return;
            // How far across the front has come (0..1 of the way from the hinge to the far edge), feather included.
            float reach = level * 1.4f;
            int dark = (int) (Math.min(1f, level * 1.15f) * 255) << 24;
            if (hingeAtEdge) {
                float edge = w * reach;
                paint.setShader(new LinearGradient(edge - w * 0.45f, 0, edge, 0, dark, 0, Shader.TileMode.CLAMP));
                canvas.drawRect(0, 0, w, h, paint);
            } else {
                float mid = w / 2f, half = mid * reach;
                paint.setShader(new LinearGradient(mid + half - mid * 0.45f, 0, mid + half, 0, dark, 0, Shader.TileMode.CLAMP));
                canvas.drawRect(mid, 0, w, h, paint);
                paint.setShader(new LinearGradient(mid - half + mid * 0.45f, 0, mid - half, 0, dark, 0, Shader.TileMode.CLAMP));
                canvas.drawRect(0, 0, mid, h, paint);
            }
        }
    }

    private boolean add() {
        if (!android.provider.Settings.canDrawOverlays(ctx))
            return false;
        wm = ctx.getSystemService(WindowManager.class);
        view = new Sweep(ctx);
        lp = new WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                | WindowManager.LayoutParams.FLAG_BLUR_BEHIND | WindowManager.LayoutParams.FLAG_DIM_BEHIND
                | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT);
        lp.setTitle("PowOS fold");
        lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        lp.setFitInsetsTypes(0);
        try {
            wm.addView(view, lp);
            return true;
        } catch (RuntimeException e) {
            Log.w(TAG, "add: " + e);
            view = null;
            return false;
        }
    }

    private void remove() {
        if (view == null)
            return;
        try {
            wm.removeView(view);
        } catch (RuntimeException e) {
            Log.w(TAG, "remove: " + e);
        }
        view = null;
    }
}
