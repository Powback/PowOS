package andro.marchy;

import java.util.HashMap;
import java.util.Map;

/**
 * Which on-screen buttons each finger is on, like a real pad: a finger is not pinned to the button it first touched.
 * Sliding from one button onto another releases the first and presses the next; a finger resting on the border of
 * two adjacent buttons (its contact patch, {@link #slop} px around the touch point, overlaps both) holds both. Every
 * finger is tracked on its own; a button stays pressed while any finger is on it.
 *
 * <p>Pure Java (no android.*) so JVM tests drive it with synthetic pointer streams (SlideButtonsTest).
 * GamepadOverlay feeds it the circles of its slide-capable buttons and turns press/release into pad state.
 */
public final class SlideButtons {
    /** Gets a button index when its first finger arrives and when its last finger leaves. */
    public interface Sink {
        void press(int button);

        void release(int button);
    }

    /** Button circles as cx, cy, r triples (overlay pixels); at most 64 buttons. */
    private float[] circles = new float[0];
    private int[] holds = new int[0];
    /** Pointer id -> bitmask of the buttons that finger is on. */
    private final Map<Integer, Long> fingers = new HashMap<>();
    /** Half the finger's contact patch, px: a finger touches a button when the patch overlaps its circle. */
    public float slop;

    /** New button geometry. Only taken while no finger is tracked, so indices never change under a finger. */
    public boolean setButtons(float[] cxCyR) {
        if (!fingers.isEmpty()) return false;
        circles = cxCyR.clone();
        holds = new int[Math.min(64, circles.length / 3)];
        return true;
    }

    public int count() {
        return holds.length;
    }

    /** Bitmask of the buttons a finger at (x, y) touches. */
    public long hits(float x, float y) {
        long mask = 0;
        for (int i = 0; i < holds.length; i++) {
            float dx = x - circles[i * 3], dy = y - circles[i * 3 + 1], reach = circles[i * 3 + 2] + slop;
            if (dx * dx + dy * dy <= reach * reach) mask |= 1L << i;
        }
        return mask;
    }

    public boolean tracks(int pointer) {
        return fingers.containsKey(pointer);
    }

    /** A finger lands; it is tracked (true) if it touches any button. */
    public boolean down(int pointer, float x, float y, Sink s) {
        long now = hits(x, y);
        if (now == 0) return false;
        fingers.put(pointer, 0L);
        apply(pointer, now, s);
        return true;
    }

    /** A tracked finger moved: presses what it slid onto, releases what it slid off. */
    public void move(int pointer, float x, float y, Sink s) {
        if (fingers.containsKey(pointer)) apply(pointer, hits(x, y), s);
    }

    public void up(int pointer, Sink s) {
        if (!fingers.containsKey(pointer)) return;
        apply(pointer, 0, s);
        fingers.remove(pointer);
    }

    /** Forget every finger without callbacks (the caller resets the pad state itself). */
    public void clear() {
        fingers.clear();
        java.util.Arrays.fill(holds, 0);
    }

    private void apply(int pointer, long now, Sink s) {
        long was = fingers.get(pointer);
        if (was == now) return;
        fingers.put(pointer, now);
        for (int i = 0; i < holds.length; i++) {
            long bit = 1L << i;
            if ((was & bit) != 0 && (now & bit) == 0 && --holds[i] == 0) s.release(i);
        }
        for (int i = 0; i < holds.length; i++) {
            long bit = 1L << i;
            if ((now & bit) != 0 && (was & bit) == 0 && holds[i]++ == 0) s.press(i);
        }
    }
}
