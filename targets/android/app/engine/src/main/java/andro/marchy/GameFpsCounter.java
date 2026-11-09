package andro.marchy;

import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.TextView;

/**
 * The built-in fps counter of a game's window task (board task games-show-no-fps-overlay): a small label in the top
 * left corner with the frames the game's window PRESENTED per second - the consumer's own count of the game's frames
 * shown on Android (Native.nativeWindowPresents), so it measures what the user sees, for every game (Proton, native,
 * FEX), with nothing injected into the game. MangoHud was the first idea; it has no aarch64 build to install (the
 * recipe's libxnvctrl dependency, docs/REMOTE-POWOS.md) and would need an x86 Vulkan layer under FEX per game.
 * On while the fps meter's switch is on (store "perf.meter", control centre Tools - the same switch as the status
 * bar's meter, which a full-screen game hides): [on] is set by the app (ShellBridge). Updates twice a second; no
 * allocation per tick but the label's text. Main thread.
 */
public final class GameFpsCounter {
    /** The fps meter's switch (store "perf.meter" on), set by the app at start and on every change. Any thread. */
    public static volatile boolean on;

    static final long TICK_MS = 500;

    /**
     * Frames per second between two reads of the presented count, rounded; -1 when there is nothing to tell (the
     * first read, no time passed, the count went back - a new consumer started counting from zero).
     */
    public static int fps(long presented0, long t0Ms, long presented1, long t1Ms) {
        if (presented0 < 0 || t1Ms <= t0Ms || presented1 < presented0)
            return -1;
        return (int) Math.round((presented1 - presented0) * 1000.0 / (t1Ms - t0Ms));
    }

    /** The label for [fps] (-1: a dash). */
    public static String label(int fps) {
        return fps < 0 ? "-- fps" : fps + " fps";
    }

    private final FrameLayout root;
    private final java.util.function.IntFunction<long[]> presents;
    private final int surfaceId;
    private final Handler main = new Handler(Looper.getMainLooper());
    private TextView view;
    private long lastCount = -1, lastMs;
    private boolean running;

    GameFpsCounter(FrameLayout root, int surfaceId, java.util.function.IntFunction<long[]> presents) {
        this.root = root;
        this.surfaceId = surfaceId;
        this.presents = presents;
    }

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (!running)
                return;
            if (!on) {
                hide();
            } else {
                show();
                long[] p = presents.apply(surfaceId);
                long now = android.os.SystemClock.uptimeMillis();
                long count = p != null && p.length > 0 ? p[0] : -1;
                if (count < 0) {
                    lastCount = -1; // nothing shown yet
                    view.setText(label(-1));
                } else {
                    int f = fps(lastCount, lastMs, count, now);
                    lastCount = count;
                    lastMs = now;
                    if (f >= 0)
                        view.setText(label(f));
                }
            }
            main.postDelayed(this, TICK_MS);
        }
    };

    /** Counting while the window is in front (its consumer presents); stopped behind, so nothing ticks for nobody. */
    void start() {
        if (running)
            return;
        running = true;
        lastCount = -1;
        main.post(tick);
    }

    void stop() {
        running = false;
        main.removeCallbacks(tick);
        hide();
    }

    private void show() {
        if (view == null) {
            view = new TextView(root.getContext());
            view.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
            view.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            view.setTextColor(Color.WHITE);
            view.setShadowLayer(3f, 0f, 0f, Color.BLACK);
            float d = root.getResources().getDisplayMetrics().density;
            view.setPadding(Math.round(6 * d), Math.round(3 * d), Math.round(6 * d), Math.round(3 * d));
            view.setBackgroundColor(0x66000000);
            view.setText(label(-1));
            // Touches go through to the game (the label takes none).
            view.setClickable(false);
            view.setFocusable(false);
            view.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.START);
            lp.leftMargin = Math.round(8 * d);
            lp.topMargin = Math.round(8 * d);
            root.addView(view, lp);
        }
        view.setVisibility(View.VISIBLE);
    }

    private void hide() {
        if (view != null)
            view.setVisibility(View.GONE);
    }
}
