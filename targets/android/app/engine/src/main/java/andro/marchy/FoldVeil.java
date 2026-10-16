package andro.marchy;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.PixelFormat;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.view.animation.DecelerateInterpolator;

/**
 * The fold transition (as on the iPhone Duo): instead of one screen cutting to the other, the screen being left blurs
 * and darkens with the hinge as the phone folds or opens, and the screen taking over starts blurred and dark and
 * clears - so the switch Android makes at its fixed hinge angle happens behind a veil, and what the new screen shows
 * (the launcher, the carried app, the desktop) is already in place when it clears.
 *
 * A window over everything on display 0 (which Android moves between the two screens), touch-through, using
 * Android's own blur-behind and dim; only there during a fold. Driven by FoldWatcher (hinge angle, screen switch).
 * Needs "display over other apps", which rooted mode grants itself.
 */
final class FoldVeil {
    private static final String TAG = "FoldVeil";
    /** At full strength: the blur radius (px) and how dark. */
    private static final int MAX_BLUR = 120;
    private static final float MAX_DIM = 0.6f;
    /** How long the new screen takes to clear. */
    private static final long CLEAR_MS = 320;

    private final Context ctx;
    private final Handler main = new Handler(Looper.getMainLooper());
    private WindowManager wm;
    private View view;
    private WindowManager.LayoutParams lp;
    private ValueAnimator clearing;
    private float level;

    FoldVeil(Context ctx) {
        this.ctx = ctx;
    }

    /** Veil at [l] (0 = none, 1 = full), following the hinge; from any thread. */
    void set(float l) {
        main.post(() -> {
            if (clearing != null) {
                clearing.cancel();
                clearing = null;
            }
            apply(Math.max(0f, Math.min(1f, l)));
        });
    }

    /** The new screen: from full strength, cleared after [delayMs] (what it shows being put in place). */
    void cover(long delayMs) {
        set(1f);
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
        lp.setBlurBehindRadius(Math.round(l * MAX_BLUR));
        lp.dimAmount = l * MAX_DIM;
        try {
            wm.updateViewLayout(view, lp);
        } catch (RuntimeException e) {
            Log.w(TAG, "update: " + e);
        }
    }

    private boolean add() {
        if (!android.provider.Settings.canDrawOverlays(ctx))
            return false;
        wm = ctx.getSystemService(WindowManager.class);
        view = new View(ctx);
        lp = new WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                | WindowManager.LayoutParams.FLAG_BLUR_BEHIND | WindowManager.LayoutParams.FLAG_DIM_BEHIND,
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
