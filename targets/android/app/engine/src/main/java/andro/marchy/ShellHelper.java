package andro.marchy;

import android.annotation.SuppressLint;
import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.graphics.PixelFormat;
import android.hardware.HardwareBuffer;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.os.Looper;
import android.os.Process;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Constructor;

/**
 * PowOS: the privileged helper behind "Android apps as PowOS windows" (docs/android-windows.md). It runs as the
 * shell user, started through adb from the PowOS APK:
 *   adb shell CLASSPATH=$(pm path com.powos.app | cut -d: -f2) app_process /system/bin andro.marchy.ShellHelper ...
 * Shell may create TRUSTED virtual displays (which can host other apps' activities) and inject input into them;
 * an app may not. The approach (system context, shell-identity context, flag set) follows scrcpy's server
 * ("new display" mode, Apache-2.0, github.com/Genymobile/scrcpy); written for PowOS.
 *
 * Step 1 (this file today): `probe <package> <width> <height> <dpi>`: virtual display backed by GPU buffers,
 * launch the app onto it, report the frames it renders for 10 s.
 */
public final class ShellHelper {
    // DisplayManager.VIRTUAL_DISPLAY_FLAG_* (hidden ones by value, as in AOSP).
    private static final int PUBLIC = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC;
    private static final int PRESENTATION = DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION;
    private static final int OWN_CONTENT_ONLY = DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY;
    private static final int SUPPORTS_TOUCH = 1 << 6;
    private static final int DESTROY_CONTENT_ON_REMOVAL = 1 << 8;
    private static final int TRUSTED = 1 << 10;
    private static final int OWN_DISPLAY_GROUP = 1 << 11;
    private static final int ALWAYS_UNLOCKED = 1 << 12;
    private static final int TOUCH_FEEDBACK_DISABLED = 1 << 13;
    private static final int OWN_FOCUS = 1 << 14;

    private ShellHelper() {}

    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        if (args.length == 5 && args[0].equals("probe")) {
            probe(args[1], Integer.parseInt(args[2]), Integer.parseInt(args[3]), Integer.parseInt(args[4]));
        } else if (args.length == 2 && args[0].equals("connect-test")) {
            connectTest(args[1]);
        } else if (args.length == 1 && args[0].equals("listen-test")) {
            listenTest();
        } else {
            System.err.println("usage: ShellHelper probe <package> <width> <height> <dpi> | connect-test <abstract-name> | listen-test");
            System.exit(2);
        }
        System.exit(0);
    }

    private static void probe(String pkg, int w, int h, int dpi) throws Exception {
        System.out.println("uid=" + Process.myUid());
        ImageReader reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE | HardwareBuffer.USAGE_GPU_COLOR_OUTPUT);
        int flags = PUBLIC | PRESENTATION | OWN_CONTENT_ONLY | SUPPORTS_TOUCH | DESTROY_CONTENT_ON_REMOVAL
                | TRUSTED | OWN_DISPLAY_GROUP | ALWAYS_UNLOCKED | TOUCH_FEEDBACK_DISABLED | OWN_FOCUS;
        VirtualDisplay vd = displayManager().createVirtualDisplay("powos:" + pkg, w, h, dpi, reader.getSurface(), flags);
        int displayId = vd.getDisplay().getDisplayId();
        System.out.println("virtual display " + displayId + " " + w + "x" + h + "@" + dpi);

        String component = sh("cmd package resolve-activity --brief -a android.intent.action.MAIN"
                + " -c android.intent.category.LAUNCHER " + pkg).trim();
        component = component.substring(component.lastIndexOf('\n') + 1);
        System.out.println("launch " + component + ": "
                + sh("am start --display " + displayId + " -n " + component).trim().replace('\n', ' '));

        int frames = 0;
        long end = System.currentTimeMillis() + 10_000;
        while (System.currentTimeMillis() < end) {
            Image img = reader.acquireLatestImage();
            if (img != null) {
                if (frames++ == 0) {
                    HardwareBuffer hb = img.getHardwareBuffer();
                    System.out.println("first frame: " + hb.getWidth() + "x" + hb.getHeight() + " format=" + hb.getFormat()
                            + " usage=0x" + Long.toHexString(hb.getUsage()));
                    hb.close();
                }
                img.close();
            }
            Thread.sleep(16);
        }
        System.out.println("frames in 10 s: " + frames);
        vd.release();
        reader.close();
    }

    /** Which way a socket between the app (untrusted_app) and this shell process passes SELinux: shell -> app. */
    private static void connectTest(String name) {
        try (android.net.LocalSocket s = new android.net.LocalSocket()) {
            s.connect(new android.net.LocalSocketAddress(name, android.net.LocalSocketAddress.Namespace.ABSTRACT));
            s.getOutputStream().write("hello from shell\n".getBytes());
            System.out.println("connect-test: connected to @" + name);
        } catch (Exception e) {
            System.out.println("connect-test: FAILED " + e);
        }
    }

    /** ... and app -> shell: listens on @powos-shellhelper for 20 s and reports who connects. */
    private static void listenTest() throws Exception {
        try (android.net.LocalServerSocket server = new android.net.LocalServerSocket("powos-shellhelper")) {
            System.out.println("listen-test: listening on @powos-shellhelper for 20 s");
            Thread t = new Thread(() -> {
                try (android.net.LocalSocket c = server.accept()) {
                    System.out.println("listen-test: accepted from uid " + c.getPeerCredentials().getUid());
                } catch (Exception e) {
                    System.out.println("listen-test: accept " + e);
                }
            });
            t.setDaemon(true);
            t.start();
            t.join(20_000);
        }
    }

    /** A DisplayManager that acts as the shell package, so TRUSTED is accepted (shell has the permission). */
    private static DisplayManager displayManager() throws Exception {
        Constructor<DisplayManager> ctor = DisplayManager.class.getDeclaredConstructor(Context.class);
        ctor.setAccessible(true);
        return ctor.newInstance(new ShellContext(systemContext()));
    }

    @SuppressLint("PrivateApi")
    private static Context systemContext() throws Exception {
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        return (Context) at.getMethod("getSystemContext").invoke(thread);
    }

    private static String sh(String cmd) throws Exception {
        java.lang.Process p = Runtime.getRuntime().exec(new String[] {"sh", "-c", cmd});
        StringBuilder out = new StringBuilder();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
            for (String line; (line = r.readLine()) != null; ) out.append(line).append('\n');
        }
        p.waitFor();
        return out.toString();
    }

    /** The shell package's identity on top of the system context (getPackageName/opPackage/attribution). */
    private static final class ShellContext extends ContextWrapper {
        ShellContext(Context base) {
            super(base);
        }

        @Override
        public String getPackageName() {
            return "com.android.shell";
        }

        @Override
        public String getOpPackageName() {
            return "com.android.shell";
        }

        @Override
        public AttributionSource getAttributionSource() {
            return new AttributionSource.Builder(Process.SHELL_UID).setPackageName("com.android.shell").build();
        }

        @Override
        public Context getApplicationContext() {
            return this;
        }
    }
}
