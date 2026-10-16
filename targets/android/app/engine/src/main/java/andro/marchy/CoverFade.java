package andro.marchy;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.RenderEffect;
import android.graphics.Shader;
import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Display;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;

/**
 * The cover screen's half of the fold crossfade. While FoldWatcher holds both screens on (device state ALL: the inner
 * screen stays display 0, the cover becomes a second display that can't host apps), this shows on the cover what it
 * shows when folded - a snapshot taken after the last fold, else Android's wallpaper - fading and sharpening in as
 * the phone closes, out as it opens. Shut, the cover is display 0 again with the real thing on it.
 */
final class CoverFade {
    private static final String TAG = "CoverFade";
    private static final float MAX_BLUR = 72f;

    private final Context ctx;
    private final java.io.File snapshot;
    private final Handler main = new Handler(Looper.getMainLooper());
    private WindowManager wm;
    private FrameLayout root;
    private ImageView image;
    private float level;

    CoverFade(Context ctx, java.io.File snapshot) {
        this.ctx = ctx;
        this.snapshot = snapshot;
    }

    /** How much of the cover shows (0 = dark, 1 = fully there); from any thread. */
    void set(float l) {
        main.post(() -> {
            level = Math.max(0f, Math.min(1f, l));
            if (root == null && !add())
                return;
            image.setAlpha(level);
            float blur = (1f - level) * MAX_BLUR;
            image.setRenderEffect(blur < 0.5f ? null : RenderEffect.createBlurEffect(blur, blur, Shader.TileMode.CLAMP));
        });
    }

    /** The cover display is gone (the fold ended) or the hold ended. */
    void hide() {
        main.post(this::remove);
    }

    private boolean add() {
        DisplayManager dm = ctx.getSystemService(DisplayManager.class);
        Display cover = null;
        for (Display d : dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION))
            if (d.getDisplayId() != Display.DEFAULT_DISPLAY)
                cover = d;
        if (cover == null || !android.provider.Settings.canDrawOverlays(ctx))
            return false; // not up yet: the next hinge event tries again
        Context dc = ctx.createDisplayContext(cover).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null);
        wm = dc.getSystemService(WindowManager.class);
        root = new FrameLayout(dc);
        root.setBackgroundColor(Color.BLACK);
        image = new ImageView(dc);
        image.setScaleType(ImageView.ScaleType.CENTER_CROP);
        Bitmap bmp = snapshot.isFile() ? BitmapFactory.decodeFile(snapshot.getPath()) : null;
        if (bmp != null)
            image.setImageBitmap(bmp);
        else
            image.setImageDrawable(android.app.WallpaperManager.getInstance(ctx).getDrawable());
        root.addView(image, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.OPAQUE);
        lp.setTitle("PowOS fold cover");
        lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        lp.setFitInsetsTypes(0);
        try {
            wm.addView(root, lp);
            return true;
        } catch (RuntimeException e) {
            Log.w(TAG, "add: " + e);
            root = null;
            return false;
        }
    }

    private void remove() {
        if (root == null)
            return;
        try {
            wm.removeView(root);
        } catch (RuntimeException e) {
            Log.w(TAG, "remove: " + e);
        }
        root = null;
    }
}
