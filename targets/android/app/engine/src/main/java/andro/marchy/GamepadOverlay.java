package andro.marchy;

import android.app.AlertDialog;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.SparseArray;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * On-screen game controls (targets/android/docs/controller-overlay.md), drawn over the PowOS surface.
 *
 * A layout is a list of modules, each with a zone in fractions of the overlay (one layout fits folded and
 * unfolded). In play mode a touch belongs to the topmost module whose zone it lands in and stays with it until it
 * lifts; a touch outside every module is not consumed and reaches the desktop as usual. The modules write one
 * shared pad state, sent to powos-padd (virtual gamepad in PowOS) by {@link PadSender} whenever it changes.
 *
 * Edit mode ({@link #setEditing}): drag a control to move it, drag its corner handle to resize, long-press it for
 * its options (output, mode, delete); the toolbar adds controls, resets to the preset, and saves (Done). The
 * layout is stored as JSON in the app's preferences.
 */
public final class GamepadOverlay extends View {

    private static final String TAG = "GamepadOverlay";
    private static final String PREFS = "powos_gamepad";
    private static final String KEY_LAYOUT = "layout";

    /** The built-in "gamepad" preset. Sticks are dynamic: their zone is where a thumb may land. */
    static final String DEFAULT_LAYOUT = "{\"version\":1,\"name\":\"gamepad\",\"modules\":["
        + "{\"type\":\"stick\",\"zone\":[0,0.3,0.45,1],\"mode\":\"dynamic\",\"radius\":0.08,\"deadzone\":0.1,\"output\":\"left\"},"
        + "{\"type\":\"stick\",\"zone\":[0.5,0.22,1,0.52],\"mode\":\"dynamic\",\"radius\":0.08,\"deadzone\":0.1,\"output\":\"right\"},"
        + "{\"type\":\"button\",\"zone\":[0.74,0.78,0.83,0.87],\"output\":\"a\",\"color\":\"#5fbf5f\"},"
        + "{\"type\":\"button\",\"zone\":[0.82,0.68,0.91,0.77],\"output\":\"b\",\"color\":\"#d95f5f\"},"
        + "{\"type\":\"button\",\"zone\":[0.66,0.68,0.75,0.77],\"output\":\"x\",\"color\":\"#5f8fd9\"},"
        + "{\"type\":\"button\",\"zone\":[0.74,0.58,0.83,0.67],\"output\":\"y\",\"color\":\"#d9c45f\"},"
        + "{\"type\":\"dpad\",\"zone\":[0.04,0.2,0.22,0.4]},"
        + "{\"type\":\"button\",\"zone\":[0,0.1,0.14,0.17],\"output\":\"lb\"},"
        + "{\"type\":\"trigger\",\"zone\":[0.15,0.1,0.29,0.17],\"output\":\"lt\"},"
        + "{\"type\":\"trigger\",\"zone\":[0.71,0.1,0.85,0.17],\"output\":\"rt\"},"
        + "{\"type\":\"button\",\"zone\":[0.86,0.1,1,0.17],\"output\":\"rb\"},"
        + "{\"type\":\"button\",\"zone\":[0.4,0.1,0.48,0.17],\"output\":\"back\"},"
        + "{\"type\":\"button\",\"zone\":[0.52,0.1,0.6,0.17],\"output\":\"start\"}"
        + "]}";

    static final String[] BUTTON_OUTPUTS = {"a", "b", "x", "y", "lb", "rb", "back", "start", "guide", "ls", "rs",
        "up", "down", "left", "right"};
    static final String[] BUTTON_LABELS = {"A", "B", "X", "Y", "LB", "RB", "⧉", "≡", "◉", "L3", "R3", "↑", "↓", "←", "→"};

    /** Shared state all modules write; sent as one packet. */
    static final class PadState {
        int buttons;
        float lx, ly, rx, ry, lt, rt;
    }

    /** One control. Coordinates are overlay pixels; the zone is resolved from fractions on layout. */
    abstract static class Module {
        final float[] frac = new float[4];
        final RectF zone = new RectF();
        String type, output, mode = "";
        int color = 0xFFDDDDDD;
        boolean hasColor;

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

        abstract void draw(Canvas c, Paint p, float unit, boolean editing);

        abstract void reset();

        /** The overlay this module lives in (mouse output, frame callbacks, pad state). */
        GamepadOverlay host;

        /** Type-specific settings beyond output/mode (sensitivity, friction...). */
        void configure(JSONObject o) {
        }

        JSONObject toJson() throws JSONException {
            JSONObject o = new JSONObject().put("type", type);
            JSONArray z = new JSONArray();
            for (float f : frac) z.put(Math.round(f * 1000) / 1000.0);
            o.put("zone", z);
            if (output != null) o.put("output", output);
            if (!mode.isEmpty()) o.put("mode", mode);
            if (hasColor) o.put("color", String.format("#%06x", color & 0xFFFFFF));
            return o;
        }
    }

    /** BUTTON_OUTPUTS is in powos-padd's bit order (PadSender.A = bit 0 ... RIGHT = bit 14). */
    static int buttonBit(String name) {
        for (int i = 0; i < BUTTON_OUTPUTS.length; i++) {
            if (BUTTON_OUTPUTS[i].equals(name)) return 1 << i;
        }
        throw new IllegalArgumentException("unknown button " + name);
    }

    static String buttonLabel(String output) {
        for (int i = 0; i < BUTTON_OUTPUTS.length; i++) if (BUTTON_OUTPUTS[i].equals(output)) return BUTTON_LABELS[i];
        return output;
    }

    /** Press/release; mode "toggle" latches. */
    static final class ButtonModule extends Module {
        int bit;
        boolean pressed;

        ButtonModule(String output, String mode) {
            type = "button";
            setOutput(output);
            this.mode = "toggle".equals(mode) ? "toggle" : "";
        }

        void setOutput(String o) {
            output = o;
            bit = buttonBit(o);
        }

        @Override boolean down(int id, float x, float y, PadState s) {
            pressed = "toggle".equals(mode) ? !pressed : true;
            s.buttons = pressed ? s.buttons | bit : s.buttons & ~bit;
            return true;
        }

        @Override boolean move(int id, float x, float y, PadState s) { return false; }

        @Override boolean up(int id, PadState s) {
            if ("toggle".equals(mode)) return false;
            pressed = false;
            s.buttons &= ~bit;
            return true;
        }

        @Override void reset() { pressed = false; }

        @Override void draw(Canvas c, Paint p, float unit, boolean editing) {
            float r = Math.min(zone.width(), zone.height()) / 2f;
            p.setStyle(Paint.Style.FILL);
            p.setColor(pressed ? (color & 0x00FFFFFF) | 0xAA000000 : 0x55202020);
            c.drawCircle(zone.centerX(), zone.centerY(), r, p);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(unit * 0.004f);
            p.setColor((color & 0x00FFFFFF) | 0xAA000000);
            c.drawCircle(zone.centerX(), zone.centerY(), r, p);
            drawLabel(c, p, buttonLabel(output) + ("toggle".equals(mode) ? "•" : ""), zone.centerX(), zone.centerY(), r);
        }
    }

    /** 8-way d-pad from the finger's position relative to the centre; slides between directions. */
    static final class DpadModule extends Module {
        int bits;

        DpadModule() { type = "dpad"; output = null; }

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

        @Override void reset() { bits = 0; }

        @Override void draw(Canvas c, Paint p, float unit, boolean editing) {
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
     * Analog stick. Dynamic (default): invisible until a thumb lands in the zone, then appears centred under it and
     * follows the thumb when it is dragged past the rim. Fixed: always drawn, centred in its zone.
     */
    static final class StickModule extends Module {
        boolean right;
        final float radiusFrac, deadzone;
        float radius, ox, oy, kx, ky;
        boolean active;

        StickModule(String output, String mode, float radiusFrac, float deadzone) {
            type = "stick";
            setOutput(output);
            this.mode = "fixed".equals(mode) ? "fixed" : "dynamic";
            this.radiusFrac = radiusFrac;
            this.deadzone = deadzone;
        }

        void setOutput(String o) {
            output = "right".equals(o) ? "right" : "left";
            right = "right".equals(output);
        }

        boolean dynamic() { return "dynamic".equals(mode); }

        @Override void layout(int w, int h) {
            super.layout(w, h);
            radius = radiusFrac * Math.min(w, h);
        }

        @Override JSONObject toJson() throws JSONException {
            return super.toJson().put("radius", radiusFrac).put("deadzone", deadzone);
        }

        private boolean set(float x, float y, PadState s) {
            float dx = x - ox, dy = y - oy, d = (float) Math.hypot(dx, dy);
            if (d > radius) {
                if (dynamic()) { // the base follows the thumb past the rim
                    ox = x - dx / d * radius;
                    oy = y - dy / d * radius;
                }
                dx = dx / d * radius;
                dy = dy / d * radius;
                d = radius;
            }
            kx = ox + dx;
            ky = oy + dy;
            float m = d / radius, vx = 0, vy = 0;
            if (m > deadzone && d > 0) { // output starts at 0 just outside the deadzone
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
            if (dynamic()) {
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

        @Override void reset() { active = false; }

        @Override void draw(Canvas c, Paint p, float unit, boolean editing) {
            if (editing && dynamic()) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(0x22FFFFFF);
                c.drawRect(zone, p);
                drawLabel(c, p, (right ? "R" : "L") + " stick (dynamic)", zone.centerX(), zone.centerY(), unit * 0.04f);
                return;
            }
            if (!active && dynamic()) return; // appears only under the thumb
            float cx = active ? ox : zone.centerX(), cy = active ? oy : zone.centerY();
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(unit * 0.004f);
            p.setColor(active ? 0x99FFFFFF : 0x66FFFFFF);
            c.drawCircle(cx, cy, radius, p);
            p.setStyle(Paint.Style.FILL);
            p.setColor(active ? 0xAAFFFFFF : 0x44FFFFFF);
            c.drawCircle(active ? kx : cx, active ? ky : cy, radius * 0.42f, p);
            if (editing) drawLabel(c, p, right ? "R" : "L", cx, cy, radius * 0.4f);
        }
    }

    /** Analog trigger: full on touch; sliding back up past the zone eases it off. */
    static final class TriggerModule extends Module {
        boolean right;
        float value;

        TriggerModule(String output) {
            type = "trigger";
            setOutput(output);
        }

        void setOutput(String o) {
            output = "rt".equals(o) ? "rt" : "lt";
            right = "rt".equals(output);
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
            return set(1f - Math.max(0f, (zone.top - y) / (zone.height() * 2f)), s);
        }

        @Override boolean up(int id, PadState s) { return set(0f, s); }

        @Override void reset() { value = 0; }

        @Override void draw(Canvas c, Paint p, float unit, boolean editing) {
            float rr = zone.height() * 0.3f;
            p.setStyle(Paint.Style.FILL);
            p.setColor(0x55202020);
            c.drawRoundRect(zone, rr, rr, p);
            if (value > 0) {
                p.setColor(0x88FFFFFF);
                c.drawRoundRect(zone.left, zone.top, zone.left + zone.width() * value, zone.bottom, rr, rr, p);
            }
            drawLabel(c, p, right ? "RT" : "LT", zone.centerX(), zone.centerY(), zone.height() / 2f);
        }
    }


    /** Where mouse modules send motion: the desktop's cursor (MainActivity), absolute + relative. */
    public interface Mouse {
        void move(float dx, float dy);

        void button(int button, boolean pressed);

        void scroll(int axis, float value);
    }

    static final int BTN_LEFT = 0x110, BTN_RIGHT = 0x111;
    static final float[] SENSITIVITIES = {0.8f, 1.2f, 1.6f, 2.4f, 3.2f};

    static float nextSensitivity(float s) {
        for (float v : SENSITIVITIES) if (v > s + 0.01f) return v;
        return SENSITIVITIES[0];
    }

    /**
     * Mouse region: drag moves the cursor (relative, so mouse-look games turn), tap = left click, two-finger tap =
     * right click, hold still then drag = drag with the left button, two fingers moving = scroll.
     */
    static class MousepadModule extends Module {
        float sens = 1.6f;
        final SparseArray<float[]> fingers = new SparseArray<>(); // id -> {lastX, lastY}
        long downTime;
        boolean moved, dragging, twoFinger;
        final float slop = 12f;
        final Runnable hold = () -> {
            if (!moved && fingers.size() == 1 && host != null && host.mouse != null) {
                dragging = true;
                host.mouse.button(BTN_LEFT, true);
                host.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
                host.invalidate();
            }
        };

        MousepadModule() {
            type = "mousepad";
            output = null;
        }

        @Override void configure(JSONObject o) {
            sens = (float) o.optDouble("sensitivity", sens);
        }

        @Override JSONObject toJson() throws JSONException {
            return super.toJson().put("sensitivity", sens);
        }

        String title() { return "mouse"; }

        @Override boolean down(int id, float x, float y, PadState s) {
            if (fingers.size() == 0) {
                downTime = System.currentTimeMillis();
                moved = false;
                twoFinger = false;
                if (host != null) host.handler.postDelayed(hold, 350);
            } else {
                twoFinger = true;
                if (host != null) host.handler.removeCallbacks(hold);
            }
            fingers.put(id, new float[]{x, y, x, y}); // last x/y, start x/y
            return false;
        }

        @Override boolean move(int id, float x, float y, PadState s) {
            float[] f = fingers.get(id);
            if (f == null || host == null || host.mouse == null) return false;
            float dx = x - f[0], dy = y - f[1];
            // The cursor follows from the first pixel (no dead zone before it starts); whether the touch is still a
            // tap is decided by the total travel, so a tap that wobbles a little still clicks.
            if (!moved && Math.hypot(x - f[2], y - f[3]) >= slop) {
                moved = true;
                host.handler.removeCallbacks(hold);
            }
            f[0] = x;
            f[1] = y;
            if (fingers.size() >= 2) {
                // Two fingers: scroll, from the first finger's motion only (both move together).
                if (fingers.keyAt(0) == id) {
                    if (Math.abs(dy) >= Math.abs(dx)) host.mouse.scroll(0, -dy * 0.5f);
                    else host.mouse.scroll(1, dx * 0.5f);
                }
            } else {
                motion(dx * sens, dy * sens);
            }
            return false;
        }

        void motion(float dx, float dy) {
            host.mouse.move(dx, dy);
        }

        @Override boolean up(int id, PadState s) {
            fingers.remove(id);
            if (fingers.size() > 0 || host == null) return false;
            host.handler.removeCallbacks(hold);
            if (dragging) {
                dragging = false;
                if (host.mouse != null) host.mouse.button(BTN_LEFT, false);
            } else if (!moved && System.currentTimeMillis() - downTime < 300 && host.mouse != null) {
                int b = twoFinger ? BTN_RIGHT : BTN_LEFT;
                host.mouse.button(b, true);
                host.mouse.button(b, false);
                host.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY);
            }
            return false;
        }

        @Override void reset() {
            fingers.clear();
            if (dragging && host != null && host.mouse != null) host.mouse.button(BTN_LEFT, false);
            dragging = false;
            if (host != null) host.handler.removeCallbacks(hold);
        }

        @Override void draw(Canvas c, Paint p, float unit, boolean editing) {
            float rr = unit * 0.02f;
            p.setStyle(Paint.Style.FILL);
            p.setColor(fingers.size() > 0 ? 0x33FFFFFF : 0x14FFFFFF);
            c.drawRoundRect(zone, rr, rr, p);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(unit * 0.003f);
            p.setColor(dragging ? 0xAA4FC3F7 : 0x44FFFFFF);
            c.drawRoundRect(zone, rr, rr, p);
            drawLabel(c, p, title(), zone.centerX(), zone.centerY(), unit * 0.03f);
        }
    }

    /**
     * Trackball: a mouse region whose motion keeps rolling after a flick and slows with friction; a touch stops it.
     * For camera control (strategy games, Besiege).
     */
    static final class TrackballModule extends MousepadModule {
        float friction = 0.93f, vx, vy;
        long lastMove;
        boolean rolling;
        final Runnable frame = new Runnable() {
            @Override public void run() {
                if (!rolling || host == null || host.mouse == null) return;
                vx *= friction;
                vy *= friction;
                if (Math.hypot(vx, vy) < 0.4) {
                    rolling = false;
                    host.invalidate();
                    return;
                }
                host.mouse.move(vx, vy);
                host.postOnAnimation(this);
            }
        };

        TrackballModule() {
            type = "trackball";
        }

        @Override void configure(JSONObject o) {
            super.configure(o);
            friction = (float) o.optDouble("friction", friction);
        }

        @Override JSONObject toJson() throws JSONException {
            return super.toJson().put("friction", friction);
        }

        @Override String title() { return rolling ? "trackball •" : "trackball"; }

        @Override boolean down(int id, float x, float y, PadState s) {
            if (rolling) { // a touch stops the ball
                rolling = false;
                vx = vy = 0;
            }
            return super.down(id, x, y, s);
        }

        @Override void motion(float dx, float dy) {
            super.motion(dx, dy);
            // Per-event velocity (pointer events arrive about once per frame), smoothed.
            vx = vx * 0.5f + dx * 0.5f;
            vy = vy * 0.5f + dy * 0.5f;
            lastMove = System.currentTimeMillis();
        }

        @Override boolean up(int id, PadState s) {
            boolean wasDrag = dragging;
            super.up(id, s);
            if (fingers.size() == 0 && moved && !wasDrag && !twoFinger
                    && System.currentTimeMillis() - lastMove < 60 && Math.hypot(vx, vy) > 2 && host != null) {
                rolling = true;
                host.postOnAnimation(frame);
            } else if (fingers.size() == 0) {
                vx = vy = 0;
            }
            return false;
        }

        @Override void reset() {
            super.reset();
            rolling = false;
            vx = vy = 0;
        }
    }

    /**
     * Gyro: the phone's rotation as mouse look or right stick, while switched on with its own toggle control.
     * Axes follow the screen's current rotation (landscape or portrait, folded or not).
     */
    static final class GyroModule extends Module implements android.hardware.SensorEventListener {
        boolean on, invertY;
        float sens = 1.6f;
        long lastNs;

        GyroModule(String output) {
            type = "gyro";
            this.output = "right_stick".equals(output) ? "right_stick" : "mouse";
        }

        @Override void configure(JSONObject o) {
            sens = (float) o.optDouble("sensitivity", sens);
            invertY = o.optBoolean("invert_y", false);
        }

        @Override JSONObject toJson() throws JSONException {
            return super.toJson().put("sensitivity", sens).put("invert_y", invertY);
        }

        void setOn(boolean v) {
            if (v == on || host == null) return;
            on = v;
            android.hardware.SensorManager sm =
                (android.hardware.SensorManager) host.getContext().getSystemService(Context.SENSOR_SERVICE);
            if (on) {
                android.hardware.Sensor g = sm.getDefaultSensor(android.hardware.Sensor.TYPE_GYROSCOPE);
                if (g == null) {
                    on = false;
                    return;
                }
                lastNs = 0;
                sm.registerListener(this, g, android.hardware.SensorManager.SENSOR_DELAY_GAME);
            } else {
                sm.unregisterListener(this);
                if ("right_stick".equals(output)) host.setRightStick(0, 0);
            }
            host.invalidate();
        }

        @Override public void onSensorChanged(android.hardware.SensorEvent e) {
            if (!on || host == null) return;
            // Device axes -> screen axes for the current rotation (x right, y up on screen).
            float x = e.values[0], y = e.values[1];
            int rot = host.getDisplay() != null ? host.getDisplay().getRotation() : 0;
            float sx, sy;
            switch (rot) {
                case android.view.Surface.ROTATION_90: sx = -y; sy = x; break;
                case android.view.Surface.ROTATION_180: sx = -x; sy = -y; break;
                case android.view.Surface.ROTATION_270: sx = y; sy = -x; break;
                default: sx = x; sy = y;
            }
            // Turning about the screen's vertical axis looks left/right; tilting about its horizontal axis up/down.
            float yaw = -sy, pitch = invertY ? sx : -sx;
            if ("right_stick".equals(output)) {
                host.setRightStick(clamp(yaw * sens * 0.35f), clamp(pitch * sens * 0.35f));
            } else {
                float dt = lastNs == 0 ? 0f : (e.timestamp - lastNs) / 1e9f;
                lastNs = e.timestamp;
                if (dt > 0 && dt < 0.1f && host.mouse != null) {
                    float px = 900f * sens * dt; // pixels per radian
                    host.mouse.move(yaw * px, pitch * px);
                }
            }
        }

        private static float clamp(float v) { return Math.max(-1f, Math.min(1f, v)); }

        @Override public void onAccuracyChanged(android.hardware.Sensor s, int a) {
        }

        @Override boolean down(int id, float x, float y, PadState s) {
            setOn(!on);
            return false;
        }

        @Override boolean move(int id, float x, float y, PadState s) { return false; }

        @Override boolean up(int id, PadState s) { return false; }

        @Override void reset() { setOn(false); }

        @Override void draw(Canvas c, Paint p, float unit, boolean editing) {
            float r = Math.min(zone.width(), zone.height()) / 2f;
            p.setStyle(Paint.Style.FILL);
            p.setColor(on ? 0xAA4FC3F7 : 0x55202020);
            c.drawCircle(zone.centerX(), zone.centerY(), r, p);
            drawLabel(c, p, "gyro", zone.centerX(), zone.centerY(), r * 0.8f);
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

    static Module create(String type, String output, String mode, double radius, double deadzone) {
        switch (type) {
            case "button": return new ButtonModule(output, mode);
            case "dpad": return new DpadModule();
            case "stick": return new StickModule(output, mode, (float) radius, (float) deadzone);
            case "trigger": return new TriggerModule(output);
            case "mousepad": return new MousepadModule();
            case "trackball": return new TrackballModule();
            case "gyro": return new GyroModule(output);
            default: return null;
        }
    }

    /** Builds modules from a layout's JSON (format: controller-overlay.md). */
    static List<Module> parse(String json) throws JSONException {
        JSONArray arr = new JSONObject(json).getJSONArray("modules");
        List<Module> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.getJSONObject(i);
            Module m = create(o.getString("type"), o.optString("output", "a"), o.optString("mode", ""),
                o.optDouble("radius", 0.08), o.optDouble("deadzone", 0.1));
            if (m == null) {
                Log.w(TAG, "unknown module type " + o.getString("type") + ", skipped");
                continue;
            }
            m.configure(o);
            JSONArray z = o.getJSONArray("zone");
            for (int k = 0; k < 4; k++) m.frac[k] = (float) z.getDouble(k);
            if (o.has("color")) {
                m.color = Color.parseColor(o.getString("color"));
                m.hasColor = true;
            }
            out.add(m);
        }
        return out;
    }

    static String serialize(List<Module> modules) throws JSONException {
        JSONArray arr = new JSONArray();
        for (Module m : modules) arr.put(m.toJson());
        return new JSONObject().put("version", 1).put("name", "custom").put("modules", arr).toString();
    }

    private final List<Module> modules = new ArrayList<>();
    private final SparseArray<Module> owner = new SparseArray<>();
    private final PadState state = new PadState();
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final PadSender sender;
    private final SharedPreferences prefs;

    // Edit mode
    private boolean editing;
    private Module editTarget;
    private boolean resizing;
    private float lastX, lastY, downX, downY;
    private final RectF btnAdd = new RectF(), btnReset = new RectF(), btnDone = new RectF();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable longPress = () -> {
        if (editTarget != null && !resizing) {
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
            showOptions(editTarget);
            editTarget = null;
        }
    };
    private Runnable onEditDone;
    Mouse mouse;
    /** Focused game's window class (steam_app_<id>), "" = the default layout. */
    private String gameKey = "";

    private String layoutPref() {
        return gameKey.isEmpty() ? KEY_LAYOUT : KEY_LAYOUT + ":" + gameKey;
    }

    /**
     * The focused window changed (powos-focus-watch): show that game's layout, or the default one for a game that
     * has none yet. Ignored while editing, so the editor never switches under the user.
     */
    public void setGame(String key) {
        key = key == null ? "" : key.trim();
        if (editing || key.equals(gameKey)) return;
        releaseAll();
        gameKey = key;
        load(prefs.getString(layoutPref(), prefs.getString(KEY_LAYOUT, DEFAULT_LAYOUT)));
        Log.i(TAG, "layout for " + (gameKey.isEmpty() ? "the desktop (default)" : gameKey));
    }

    public void setMouse(Mouse m) {
        mouse = m;
    }

    /** Gyro -> right stick. */
    void setRightStick(float x, float y) {
        if (x == state.rx && y == state.ry) return;
        state.rx = x;
        state.ry = y;
        send();
    }

    public GamepadOverlay(Context ctx, String padSocketPath) {
        super(ctx);
        prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        sender = new PadSender(padSocketPath);
        sender.start();
        load(prefs.getString(KEY_LAYOUT, DEFAULT_LAYOUT));
        setWillNotDraw(false);
    }

    private void load(String json) {
        modules.clear();
        try {
            modules.addAll(parse(json));
        } catch (JSONException | IllegalArgumentException e) {
            Log.w(TAG, "bad saved layout, using the preset", e);
            try {
                modules.addAll(parse(DEFAULT_LAYOUT));
            } catch (JSONException e2) {
                throw new IllegalStateException("built-in layout", e2);
            }
        }
        for (Module m : modules) m.host = this;
        if (getWidth() > 0) for (Module m : modules) m.layout(getWidth(), getHeight());
        invalidate();
    }

    private void save() {
        try {
            prefs.edit().putString(layoutPref(), serialize(modules)).apply();
        } catch (JSONException e) {
            Log.e(TAG, "could not save layout", e);
        }
    }

    /** Shows or hides the controls; hiding releases everything so nothing stays held in the game. */
    public void setShown(boolean shown) {
        setVisibility(shown ? VISIBLE : GONE);
        if (!shown) {
            setEditing(false);
            releaseAll();
        }
    }

    public boolean isEditing() { return editing; }

    /** Edit mode; leaving it saves the layout. {@code done} runs when the user taps Done. */
    public void setEditing(boolean on, Runnable done) {
        onEditDone = done;
        setEditing(on);
    }

    public void setEditing(boolean on) {
        if (on == editing) return;
        editing = on;
        Log.i(TAG, on ? "editor opened" : "editor closed, layout saved");
        if (on) {
            releaseAll();
            setVisibility(VISIBLE);
        } else {
            save();
        }
        invalidate();
    }

    private void releaseAll() {
        owner.clear();
        for (Module m : modules) m.reset();
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
        float u = Math.min(w, h), bw = u * 0.16f, bh = u * 0.055f, gap = u * 0.02f, top = u * 0.02f;
        float left = (w - (3 * bw + 2 * gap)) / 2f;
        btnAdd.set(left, top, left + bw, top + bh);
        btnReset.set(left + bw + gap, top, left + 2 * bw + gap, top + bh);
        btnDone.set(left + 2 * (bw + gap), top, left + 3 * bw + 2 * gap, top + bh);
    }

    @Override
    protected void onDraw(Canvas canvas) {
        float unit = Math.min(getWidth(), getHeight());
        if (editing) canvas.drawColor(0x44000000);
        for (Module m : modules) m.draw(canvas, paint, unit, editing);
        if (!editing) return;
        Paint p = paint;
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(unit * 0.003f);
        p.setPathEffect(new DashPathEffect(new float[]{unit * 0.01f, unit * 0.008f}, 0));
        p.setColor(0xCCFFFFFF);
        for (Module m : modules) canvas.drawRect(m.zone, p);
        p.setPathEffect(null);
        p.setStyle(Paint.Style.FILL);
        p.setColor(0xFF4FC3F7);
        for (Module m : modules) canvas.drawCircle(m.zone.right, m.zone.bottom, handleRadius(), p);
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(unit * 0.003f);
        p.setColor(0xFFFF2BD6); // guide magenta
        if (guideX >= 0) canvas.drawLine(guideX * getWidth(), 0, guideX * getWidth(), getHeight(), p);
        if (guideY >= 0) canvas.drawLine(0, guideY * getHeight(), getWidth(), guideY * getHeight(), p);
        if (sizeMatch != null) canvas.drawRect(sizeMatch.zone, p);
        drawChip(canvas, btnAdd, "+ Add", 0xCC2E7D32, unit);
        drawChip(canvas, btnReset, "Reset", 0xCC6D4C41, unit);
        drawChip(canvas, btnDone, "Done", 0xCC1565C0, unit);
        // Which layout is being edited: in the toolbar row, left of the chips (clear of the controls below).
        drawLabel(canvas, p, "Layout: " + (gameKey.isEmpty() ? "default" : gameKey), btnAdd.left / 2f,
            btnAdd.centerY(), btnAdd.height() * 0.55f);
    }

    private float handleRadius() { return Math.min(getWidth(), getHeight()) * 0.022f; }

    private void drawChip(Canvas c, RectF r, String text, int color, float unit) {
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(color);
        c.drawRoundRect(r, r.height() / 2f, r.height() / 2f, paint);
        drawLabel(c, paint, text, r.centerX(), r.centerY(), r.height() * 0.6f);
    }

    private Module moduleAt(float x, float y) {
        for (int i = modules.size() - 1; i >= 0; i--) { // topmost (last) first
            if (modules.get(i).contains(x, y)) return modules.get(i);
        }
        return null;
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        return editing ? onEditTouch(e) : onPlayTouch(e);
    }

    private boolean onPlayTouch(MotionEvent e) {
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
                // Every touch event as it arrives, not batched to the display frame: a frame less latency.
                if (action == MotionEvent.ACTION_DOWN && android.os.Build.VERSION.SDK_INT >= 30)
                    requestUnbufferedDispatch(e);
                owner.put(e.getPointerId(i), m);
                changed = m.down(e.getPointerId(i), e.getX(i), e.getY(i), state);
                // Mouse regions buzz only when they click (MousepadModule.up), not on every touch.
                if (!(m instanceof MousepadModule))
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
        if (changed) send();
        // Always redraw: a dynamic stick appears (and follows the thumb) before its output leaves the deadzone.
        invalidate();
        return true;
    }

    /** Smart guides (editor): the module being dragged snaps to these; drawn while they hold. */
    private final float[] dragStart = new float[4];
    private float guideX = -1, guideY = -1;
    private Module sizeMatch;

    private float snapTolX() { return 10f * getResources().getDisplayMetrics().density / Math.max(1, getWidth()); }

    private float snapTolY() { return 10f * getResources().getDisplayMetrics().density / Math.max(1, getHeight()); }

    /** Lines a module can align to on one axis (0 = x, 1 = y): screen edges and centre, every other module's
     *  edges and centre. */
    private List<Float> guideLines(Module self, int axis) {
        List<Float> lines = new ArrayList<>();
        lines.add(0f);
        lines.add(0.5f);
        lines.add(1f);
        for (Module m : modules) {
            if (m == self) continue;
            float a = m.frac[axis], b = m.frac[axis + 2];
            lines.add(a);
            lines.add((a + b) / 2f);
            lines.add(b);
        }
        return lines;
    }

    /** Best shift (within tol) that puts one of {@code edges} on a guide line; {@code out[1]} = the line or -1. */
    private static void bestSnap(float[] edges, List<Float> lines, float tol, float[] out) {
        float bestAbs = tol;
        out[0] = 0;
        out[1] = -1;
        for (float e : edges) {
            for (float l : lines) {
                float d = l - e;
                if (Math.abs(d) < bestAbs) {
                    bestAbs = Math.abs(d);
                    out[0] = d;
                    out[1] = l;
                }
            }
        }
    }

    private boolean onEditTouch(MotionEvent e) {
        float x = e.getX(), y = e.getY(), w = getWidth(), h = getHeight();
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: {
                if (btnAdd.contains(x, y)) { showAdd(); return true; }
                if (btnReset.contains(x, y)) { confirmReset(); return true; }
                if (btnDone.contains(x, y)) {
                    setEditing(false);
                    if (onEditDone != null) onEditDone.run();
                    return true;
                }
                editTarget = null;
                resizing = false;
                float hr = handleRadius() * 1.8f;
                for (int i = modules.size() - 1; i >= 0; i--) { // corner handles first
                    Module m = modules.get(i);
                    if (Math.hypot(x - m.zone.right, y - m.zone.bottom) < hr) {
                        editTarget = m;
                        resizing = true;
                        break;
                    }
                }
                if (editTarget == null) editTarget = moduleAt(x, y);
                if (editTarget != null) System.arraycopy(editTarget.frac, 0, dragStart, 0, 4);
                lastX = downX = x;
                lastY = downY = y;
                if (editTarget != null && !resizing) handler.postDelayed(longPress, ViewConfiguration.getLongPressTimeout());
                return true;
            }
            case MotionEvent.ACTION_MOVE: {
                if (editTarget == null) return true;
                if (Math.hypot(x - downX, y - downY) > ViewConfiguration.get(getContext()).getScaledTouchSlop())
                    handler.removeCallbacks(longPress);
                // From where the drag started (not incrementally), so a snap never sticks: the finger leads.
                float dx = (x - downX) / w, dy = (y - downY) / h;
                float[] f = editTarget.frac, s0 = dragStart, out = new float[2];
                float oldGX = guideX, oldGY = guideY;
                Module oldMatch = sizeMatch;
                sizeMatch = null;
                if (resizing) {
                    float r = Math.max(s0[0] + 0.04f, Math.min(1f, s0[2] + dx));
                    float b = Math.max(s0[1] + 0.04f, Math.min(1f, s0[3] + dy));
                    // Right/bottom edge onto a guide line, or the same width/height as another control.
                    bestSnap(new float[]{r}, guideLines(editTarget, 0), snapTolX(), out);
                    guideX = out[1];
                    r += out[0];
                    bestSnap(new float[]{b}, guideLines(editTarget, 1), snapTolY(), out);
                    guideY = out[1];
                    b += out[0];
                    if (guideX < 0 || guideY < 0) {
                        for (Module m : modules) {
                            if (m == editTarget) continue;
                            float mw = m.frac[2] - m.frac[0], mh = m.frac[3] - m.frac[1];
                            if (guideX < 0 && Math.abs((r - s0[0]) - mw) < snapTolX()) { r = s0[0] + mw; sizeMatch = m; }
                            if (guideY < 0 && Math.abs((b - s0[1]) - mh) < snapTolY()) { b = s0[1] + mh; sizeMatch = m; }
                        }
                    }
                    f[2] = r;
                    f[3] = b;
                } else {
                    float zw = s0[2] - s0[0], zh = s0[3] - s0[1];
                    float l = Math.max(0f, Math.min(1f - zw, s0[0] + dx));
                    float t = Math.max(0f, Math.min(1f - zh, s0[1] + dy));
                    // Left, centre or right edge onto a guide (screen edge/centre, another control's edge/centre).
                    bestSnap(new float[]{l, l + zw / 2f, l + zw}, guideLines(editTarget, 0), snapTolX(), out);
                    guideX = out[1];
                    l = Math.max(0f, Math.min(1f - zw, l + out[0]));
                    bestSnap(new float[]{t, t + zh / 2f, t + zh}, guideLines(editTarget, 1), snapTolY(), out);
                    guideY = out[1];
                    t = Math.max(0f, Math.min(1f - zh, t + out[0]));
                    f[0] = l;
                    f[1] = t;
                    f[2] = l + zw;
                    f[3] = t + zh;
                }
                // A tick when something new snaps, like Photoshop's guides catching.
                if ((guideX >= 0 && guideX != oldGX) || (guideY >= 0 && guideY != oldGY) || (sizeMatch != null && sizeMatch != oldMatch))
                    performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK);
                lastX = x;
                lastY = y;
                editTarget.layout(getWidth(), getHeight());
                invalidate();
                return true;
            }
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                handler.removeCallbacks(longPress);
                guideX = guideY = -1;
                sizeMatch = null;
                if (editTarget != null) {
                    editTarget.layout(getWidth(), getHeight());
                    editTarget = null;
                }
                invalidate();
                return true;
        }
        return true;
    }

    private void showAdd() {
        final String[] items = {"Button A", "Button B", "Button X", "Button Y", "Bumper LB", "Bumper RB", "Back",
            "Start", "Guide", "Stick click L3", "Stick click R3", "D-pad", "Left stick", "Right stick",
            "Trigger LT", "Trigger RT", "Mouse region", "Trackball", "Gyro (toggle)"};
        new AlertDialog.Builder(getContext()).setTitle("Add control").setItems(items, (d, which) -> {
            Module m;
            if (which <= 10) m = new ButtonModule(BUTTON_OUTPUTS[which], "");
            else if (which == 11) m = new DpadModule();
            else if (which <= 13) m = new StickModule(which == 12 ? "left" : "right", "dynamic", 0.08f, 0.1f);
            else if (which <= 15) m = new TriggerModule(which == 14 ? "lt" : "rt");
            else if (which == 16) m = new MousepadModule();
            else if (which == 17) m = new TrackballModule();
            else m = new GyroModule("mouse");
            m.host = this;
            boolean area = m instanceof MousepadModule;
            float sw = area ? 0.35f : m instanceof StickModule ? 0.3f : m instanceof DpadModule ? 0.18f : m instanceof TriggerModule ? 0.14f : 0.09f;
            float sh = area ? 0.35f : m instanceof StickModule ? 0.3f : m instanceof DpadModule ? 0.2f : m instanceof TriggerModule ? 0.07f : 0.09f;
            m.frac[0] = 0.5f - sw / 2;
            m.frac[1] = 0.45f - sh / 2;
            m.frac[2] = 0.5f + sw / 2;
            m.frac[3] = 0.45f + sh / 2;
            m.layout(getWidth(), getHeight());
            modules.add(m);
            invalidate();
        }).show();
    }

    private void confirmReset() {
        new AlertDialog.Builder(getContext()).setTitle("Reset controls?")
            .setMessage("Go back to the default gamepad layout.")
            .setPositiveButton("Reset", (d, w) -> load(DEFAULT_LAYOUT))
            .setNegativeButton("Cancel", null).show();
    }

    private void showOptions(Module m) {
        List<String> items = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        if (m instanceof ButtonModule) {
            ButtonModule b = (ButtonModule) m;
            items.add("Output: " + buttonLabel(b.output) + "  (change)");
            actions.add(() -> new AlertDialog.Builder(getContext()).setTitle("Button output")
                .setItems(BUTTON_LABELS, (d, i) -> { b.setOutput(BUTTON_OUTPUTS[i]); invalidate(); }).show());
            items.add("toggle".equals(b.mode) ? "Mode: toggle  (switch to hold)" : "Mode: hold  (switch to toggle)");
            actions.add(() -> { b.mode = "toggle".equals(b.mode) ? "" : "toggle"; invalidate(); });
        } else if (m instanceof StickModule) {
            StickModule s = (StickModule) m;
            items.add((s.right ? "Right" : "Left") + " stick  (swap)");
            actions.add(() -> { s.setOutput(s.right ? "left" : "right"); invalidate(); });
            items.add(s.dynamic() ? "Dynamic  (switch to fixed)" : "Fixed  (switch to dynamic)");
            actions.add(() -> { s.mode = s.dynamic() ? "fixed" : "dynamic"; invalidate(); });
        } else if (m instanceof TriggerModule) {
            TriggerModule t = (TriggerModule) m;
            items.add((t.right ? "RT" : "LT") + "  (swap)");
            actions.add(() -> { t.setOutput(t.right ? "lt" : "rt"); invalidate(); });
        }
        if (m instanceof MousepadModule) {
            MousepadModule mp = (MousepadModule) m;
            items.add("Sensitivity " + mp.sens + "  (change)");
            actions.add(() -> { mp.sens = nextSensitivity(mp.sens); invalidate(); });
        } else if (m instanceof GyroModule) {
            GyroModule g = (GyroModule) m;
            items.add("Output: " + ("right_stick".equals(g.output) ? "right stick" : "mouse") + "  (swap)");
            actions.add(() -> { g.setOn(false); g.output = "right_stick".equals(g.output) ? "mouse" : "right_stick"; invalidate(); });
            items.add("Sensitivity " + g.sens + "  (change)");
            actions.add(() -> g.sens = nextSensitivity(g.sens));
            items.add(g.invertY ? "Up/down inverted  (normal)" : "Up/down normal  (invert)");
            actions.add(() -> g.invertY = !g.invertY);
        }
        items.add("Delete");
        actions.add(() -> { modules.remove(m); invalidate(); });
        new AlertDialog.Builder(getContext()).setTitle("Control")
            .setItems(items.toArray(new String[0]), (d, i) -> actions.get(i).run()).show();
    }

    @Override
    protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        handler.removeCallbacks(longPress);
        releaseAll();
        sender.shutdown();
    }
}
