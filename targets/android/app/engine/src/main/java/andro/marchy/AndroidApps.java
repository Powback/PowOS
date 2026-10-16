package andro.marchy;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;
import java.util.HashSet;
import java.util.Set;

/**
 * PowOS: the Android apps in PowOS's application menu (Plasma's launcher, KRunner, the task manager): one
 * freedesktop .desktop entry + icon per launchable Android app, in the PowOS user's
 * ~/.local/share/applications and icons dirs, category "Android". Each runs android-request "float <package>":
 * the app opens in a floating Android window over the PowOS desktop (see AndroidRequests). Kept in sync on
 * install/update/removal. (Andromarchy wrote a block into Omarchy's JSONC menu instead.)
 */
final class AndroidApps extends BroadcastReceiver {
    private static final String TAG = "AndroidApps";
    private static final String PREFIX = "android-";
    private static final int ICON_PX = 192;
    private final File apps;
    private final File icons;

    AndroidApps(Context ctx) {
        // Rooted mode: PowOS is /data/powos/root (out of this app's reach); the app's run dir is PowOS's
        // /run/powos-app, and its share/ is on PowOS's XDG_DATA_DIRS (rooted/powos-session.sh).
        File share = RootMode.enabled() ? new File(SessionService.runDir(ctx), "share")
                : new File(SessionService.rootfs(ctx), "root/.local/share");
        apps = new File(share, "applications");
        icons = new File(share, "icons/hicolor/" + ICON_PX + "x" + ICON_PX + "/apps");
    }

    void register(Context ctx) {
        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_PACKAGE_ADDED);
        f.addAction(Intent.ACTION_PACKAGE_REMOVED);
        f.addAction(Intent.ACTION_PACKAGE_CHANGED);
        f.addDataScheme("package");
        ctx.registerReceiver(this, f);
        new Thread(() -> export(ctx)).start();
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        new Thread(() -> export(ctx)).start();
    }

    private synchronized void export(Context ctx) {
        PackageManager pm = ctx.getPackageManager();
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        apps.mkdirs();
        icons.mkdirs();
        Set<String> wanted = new HashSet<>();
        for (ResolveInfo ri : pm.queryIntentActivities(launcher, 0)) {
            String pkg = ri.activityInfo.packageName;
            if (pkg.equals(ctx.getPackageName()) || !wanted.add(pkg))
                continue;
            String id = PREFIX + pkg;
            String label = ri.loadLabel(pm).toString().replace('\n', ' ').trim();
            try {
                writeIcon(ri.loadIcon(pm), new File(icons, id + ".png"));
                String entry = "[Desktop Entry]\n"
                        + "Type=Application\n"
                        + "Name=" + label + "\n"
                        + "Comment=Android app (" + pkg + ")\n"
                        + "Exec=android-request float " + pkg + "\n"
                        + "Icon=" + id + "\n"
                        + "Categories=Android;\n"
                        + "Keywords=android;" + pkg + ";\n"
                        + "X-PowOS-Android-Package=" + pkg + "\n";
                File f = new File(apps, id + ".desktop");
                File tmp = new File(apps, "." + id + ".desktop");
                try (FileWriter w = new FileWriter(tmp)) {
                    w.write(entry);
                }
                tmp.renameTo(f);
            } catch (IOException ex) {
                Log.w(TAG, "export " + pkg, ex);
            }
        }
        // Entries of apps no longer installed.
        File[] old = apps.listFiles((d, n) -> n.startsWith(PREFIX) && n.endsWith(".desktop"));
        if (old != null)
            for (File f : old) {
                String pkg = f.getName().substring(PREFIX.length(), f.getName().length() - ".desktop".length());
                if (!wanted.contains(pkg)) {
                    f.delete();
                    new File(icons, PREFIX + pkg + ".png").delete();
                }
            }
    }

    private static void writeIcon(Drawable d, File out) throws IOException {
        Bitmap bmp = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(bmp);
        d.setBounds(0, 0, ICON_PX, ICON_PX);
        d.draw(c);
        try (FileOutputStream os = new FileOutputStream(out)) {
            bmp.compress(Bitmap.CompressFormat.PNG, 100, os);
        }
        bmp.recycle();
    }
}
