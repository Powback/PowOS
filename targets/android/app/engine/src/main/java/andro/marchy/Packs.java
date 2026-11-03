package andro.marchy;

import android.content.Context;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.util.zip.GZIPInputStream;

/**
 * The parts of PowOS a phone without root adds on demand over the base image (targets/android/rootfs-packs.conf,
 * tools/split-rootfs.py): "gaming" (Steam, FEX + its x86 rootfs, box64), "languages" (translations other than English).
 * Each is a tarball published beside the rootfs (android.pow/apk/powos-pack-NAME.tar.gz), checked against the sha256
 * pinned in this APK (assets/powos-pack-NAME.sha256) before anything is unpacked, then unpacked over the rootfs.
 * Installed = rootfs/var/lib/powos/packs/NAME exists. Progress goes to run/pack-NAME.state for the Linux side
 * (play/powos-steam waits on it): "downloading <done> <total>", "installing", "done", "failed <message>".
 */
public final class Packs {
    private static final String TAG = "Packs";
    static final String URL_BASE = "http://android.pow/apk/";
    private static final ConcurrentHashMap<String, Boolean> running = new ConcurrentHashMap<>();

    private Packs() {}

    static boolean valid(String name) {
        return name.matches("[a-z0-9-]{1,32}");
    }

    public static boolean installed(Context ctx, String name) {
        return new File(SessionService.rootfs(ctx), "var/lib/powos/packs/" + name).exists();
    }

    /** The pack's pinned sha256, or null when this APK pins none (its rootfs was published without packs). */
    static String pin(Context ctx, String name) {
        try (BufferedReader r = new BufferedReader(new InputStreamReader(ctx.getAssets().open("powos-pack-" + name
                + ".sha256"), StandardCharsets.US_ASCII))) {
            String line = r.readLine();
            String hex = line == null ? "" : line.trim().split("\\s+")[0].toLowerCase(Locale.ROOT);
            return hex.matches("[0-9a-f]{64}") ? hex : null;
        } catch (IOException e) {
            return null;
        }
    }

    /** Whether this APK can add the pack (it pins one): the base image is only used when it can add every pack. */
    static boolean available(Context ctx, String name) {
        return pin(ctx, name) != null;
    }

    /** Installs the pack in the background (once at a time per pack); the state file reports how it goes. */
    public static void installAsync(Context ctx, String name, File runDir) {
        if (!valid(name) || running.putIfAbsent(name, true) != null)
            return;
        new Thread(() -> {
            File state = runDir == null ? null : new File(runDir, "pack-" + name + ".state");
            try {
                install(ctx, name, (done, total) -> write(state, "downloading " + done + " " + total));
                write(state, "done");
            } catch (Throwable e) {
                Log.w(TAG, "pack " + name + " failed", e);
                write(state, "failed " + e.getMessage());
            } finally {
                running.remove(name);
            }
        }, "pack-" + name).start();
    }

    interface Progress {
        void onBytes(long done, long total);
    }

    /** Downloads (or takes a local copy from the app's external files dir), checks the pin, unpacks over the rootfs. */
    static void install(Context ctx, String name, Progress progress) throws IOException {
        if (installed(ctx, name))
            return;
        String pin = pin(ctx, name);
        if (pin == null)
            throw new IOException("this app has no " + name + " pack pinned (assets/powos-pack-" + name + ".sha256)");
        String file = "powos-pack-" + name + ".tar.gz";
        File local = new File(ctx.getExternalFilesDir(null), file);
        File download = new File(ctx.getFilesDir(), file + ".download");
        download.delete();
        try {
            File archive;
            String got;
            if (local.canRead()) {
                archive = local;
                got = sha256(new FileInputStream(local), local.length(), null, progress);
            } else {
                HttpURLConnection c = (HttpURLConnection) new URL(URL_BASE + file).openConnection();
                c.setInstanceFollowRedirects(true);
                c.connect();
                if (c.getResponseCode() != 200)
                    throw new IOException("download: HTTP " + c.getResponseCode());
                try (OutputStream out = new FileOutputStream(download)) {
                    got = sha256(c.getInputStream(), c.getContentLengthLong(), out, progress);
                }
                archive = download;
            }
            if (!got.equals(pin))
                throw new IOException("the " + name + " pack's checksum doesn't match this app's: refusing to install it");
            File rootfs = SessionService.rootfs(ctx);
            try (InputStream in = new GZIPInputStream(new BufferedInputStream(new FileInputStream(archive), 1 << 20), 1 << 16)) {
                TarExtractor.extract(in, rootfs, entry -> {});
            }
            File marker = new File(rootfs, "var/lib/powos/packs/" + name);
            marker.getParentFile().mkdirs();
            write(marker, pin + "\n");
        } finally {
            download.delete();
        }
    }

    private static String sha256(InputStream raw, long size, OutputStream out, Progress progress) throws IOException {
        MessageDigest md;
        try {
            md = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IOException(e);
        }
        byte[] buf = new byte[1 << 20];
        long read = 0, shown = 0;
        try (InputStream in = raw) {
            for (int n; (n = in.read(buf)) > 0; ) {
                md.update(buf, 0, n);
                if (out != null)
                    out.write(buf, 0, n);
                read += n;
                long now = System.currentTimeMillis();
                if (now - shown >= 500) {
                    shown = now;
                    progress.onBytes(read, size);
                }
            }
        }
        StringBuilder hex = new StringBuilder(64);
        for (byte b : md.digest())
            hex.append(String.format(Locale.ROOT, "%02x", b));
        return hex.toString();
    }

    private static void write(File f, String s) {
        if (f == null)
            return;
        File tmp = new File(f.getPath() + ".tmp");
        try (FileWriter w = new FileWriter(tmp)) {
            w.write(s + "\n");
        } catch (IOException e) {
            return;
        }
        tmp.renameTo(f);
    }
}
