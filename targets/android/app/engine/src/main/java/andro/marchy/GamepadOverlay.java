package andro.marchy;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.util.Log;
import android.util.SparseArray;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * On-screen game controls (targets/android/docs/controller-overlay.md), drawn over the PowOS surface.
 *
 * A layout is a list of modules, each with a zone in fractions of the overlay (one layout fits folded and
 * unfolded). A touch belongs to the topmost module whose zone it lands in and stays with it until it lifts;
 * a touch outside every module is not consumed and reaches the desktop as usual. The modules write one shared
 * pad state, sent to powos-padd (virtual gamepad in PowOS) by {@link PadSender} whenever it changes.
 */
public final class GamepadOverlay extends View {

    private static final String TAG = "GamepadOverlay";

    /** The built-in "gamepad" preset (design doc: milestone 1). */
    static final String DEFAULT_LAYOUT = "{\"version\":1,\"name\":\"gamepad\",\"modules\":["
        + "{\"type\":\"stick\",\"zone\":[0,0.35,0.48,1],\"mode\":\"dynamic\",\"radius\":0.09,\"deadzone\":0.1,\"output\":\"left\"},"
        + "{\"type\":\"stick\",\"zone\":[0.52,0.3,1,0.66],\"mode\":\"dynamic\",\"radius\":0.09,\"deadzone\":0.1,\"output\":\"right\"},"
        + "{\"type\":\"button\",\"zone\":[0.80,0.80,0.92,0.88],\"label\":\"A\",\"output\":\"a\",\"color\":\"#5fbf5f\"},"
        + "{\"type\":\"button\",\"zone\":[0.88,0.72,1.0,0.80],\"label\":\"B\",\"output\":\"b\",\"color\":\"#d95f5f\"},"
        + "{\"type\":\"button\",\"zone\":[0.68,0.72,0.80,0.80],\"label\":\"X\",\"output\":\"x\",\"color\":\"#5f8fd9\"},"
        + "{\"type\":\"button\",\"zone\":[0.80,0.64,0.92,0.72],\"label\":\"Y\",\"output\":\"y\",\"color\":\"#d9c45f\"},"
        + "{\"type\":\"dpad\",\"zone\":[0.03,0.22,0.27,0.40]},"
        + "{\"type\":\"button\",\"zone\":[0,0.13,0.16,0.19],\"label\":\"LB\",\"output\":\"lb\"},"
        + "{\"type\":\"trigger\",\"zone\":[0.17,0.13,0.31,0.19],\"label\":\"LT\",\"output\":\"lt\"},"
        + "{\"type\":\"trigger\",\"zone\":[0.69,0.13,0.83,0.19],\"label\":\"RT\",\"output\":\"rt\"},"
        + "{\"type\":\"button\",\"zone\":[0.84,0.13,1,0.19],\"label\":\"RB\",\"output\":\"rb\"},"
        + "{\"type\":\"button\",\"zone\":[0.38,0.13,0.48,0.19],\"label\":\"⧉\",\"output\":\"back\"},"
        + "{\"type\":\"button\",\"zone\":[0.52,0.13,0.62,0.19],\"label\":\"≡\",\"output\":\"start\"}"
        + "]}";

    /** Shared state all modules write; sent as one packet. */
    static final class PadState {
        int buttons;
        float lx, ly, rx, ry, lt, rt;
    }

    /** One control. Coordinates are overlay pixels; zone is resolved from fractions on layout. */
    abstract static class Module {
        final float[] frac = new float[4];
        final RectF zone = new RectF();
        String label = "";
        int color = 0xFFDDDDDD;

        void layout(int w, int h) {
            zone.set(frac[0] * w, frac[1] * h, frac[2] * w, frac[3] * h);
        }

        boolean contains(float x, float y) {
            return zone.contains(x, y);
        }

        /** @return true if the state changed. */
        abstract boolean down(int id, float x, float y, PadState s);

        abstract boolean move(int id, float x, float y, PadState s);

        abstract boolean up(int id, PadState s);

        abstract void draw(Canvas c, Paint p, float unit);
    }

    static int buttonBit(String name) {
        switch (name) {
            case "a": return PadSender.A;
            case "b": return PadSender.B;
            case "x": return PadSender.X;
            case "y": return PadSender.Y;
            case "lb": return PadSender.LB;
            case "rb": return PadSender.RB;
            case "back": return PadSender.BACK;
            case "start": return PadSender.START;
            case "guide": return PadSender.GUIDE;
            case "ls": return PadSender.LS;
            case "rs": return PadSender.RS;
            case "up": return PadSender.UP;
            case "down": return PadSender.DOWN;
            case "left": return PadSender.LEFT;
            case "right": return PadSender.RIGHT;
            default: throw new IllegalArgumentException("unknown button " + name);
        }
    }

    /** Press/release; `mode` tap (held while touched) or toggle. */
    static final class ButtonModule extends Module {
        final int bit;
        final boolean toggle;
        boolean pressed;

        ButtonModule(int bit, boolean toggle) {
            this.bit = bit;
            this.toggle = toggle;
        }

        @Override boolean down(int id, float x, float y, PadState s) {
            if (toggle) pressed = !pressed; else pressed = true;
            s.buttons = pressed ? s.buttons | bit : s.buttons & ~bit;
            return true;
        }

        @Override boolean move(int id, float x, float y, PadState s) {
            return false;
        }

        @Override boolean up(int id, PadState s) {
            if (toggle) return false;
            pressed = false;
            s.buttons &= ~bit;
            return true;
        }

        @Override void draw(Canvas c, Paint p, float unit) {
            float r = Math.min(zone.width(), zone.height()) / 2f;
            p.setStyle(Paint.Style.FILL);
            p.setColor(pressed ? (color & 0x00FFFFFF) | 0xAA000000 : 0x55202020);
            c.drawCircle(zone.centerX(), zone.centerY(), r, p);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(unit * 0.004f);
            p.setColor((color & 0x00FFFFFF) | 0xAA000000);
            c.drawCircle(zone.centerX(), zone.centerY(), r, p);
            drawLabel(c, p, label, zone.centerX(), zone.centerY(), r);
        }
    }

    /** 8-way d-pad from the finger's position relative to the centre; slides between directions. */
    static final class DpadModule extends Module {
        int bits;

        private boolean set(float x, float y, PadState s) {
            float dx = (x - zone.centerX()) / (zone.width() / 2f), dy = (y - zone.centerY()) / (zone.height() / 2f);
            int b = 0;
            if (Math.hypot(dx, dy) > 0.25) {
                double a = Math.toDegrees(Math.atan2(dy, dx)); // 0 = right, 90 = down
                if (a > -67.5 && a < 67.5) b |= PadSender.RIGHT;
                if (a > 22.5 && a < 157.5) b |= PadSender.DOWN;
                if (a > 112.5 || a < -112.5) b |= PadSender.LEFT;
                if (a > -157.5 && a < -22.5) b |= PadSender.UP;
            }
            if (b == bits) return false;
            s.buttons = (s.buttons & ~bits) | b;
            bits = b;
            return true;
        }

        @Override boolean down(int id, float x, float y, PadState s) { return set(x, y, s); }

        @Override boolean move(int id, float x, float y, PadState s) { return set(x, y, s); }

        @Override boolean up(int id, PadState s) {
            if (bits == 0) return false;
            s.buttons &= ~bits;
            bits = 0;
            return true;
        }

        @Override void draw(Canvas c, Paint p, float unit) {
            float cx = zone.centerX(), cy = zone.centerY(), r = Math.min(zone.width(), zone.height()) / 2f;
            float arm = r * 0.36f;
            p.setStyle(Paint.Style.FILL);
            int[][] dirs = {{0, -1, PadSender.UP}, {0, 1, PadSender.DOWN}, {-1, 0, PadSender.LEFT}, {1, 0, PadSender.RIGHT}};
            for (int[] d : dirs) {
                p.setColor((bits & d[2]) != 0 ? 0xAAFFFFFF : 0x55202020);
                float ox = cx + d[0] * r * 0.62f, oy = cy + d[1] * r * 0.62f;
                c.drawRoundRect(ox - arm, oy - arm, ox + arm, oy + arm, arm * 0.3f, arm * 0.3f, p);
            }
        }
    }

    /**
     * Analog stick. Fixed: centred in its zone. Dynamic: appears where the thumb lands (zone = where it may
     * land), re-centred on every touch, and follows the thumb when it is dragged past the rim.
     */
    static final class StickModule extends Module {
        final boolean right, dynamic;
        final float radiusFrac, deadzone;
        float radius, ox, oy, kx, ky;
        boolean active;

        StickModule(boolean right, boolean dynamic, float radiusFrac, float deadzone) {
            this.right = right;
            this.dynamic = dynamic;
            this.radiusFrac = radiusFrac;
            this.deadzone = deadzone;
        }

        @Override void layout(int w, int h) {
            super.layout(w, h);
            radius = radiusFrac * Math.min(w, h) * 1.6f;
        }

        private boolean set(float x, float y, PadState s) {
            float dx = x - ox, dy = y - oy, d = (float) Math.hypot(dx, dy);
            if (dynamic && d > radius) { // the base follows the thumb past the rim
                ox = x - dx / d * radius;
                oy = y - dy / d * radius;
                dx = x - ox;
                dy = y - oy;
                d = radius;
            } else if (d > radius) {
                dx = dx / d * radius;
                dy = dy / d * radius;
                d = radius;
            }
            kx = ox + dx;
            ky = oy + dy;
            float m = d / radius, vx = 0, vy = 0;
            if (m > deadzone) { // rescale so output starts at 0 just outside the deadzone
                float scaled = (m - deadzone) / (1 - deadzone);
                vx = dx / d * scaled;
                vy = dy / d * scaled;
            }
            boolean changed;
            if (right) {
                changed = vx != s.rx || vy != s.ry;
                s.rx = vx;
                s.ry = vy;
            } else {
                changed = vx != s.lx || vy != s.ly;
                s.lx = vx;
                s.ly = vy;
            }
            return changed;
        }

        @Override boolean down(int id, float x, float y, PadState s) {
            active = true;
            if (dynamic) {
                ox = x;
                oy = y;
            } else {
                ox = zone.centerX();
                oy = zone.centerY();
            }
            return set(x, y, s);
        }

        @Override boolean move(int id, float x, float y, PadState s) { return set(x, y, s); }

        @Override boolean up(int id, PadState s) {
            active = false;
            if (right) s.rx = s.ry = 0; else s.lx = s.ly = 0;
            return true;
        }

        @Override void draw(Canvas c, Paint p, float unit) {
            float cx = active ? ox : (dynamic ? zone.centerX() : zone.centerX());
            float cy = active ? oy : (dynamic ? zone.centerY() : zone.centerY());
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(unit * 0.004f);
            p.setColor(active ? 0x99FFFFFF : (dynamic ? 0x33FFFFFF : 0x66FFFFFF));
            c.drawCircle(cx, cy, radius, p);
            p.setStyle(Paint.Style.FILL);
            p.setColor(active ? 0xAAFFFFFF : 0x44FFFFFF);
            c.drawCircle(active ? kx : cx, active ? ky : cy, radius * 0.42f, p);
        }
    }

    /** Analog trigger: pressure along the zone's height (finger lower = harder), or full when tapped. */
    static final class TriggerModule extends Module {
        final boolean right;
        float value;

        TriggerModule(boolean right) {
            this.right = right;
        }

        private boolean set(float v, PadState s) {
            v = Math.max(0f, Math.min(1f, v));
            if (v == value) return false;
            value = v;
            if (right) s.rt = v; else s.lt = v;
            return true;
        }

        @Override boolean down(int id, float x, float y, PadState s) { return set(1f, s); }

        @Override boolean move(int id, float x, float y, PadState s) {
            // Sliding down past the zone keeps it fully pressed; back up eases it off.
            return set(1f - Math.max(0f, (zone.top - y) / (zone.height() * 2f)), s);
        }

        @Override boolean up(int id, PadState s) { return set(0f, s); }

        @Override void draw(Canvas c, Paint p, float unit) {
            float rr = zone.height() * 0.3f;
            p.setStyle(Paint.Style.FILL);
            p.setColor(0x55202020);
            c.drawRoundRect(zone, rr, rr, p);
            if (value > 0) {
                p.setColor(0x88FFFFFF);
                c.drawRoundRect(zone.left, zone.top, zone.left + zone.width() * value, zone.bottom, rr, rr, p);
            }
            drawLabel(c, p, label, zone.centerX(), zone.centerY(), zone.height() / 2f);
        }
    }

    static void drawLabel(Canvas c, Paint p, String text, float cx, float cy, float r) {
        if (text == null || text.isEmpty()) return;
        p.setStyle(Paint.Style.FILL);
        p.setColor(0xDDFFFFFF);
        p.setTextAlign(Paint.Align.CENTER);
        p.setTextSize(r * 0.8f);
        c.drawText(text, cx, cy - (p.descent() + p.ascent()) / 2f, p);
    }

    /** Builds modules from a layout's JSON (format: controller-overlay.md). */
    static List<Module> parse(String json) throws JSONException {
        JSONArray arr = new JSONObject(json).getJSONArray("modules");
        List<Module> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.getJSONObject(i);
            String type = o.getString("type");
            Module m;
            switch (type) {
                case "button":
                    m = new ButtonModule(buttonBit(o.getString("output")), "toggle".equals(o.optString("mode")));
                    break;
                case "dpad":
                    m = new DpadModule();
                    break;
                case "stick":
                    m = new StickModule("right".equals(o.optString("output", "left")),
                        !"fixed".equals(o.optString("mode", "dynamic")),
                        (float) o.optDouble("radius", 0.09), (float) o.optDouble("deadzone", 0.1));
                    break;
                case "trigger":
                    m = new TriggerModule("rt".equals(o.optString("output", "lt")));
                    break;
                default:
                    Log.w(TAG, "unknown module type " + type + ", skipped");
                    continue;
            }
            JSONArray z = o.getJSONArray("zone");
            for (int k = 0; k < 4; k++) m.frac[k] = (float) z.getDouble(k);
            m.label = o.optString("label", "");
            if (o.has("color")) m.color = Color.parseColor(o.getString("color"));
            out.add(m);
        }
        return out;
    }

    private final List<Module> modules = new ArrayList<>();
    private final SparseArray<Module> owner = new SparseArray<>();
    private final PadState state = new PadState();
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final PadSender sender;

    public GamepadOverlay(Context ctx, String padSocketPath) {
        super(ctx);
        sender = new PadSender(padSocketPath);
        sender.start();
        try {
            modules.addAll(parse(DEFAULT_LAYOUT));
        } catch (JSONException e) {
            throw new IllegalStateException("built-in layout", e);
        }
        setWillNotDraw(false);
    }

    /** Shows or hides the controls; hiding releases everything so nothing stays held in the game. */
    public void setShown(boolean shown) {
        setVisibility(shown ? VISIBLE : GONE);
        if (!shown) releaseAll();
    }

    private void releaseAll() {
        owner.clear();
        for (Module m : modules) {
            if (m instanceof ButtonModule) ((ButtonModule) m).pressed = false;
            if (m instanceof DpadModule) ((DpadModule) m).bits = 0;
            if (m instanceof StickModule) ((StickModule) m).active = false;
            if (m instanceof TriggerModule) ((TriggerModule) m).value = 0;
        }
        state.buttons = 0;
        state.lx = state.ly = state.rx = state.ry = state.lt = state.rt = 0;
        send();
        invalidate();
    }

    private void send() {
        sender.post(state.buttons, state.lx, state.ly, state.rx, state.ry, state.lt, state.rt);
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        for (Module m : modules) m.layout(w, h);
    }

    @Override
    protected void onDraw(Canvas canvas) {
        float unit = Math.min(getWidth(), getHeight());
        for (Module m : modules) m.draw(canvas, paint, unit);
    }

    private Module moduleAt(float x, float y) {
        for (int i = modules.size() - 1; i >= 0; i--) { // topmost (last) first: buttons sit over stick zones
            if (modules.get(i).contains(x, y)) return modules.get(i);
        }
        return null;
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int action = e.getActionMasked();
        boolean changed = false;
        switch (action) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_POINTER_DOWN: {
                int i = e.getActionIndex();
                Module m = moduleAt(e.getX(i), e.getY(i));
                if (m == null) {
                    // Not a control: the first finger's gesture goes to the desktop instead.
                    return action != MotionEvent.ACTION_DOWN;
                }
                owner.put(e.getPointerId(i), m);
                changed = m.down(e.getPointerId(i), e.getX(i), e.getY(i), state);
                performHapticFeedback(m instanceof StickModule ? HapticFeedbackConstants.CLOCK_TICK
                    : HapticFeedbackConstants.VIRTUAL_KEY);
                break;
            }
            case MotionEvent.ACTION_MOVE:
                for (int i = 0; i < e.getPointerCount(); i++) {
                    Module m = owner.get(e.getPointerId(i));
                    if (m != null) changed |= m.move(e.getPointerId(i), e.getX(i), e.getY(i), state);
                }
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP: {
                int id = e.getPointerId(e.getActionIndex());
                Module m = owner.get(id);
                if (m != null) {
                    changed = m.up(id, state);
                    owner.remove(id);
                }
                break;
            }
            case MotionEvent.ACTION_CANCEL:
                releaseAll();
                return true;
        }
        if (changed) {
            send();
            invalidate();
        }
        return true;
    }

    @Override
    protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        releaseAll();
        sender.shutdown();
    }
}
