// S1 permission probe for docs/WEB_WINDOWS.md (throwaway, not shipped). Nothing is shown and nothing is launched:
// every display's output is a 1x1 ImageReader in this process, the mirror is never put on a layer stack.
//
//   P1 make <pkg> <flagsHex> <holdMs>   create a VD as <pkg> (run under that package's uid: `su -c '...' <uid>`), try
//                                       mirrorDisplay on it, VirtualDisplay.resize, print "VD <id>", hold, release
//   P1 mirror <pkg> <displayId>          mirrorDisplay of a VD another process made, as <pkg>'s uid
//   P1 allowed <pkg> <displayId> <component>   ActivityManager.isActivityStartAllowedOnDisplay as <pkg>'s uid: the
//                                       same check (canPlaceEntityOnDisplay) ActivityStarter makes before it moves a
//                                       launch to the default display
import android.app.ActivityManager;
import android.content.AttributionSource;
import android.content.ComponentName;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.ImageReader;
import android.os.Looper;
import android.os.SystemClock;
import android.view.SurfaceControl;

import java.lang.reflect.*;

public class P1 {
    static String pkg;

    static Object hidden(Object target, String name, Object... args) throws Exception {
        Class<?> k = target instanceof Class ? (Class<?>) target : target.getClass();
        for (Class<?> c = k; c != null; c = c.getSuperclass())
            for (Method m : c.getDeclaredMethods())
                if (m.getName().equals(name) && m.getParameterCount() == args.length) {
                    m.setAccessible(true);
                    return m.invoke(target instanceof Class ? null : target, args);
                }
        throw new NoSuchMethodException(k + "." + name);
    }

    static class FakeContext extends ContextWrapper {
        FakeContext(Context base) { super(base); }
        @Override public String getPackageName() { return pkg; }
        @Override public String getOpPackageName() { return pkg; }
        @Override public AttributionSource getAttributionSource() {
            return new AttributionSource.Builder(android.os.Process.myUid()).setPackageName(pkg).build();
        }
        @Override public Context getApplicationContext() { return this; }
    }

    static Context context() throws Exception {
        Class<?> at = Class.forName("android.app.ActivityThread");
        Constructor<?> c = at.getDeclaredConstructor();
        c.setAccessible(true);
        Object t = c.newInstance();
        Field f = at.getDeclaredField("sCurrentActivityThread"); f.setAccessible(true); f.set(null, t);
        Field s = at.getDeclaredField("mSystemThread"); s.setAccessible(true); s.setBoolean(t, true);
        return new FakeContext((Context) hidden(t, "getSystemContext"));
    }

    static void log(String s) { System.out.println("P1 uid=" + android.os.Process.myUid() + " " + s); }

    public static void main(String[] a) throws Exception {
        Looper.prepareMainLooper();
        pkg = a[1];
        Context ctx = context();
        if (a[0].equals("allowed")) {
            int id = Integer.parseInt(a[2]);
            Intent i = new Intent(Intent.ACTION_MAIN).setComponent(ComponentName.unflattenFromString(a[3])).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ActivityManager am = ctx.getSystemService(ActivityManager.class);
            try {
                log("isActivityStartAllowedOnDisplay(" + id + ", " + a[3] + ") = " + am.isActivityStartAllowedOnDisplay(ctx, id, i));
            } catch (Throwable e) { log("isActivityStartAllowedOnDisplay threw " + e); }
            System.exit(0);
        }
        if (a[0].equals("mirror")) {
            int id = Integer.parseInt(a[2]);
            Object wm = Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null);
            Constructor<SurfaceControl> k = SurfaceControl.class.getDeclaredConstructor(); k.setAccessible(true);
            SurfaceControl m = k.newInstance();
            try { log("mirrorDisplay(" + id + ") of another uid's VD = " + hidden(wm, "mirrorDisplay", id, m) + " valid=" + m.isValid()); }
            catch (InvocationTargetException e) { log("mirrorDisplay threw " + e.getCause()); }
            System.exit(0);
        }
        int flags = Integer.decode(a[2]);
        long hold = Long.parseLong(a[3]);
        DisplayManager dm = DisplayManager.class.getDeclaredConstructor(Context.class).newInstance(ctx);
        ImageReader r = ImageReader.newInstance(1, 1, PixelFormat.RGBA_8888, 2);
        VirtualDisplay vd = null;
        try {
            vd = dm.createVirtualDisplay("p1-probe", 640, 480, 320, r.getSurface(), flags);
        } catch (Throwable e) { log("createVirtualDisplay flags=0x" + Integer.toHexString(flags) + " threw " + e); System.exit(0); }
        if (vd == null) { log("createVirtualDisplay flags=0x" + Integer.toHexString(flags) + " -> null"); System.exit(0); }
        int id = vd.getDisplay().getDisplayId();
        log("VD " + id + " flags=0x" + Integer.toHexString(flags) + " displayFlags=0x" + Integer.toHexString(vd.getDisplay().getFlags()) + " state=" + vd.getDisplay().getState());
        Object wm = Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null);
        long t0 = SystemClock.uptimeMillis();
        String result = "?";
        for (int i = 0; i < 100; i++) {
            Constructor<SurfaceControl> k = SurfaceControl.class.getDeclaredConstructor(); k.setAccessible(true);
            SurfaceControl m = k.newInstance();
            try {
                boolean ok = (Boolean) hidden(wm, "mirrorDisplay", id, m);
                if (ok && m.isValid()) {
                    SurfaceControl parent = new SurfaceControl.Builder().setName("p1-parent").build();
                    new SurfaceControl.Transaction().reparent(m, parent).setVisibility(m, true).apply();
                    result = "true after " + (SystemClock.uptimeMillis() - t0) + " ms (" + i + " retries), reparented ok";
                    m.release(); parent.release();
                    break;
                }
                result = "false (" + (SystemClock.uptimeMillis() - t0) + " ms)";
            } catch (InvocationTargetException e) { result = "threw " + e.getCause(); break; }
            Thread.sleep(20);
        }
        log("mirrorDisplay(" + id + ") " + result);
        try { vd.resize(320, 240, 320); log("resize ok"); } catch (Throwable e) { log("resize threw " + e); }
        System.out.println("VD " + id);
        System.out.flush();
        Thread.sleep(hold);
        vd.release();
        r.close();
        log("released");
        System.exit(0);
    }
}
