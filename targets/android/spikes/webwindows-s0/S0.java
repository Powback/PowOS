// S0 de-risk spike for docs/WEB_WINDOWS.md (questions U1/R1 and U3/R3). Throwaway, not shipped.
// Runs as shell through app_process (see run.sh). Everything is offscreen: two virtual displays whose output goes to
// ImageReaders in this process; Chrome is started fresh on display A and removed with it.
//
//   A  "s0-app"  720x800  PUBLIC|OWN_CONTENT_ONLY|DESTROY_CONTENT_ON_REMOVAL (the WebWindows.kt flags)  Chrome runs here
//   B  "s0-home" 1600x800 OWN_CONTENT_ONLY, output = ImageReader rB      stands in for home's display
//   host  a root container layer put on B's layer stack       stands in for home's window surface
//     mirror  IWindowManager.mirrorDisplay(A) reparented under host at x=0      the zero-copy path (S3)
//     copy    buffer layer at x=800; A's output Surface = Surface(copy)          the one-copy path (S1)
//
// The page counts requestAnimationFrame calls and paints the low 8 bits as 8 black/white blocks, so every rB frame
// says which Chrome frame each path shows. lag = mirror counter - copy counter.
import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Display;
import android.view.Surface;
import android.view.SurfaceControl;

import java.io.*;
import java.lang.reflect.*;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.*;

public class S0 {
    static final int AW = 720, AH = 800, DPI = 320, BW = 1600, BH = 800, COPY_X = 800;
    static final String OUT = "/data/local/tmp/s0";
    static final String PAGE = "<!doctype html><meta name=viewport content='width=device-width'><body style='margin:0;background:#888'>"
        + "<input id=t placeholder='type here' style='position:fixed;left:2%;top:4%;width:90%;height:14%;font-size:28px'>"
        + "<canvas id=c style='position:fixed;left:0;top:30%;width:100%;height:40%'></canvas><script>"
        + "let n=0;const c=document.getElementById('c'),g=c.getContext('2d');c.width=800;c.height=100;"
        + "function f(){n++;for(let i=0;i<8;i++){g.fillStyle=(n>>i)&1?'#fff':'#000';g.fillRect(i*100,0,100,100);}"
        + "requestAnimationFrame(f);}requestAnimationFrame(f);"
        + "document.getElementById('t').addEventListener('input',e=>console.log('S0INPUT '+e.target.value));"
        + "</script>";

    // --- per-frame decode of rB -------------------------------------------------------------------------------
    static volatile String phase = "boot";
    static final Map<String, Stats> stats = new LinkedHashMap<>();
    static volatile boolean wantPng;
    static volatile String pngName;

    static class Stats {
        int frames, mirrorChanges, copyChanges, lastM = -1, lastC = -1;
        long t0 = -1, t1;
        final TreeMap<Integer, Integer> lag = new TreeMap<>();
        List<String> trace = new ArrayList<>();
        String line() {
            double s = (t1 - t0) / 1e9;
            return String.format(Locale.ROOT, "frames=%d over %.1fs | mirror: %d new Chrome frames (%.1f/s) | copy: %d (%.1f/s) | lag(mirror-copy, frames)=%s",
                frames, s, mirrorChanges, mirrorChanges / s, copyChanges, copyChanges / s, lag) + "\n    trace(ms:mirror/copy) " + trace;
        }
    }

    static int decode(ByteBuffer buf, int stride, int x0) {
        int v = 0, y = (int) (AH * 0.5);
        for (int i = 0; i < 8; i++) {
            int x = x0 + (int) ((i + 0.5) * AW / 8.0);
            int o = (y * stride + x) * 4;
            int lum = (buf.get(o) & 255) + (buf.get(o + 1) & 255) + (buf.get(o + 2) & 255);
            if (lum > 3 * 200) v |= 1 << i;
            else if (lum > 3 * 50) return -1; // not a block (gray background, toolbar, nothing drawn)
        }
        return v;
    }

    static void onImage(ImageReader r) {
        Image im = r.acquireLatestImage();
        if (im == null) return;
        try {
            Image.Plane p = im.getPlanes()[0];
            ByteBuffer b = p.getBuffer();
            int stride = p.getRowStride() / 4;
            int m = decode(b, stride, 0), c = decode(b, stride, COPY_X);
            Stats s;
            synchronized (stats) { s = stats.computeIfAbsent(phase, k -> new Stats()); }
            if (s.t0 < 0) s.t0 = im.getTimestamp();
            s.t1 = im.getTimestamp();
            s.frames++;
            if (m != s.lastM && s.trace.size() < 40) s.trace.add(String.format(Locale.ROOT, "%.0f:m%d/c%d", (im.getTimestamp() - s.t0) / 1e6, m, c));
            if (m >= 0 && m != s.lastM) { s.mirrorChanges++; s.lastM = m; }
            if (c >= 0 && c != s.lastC) { s.copyChanges++; s.lastC = c; }
            if (m >= 0 && c >= 0) s.lag.merge((m - c) & 255, 1, Integer::sum);
            if (wantPng) {
                wantPng = false;
                Bitmap bm = Bitmap.createBitmap(stride, BH, Bitmap.Config.ARGB_8888);
                b.rewind();
                bm.copyPixelsFromBuffer(b);
                try (FileOutputStream fo = new FileOutputStream(OUT + "/" + pngName + ".png")) {
                    Bitmap.createBitmap(bm, 0, 0, BW, BH).compress(Bitmap.CompressFormat.PNG, 90, fo);
                } catch (IOException e) { log("png: " + e); }
            }
        } finally { im.close(); }
    }

    // --- helpers ------------------------------------------------------------------------------------------------
    static PrintStream logf;
    static void log(String s) {
        String l = String.format(Locale.ROOT, "%8.3f %s", SystemClock.uptimeMillis() / 1000.0, s);
        System.out.println(l);
        if (logf != null) logf.println(l);
    }
    static String sh(String cmd) {
        try {
            Process p = new ProcessBuilder("sh", "-c", cmd).redirectErrorStream(true).start();
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            p.getInputStream().transferTo(o);
            p.waitFor();
            return o.toString().trim();
        } catch (Exception e) { return "sh failed: " + e; }
    }
    static void dump(String name) {
        sh("dumpsys activity activities > " + OUT + "/" + name + ".activities.txt; dumpsys SurfaceFlinger > " + OUT + "/" + name
            + ".sf.txt; dumpsys SurfaceFlinger --list > " + OUT + "/" + name + ".sflist.txt; dumpsys display > " + OUT + "/" + name + ".display.txt");
    }
    static String chromeState() {
        return sh("dumpsys activity activities | grep -A12 'Hist.*com.android.chrome' | grep -oE 'state=[A-Z_]+|displayId=[0-9]+|mVisibleRequested=[a-z]+' | sort -u | tr '\\n' ' '");
    }
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
        @Override public String getPackageName() { return "com.android.shell"; }
        @Override public String getOpPackageName() { return "com.android.shell"; }
        @Override public AttributionSource getAttributionSource() {
            return new AttributionSource.Builder(android.os.Process.myUid()).setPackageName("com.android.shell").build();
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

    static void serve(ServerSocket ss) {
        while (!ss.isClosed()) {
            try (Socket s = ss.accept()) {
                BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream()));
                String req = in.readLine();
                while (true) { String l = in.readLine(); if (l == null || l.isEmpty()) break; }
                byte[] body = PAGE.getBytes("UTF-8");
                OutputStream o = s.getOutputStream();
                o.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: " + body.length
                    + "\r\nConnection: close\r\n\r\n").getBytes());
                o.write(body);
                log("http: " + req);
            } catch (IOException e) { /* closed */ }
        }
    }

    static void phase(String name, int ms) throws Exception {
        synchronized (stats) { phase = name; }
        Thread.sleep(ms / 2);
        pngName = name; wantPng = true;
        log(name + ": chrome " + chromeState() + "| displayA state=" + st(dispA));
        dump(name);
        Thread.sleep(ms / 2);
        Stats s = stats.get(name);
        log(name + ": " + (s == null ? "no rB frames at all" : s.line()));
    }

    static Display dispA;
    static volatile boolean pokeOn = !"0".equals(System.getenv("S0_POKE"));
    static String st(Display d) { try { return (String) hidden(Display.class, "stateToString", d.getState()); } catch (Exception e) { return "" + d.getState(); } }

    public static void main(String[] args) throws Exception {
        new File(OUT).mkdirs();
        logf = new PrintStream(new FileOutputStream(OUT + "/log.txt"), true);
        Looper.prepareMainLooper();
        String mode = args.length > 0 ? args[0] : "mirror";
        int extraFlags = args.length > 1 ? Integer.decode(args[1]) : 0;
        Context ctx = context();
        DisplayManager dm = DisplayManager.class.getDeclaredConstructor(Context.class).newInstance(ctx);
        HandlerThread ht = new HandlerThread("rB"); ht.start();
        Handler h = new Handler(ht.getLooper());

        ServerSocket ss = new ServerSocket(8765, 4, java.net.InetAddress.getByName("127.0.0.1"));
        new Thread(() -> serve(ss)).start();

        ImageReader rB = ImageReader.newInstance(BW, BH, PixelFormat.RGBA_8888, 3);
        rB.setOnImageAvailableListener(S0::onImage, h);
        final int OWN = DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY, PUB = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC;
        VirtualDisplay vB = dm.createVirtualDisplay("s0-home", BW, BH, DPI, rB.getSurface(), OWN | extraFlags);
        VirtualDisplay vA = null;
        SurfaceControl host = null, copy = null;
        SurfaceControl mirror = null;
        try {
            Object infoB = hidden(Class.forName("android.hardware.display.DisplayManagerGlobal").getMethod("getInstance").invoke(null),
                "getDisplayInfo", vB.getDisplay().getDisplayId());
            int lsB = infoB.getClass().getField("layerStack").getInt(infoB);
            log("B id=" + vB.getDisplay().getDisplayId() + " layerStack=" + lsB);

            SurfaceControl.Builder hb = new SurfaceControl.Builder().setName("s0-host");
            hidden(hb, "setContainerLayer");
            host = hb.build();
            copy = new SurfaceControl.Builder().setName("s0-copy").setBufferSize(AW, AH).setFormat(PixelFormat.RGBA_8888).setParent(host).build();
            SurfaceControl.Transaction t = new SurfaceControl.Transaction();
            hidden(t, "setLayerStack", host, lsB);
            t.setLayer(host, 1_000_000).setVisibility(host, true).setPosition(copy, COPY_X, 0).setVisibility(copy, true).apply();
            Surface copySurface = new Surface(copy);

            int flagsA = PUB | OWN | (1 << 8) | extraFlags;
            vA = dm.createVirtualDisplay("s0-app", AW, AH, DPI, copySurface, flagsA);
            dispA = vA.getDisplay();
            int idA = dispA.getDisplayId();
            log("A id=" + idA + " flags=0x" + Integer.toHexString(flagsA) + " state=" + st(dispA));

            Object wm = Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null);
            for (int i = 0; i < 40 && !sh("dumpsys window displays").contains("mDisplayId=" + idA); i++) Thread.sleep(50);
            log("A known to WM: " + sh("dumpsys window displays | grep -E 'mDisplayId=" + idA + "' | head -1"));
            try {
                { Constructor<SurfaceControl> k = SurfaceControl.class.getDeclaredConstructor(); k.setAccessible(true); mirror = k.newInstance(); }
                boolean ok = (Boolean) hidden(wm, "mirrorDisplay", idA, mirror);
                log("mirrorDisplay(" + idA + ") -> " + ok + " valid=" + mirror.isValid());
                if (ok && mirror.isValid()) {
                    new SurfaceControl.Transaction().reparent(mirror, host).setCrop(mirror, new Rect(0, 0, AW, AH))
                        .setVisibility(mirror, true).apply();
                } else mirror = null;
            } catch (InvocationTargetException e) {
                log("mirrorDisplay threw " + e.getCause());
                mirror = null;
            }
            if (mode.equals("ime")) {
                try {
                    hidden(wm, "setDisplayImePolicy", idA, Integer.parseInt(args.length > 2 ? args[2] : "1"));
                    log("setDisplayImePolicy(" + idA + ", " + (args.length > 2 ? args[2] : "1") + ") ok");
                } catch (InvocationTargetException e) { log("setDisplayImePolicy threw " + e.getCause()); }
            }

            // The phone's own screen is off (dozing) while this runs; A and B are in their own display group (flag
            // 1<<11), which would time out like a screen. Keep that group awake with user activity on A only.
            final int idAf = idA;
            Object pm = Class.forName("android.os.IPowerManager$Stub").getMethod("asInterface", android.os.IBinder.class)
                .invoke(null, Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "power"));
            Thread poke = new Thread(() -> {
                while (!Thread.interrupted()) {
                    if (pokeOn) try { hidden(pm, "userActivity", idAf, SystemClock.uptimeMillis(), 0, 0); } catch (Exception e) { log("poke: " + e); pokeOn = false; }
                    try { Thread.sleep(2000); } catch (InterruptedException e) { return; }
                }
            });
            poke.setDaemon(true);
            if (pokeOn) poke.start();
            log("am start: " + sh("am start --display " + idA + " -W -a android.intent.action.VIEW -d http://127.0.0.1:8765/ -f 0x18000000 com.android.chrome"));
            Thread.sleep(1500);
            String where = sh("dumpsys activity activities | grep -E 'Display #|Hist.*com.android.chrome'");
            log("chrome placement: " + where.replace('\n', '|'));
            if (Arrays.stream(where.split("Display #")).anyMatch(seg -> seg.startsWith("0 ") && seg.contains("com.android.chrome"))) {
                String tid = sh("dumpsys activity activities | grep -oE 'com.android.chrome/[^ ]+ t[0-9]+' | head -1 | grep -oE '[0-9]+$'");
                log("Chrome landed on display 0: removing task " + tid + ": " + sh("am stack remove " + tid));
                return;
            }
            phase("p0-warmup", 8000);

            if (mode.equals("mirror")) {
                phase("p1-surface-on", 10000);
                vA.setSurface(null);
                log("A.setSurface(null)");
                phase("p2-surface-null", 10000);
                ImageReader unread = ImageReader.newInstance(AW, AH, PixelFormat.RGBA_8888, 1);
                vA.setSurface(unread.getSurface());
                log("A.setSurface(unread ImageReader, maxImages 1)");
                phase("p3-unread-reader", 10000);
                ImageReader tiny = ImageReader.newInstance(1, 1, PixelFormat.RGBA_8888, 2);
                tiny.setOnImageAvailableListener(r -> { Image i = r.acquireLatestImage(); if (i != null) i.close(); }, h);
                vA.setSurface(tiny.getSurface());
                log("A.setSurface(1x1 ImageReader, read)");
                phase("p4-1x1-reader", 10000);
                vA.setSurface(copySurface);
                new SurfaceControl.Transaction().setVisibility(copy, false).apply();
                log("A.setSurface(copy) and copy layer hidden");
                phase("p5-copy-hidden", 10000);
                new SurfaceControl.Transaction().setVisibility(copy, true).setVisibility(mirror, false).apply();
                log("copy shown, mirror hidden");
                phase("p6-mirror-hidden", 8000);
                if ("1".equals(System.getenv("S0_SHORT"))) return;
                new SurfaceControl.Transaction().setVisibility(mirror, true).apply();
                vA.setSurface(null);
                Thread.sleep(65000);
                log("A surface null for 65 s");
                phase("p7-null-after-65s", 6000);
                unread.close(); tiny.close();
            } else {
                // IME: tap the page's text field on A, then read the IME state.
                log("ime before: " + sh("dumpsys input_method | grep -E 'mCurFocusedWindow=|mCurTokenDisplayId|mInputShown|mCurClient=|mVisibleBound|mShowRequested|imeShowing|mCurMethodId|displayId' | head -20"));
                log("tap: " + sh("input -d " + idA + " tap " + (System.getenv("S0_TAP") != null ? System.getenv("S0_TAP") : "360 190")));
                Thread.sleep(2500);
                phase("ime-after-tap", 4000);
                log("ime after: " + sh("dumpsys input_method | grep -E 'mCurFocusedWindow=|mCurTokenDisplayId|mInputShown|mCurClient=|mVisibleBound|mShowRequested|imeShowing|mCurMethodId|mServedView|displayId' | head -30"));
                log("wm focus: " + sh("dumpsys window | grep -E 'mCurrentFocus|mFocusedApp|mTopFocusedDisplayId|imeLayeringTarget|imeInputTarget|imeControlTarget' | head"));
                log("ime window: " + sh("dumpsys window windows | grep -B2 -A3 'InputMethod' | grep -E 'Window #|mDisplayId|isVisible|mHasSurface|mViewVisibility' | head"));
                sh("dumpsys input_method > " + OUT + "/ime.txt; dumpsys window > " + OUT + "/window.txt");
                if (args.length > 3) {
                    log("type via IME-local taps: " + sh(args[3]));
                    Thread.sleep(1500);
                    phase("ime-after-typing", 3000);
                }
            }
        } finally {
            log("cleanup");
            String tids = sh("dumpsys activity recents | grep -E 'Recent #.*com.android.chrome' | grep -oE '#[0-9]+ type' | grep -oE '[0-9]+'");
            if (vA != null) vA.release();
            Thread.sleep(500);
            // DESTROY_CONTENT_ON_REMOVAL finishes Chrome's activity but leaves its task in recents: remove it (Chrome
            // had no task before this run, so every Chrome task here is ours).
            for (String tid : tids.split("\\s+")) if (!tid.isEmpty()) log("remove chrome task " + tid + ": " + sh("am stack remove " + tid));
            if (mirror != null) mirror.release();
            if (copy != null) copy.release();
            if (host != null) host.release();
            vB.release();
            rB.close();
            ss.close();
            Thread.sleep(1500);
            log("after cleanup, chrome tasks: [" + sh("dumpsys activity activities | grep -E 'Hist.*com.android.chrome'; dumpsys activity recents | grep -E 'Recent #.*chrome'") + "]");
            log("after cleanup, displays: " + sh("dumpsys display | grep -cE 's0-(app|home)'") + " s0 lines in dumpsys display");
            ht.quitSafely();
            System.exit(0);
        }
    }
}
