package andro.marchy;

import android.content.Context;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.Writer;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.util.zip.GZIPInputStream;

/**
 * The parts of PowOS a phone without root adds on demand over the base image (targets/android/rootfs-packs.conf,
 * tools/split-rootfs.py): "gaming" (Steam, FEX + its x86 rootfs, box64), "apps", "dev", "languages". The base lists them
 * in rootfs/etc/powos/packs (name, download bytes, unpacked bytes); a rootfs without that file (the full one, rooted
 * phones) has every part already and no packs. Each pack is a tarball published beside the rootfs
 * (android.pow/apk/powos-pack-NAME.tar.gz), checked against the sha256 pinned in this APK
 * (assets/powos-pack-NAME.sha256) before anything is unpacked, then unpacked over the rootfs.
 * Installed = rootfs/var/lib/powos/packs/NAME exists; it lists the pack's files, which is what removing it deletes.
 * Progress: [state] and [listener] for the app's screens; run/pack-NAME.state for the Linux side (play/powos-pack):
 * "downloading <done> <total>", "installing <done> <total>", "removing", "done", "failed <message>".
 */
public final class Packs {
    private static final String TAG = "Packs";
    static final String URL_BASE = "http://android.pow/apk/";
    private static final ConcurrentHashMap<String, String> states = new ConcurrentHashMap<>();
    /** Called (on a worker thread) whenever a pack's [state] changes; the app's screens re-read the list. */
    public static volatile Runnable listener = null;

    private Packs() {}

    /** A pack the base leaves out: its sizes (bytes) and whether it is on the phone. */
    public static final class Pack {
        public final String name;
        public final long download, unpacked;
        public final boolean installed;

        Pack(String name, long download, long unpacked, boolean installed) {
            this.name = name;
            this.download = download;
            this.unpacked = unpacked;
            this.installed = installed;
        }
    }

    static boolean valid(String name) {
        return name.matches("[a-z0-9-]{1,32}");
    }

    private static File marker(Context ctx, String name) {
        return new File(SessionService.rootfs(ctx), "var/lib/powos/packs/" + name);
    }

    public static boolean installed(Context ctx, String name) {
        return marker(ctx, name).exists();
    }

    /** The packs the installed base leaves out, in its order; empty for a full rootfs (or none installed). */
    public static List<Pack> list(Context ctx) {
        List<Pack> out = new ArrayList<>();
        File f = new File(SessionService.rootfs(ctx), "etc/powos/packs");
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            for (String line; (line = r.readLine()) != null; ) {
                String[] w = line.trim().split("\t");
                if (w.length >= 3 && valid(w[0]))
                    out.add(new Pack(w[0], Long.parseLong(w[1]), Long.parseLong(w[2]), installed(ctx, w[0])));
            }
        } catch (IOException | NumberFormatException e) {
            // no list: a full rootfs
        }
        return out;
    }

    /** What is happening to the pack now (see the class comment), or null while nothing is. */
    public static String state(String name) {
        return states.get(name);
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

    private static void set(Context ctx, String name, String state) {
        if (state == null)
            states.remove(name);
        else
            states.put(name, state);
        File f = new File(SessionService.runDir(ctx), "pack-" + name + ".state");
        File tmp = new File(f.getPath() + ".tmp");
        try (FileWriter w = new FileWriter(tmp)) {
            w.write((state == null ? "done" : state) + "\n");
        } catch (IOException e) {
            // no run dir yet (no session): only the app's screens see the progress
        }
        tmp.renameTo(f);
        Runnable l = listener;
        if (l != null)
            l.run();
    }

    /** Installs the pack in the background (one job at a time per pack); [state] reports how it goes. */
    public static void installAsync(Context ctx, String name) {
        start(ctx, name, "downloading 0 0", () -> install(ctx, name, (phase, done, total) -> set(ctx, name, phase + " " + done + " " + total)));
    }

    /** Removes an installed pack's files in the background (see [remove]). */
    public static void removeAsync(Context ctx, String name) {
        start(ctx, name, "removing", () -> remove(ctx, name));
    }

    private interface Work {
        void run() throws IOException;
    }

    private static void start(Context ctx, String name, String first, Work work) {
        if (!valid(name))
            return;
        clearFailure(name);
        if (states.putIfAbsent(name, first) != null)
            return;
        set(ctx, name, first);
        new Thread(() -> {
            try {
                work.run();
                set(ctx, name, null);
            } catch (Throwable e) {
                Log.w(TAG, "pack " + name + " failed", e);
                set(ctx, name, "failed " + e.getMessage());
            }
        }, "pack-" + name).start();
    }

    /** Clears a failure shown for the pack, so it can be tried again. */
    public static void clearFailure(String name) {
        String s = states.get(name);
        if (s != null && s.startsWith("failed"))
            states.remove(name, s);
    }

    interface Progress {
        /** [phase]: "downloading" (bytes fetched) or "installing" (archive bytes unpacked). */
        void on(String phase, long done, long total);
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
                got = sha256(new FileInputStream(local), local.length(), null, (d, t) -> progress.on("downloading", d, t));
            } else {
                HttpURLConnection c = (HttpURLConnection) new URL(URL_BASE + file).openConnection();
                c.setInstanceFollowRedirects(true);
                c.connect();
                if (c.getResponseCode() != 200)
                    throw new IOException("download: HTTP " + c.getResponseCode());
                try (OutputStream out = new FileOutputStream(download)) {
                    got = sha256(c.getInputStream(), c.getContentLengthLong(), out, (d, t) -> progress.on("downloading", d, t));
                }
                archive = download;
            }
            if (!got.equals(pin))
                throw new IOException("the " + name + " pack's checksum doesn't match this app's: refusing to install it");
            File rootfs = SessionService.rootfs(ctx);
            File marker = marker(ctx, name);
            marker.getParentFile().mkdirs();
            File partial = new File(marker.getPath() + ".partial");
            final long size = archive.length();
            long[] read = {0}, shown = {0};
            // The file list is written as the files land: a stopped install can still be removed.
            try (Writer files = new FileWriter(partial);
                 InputStream in = new GZIPInputStream(new FilterInputStream(new BufferedInputStream(new FileInputStream(archive), 1 << 20)) {
                     @Override
                     public int read(byte[] b, int off, int len) throws IOException {
                         int n = super.read(b, off, len);
                         if (n > 0)
                             read[0] += n;
                         return n;
                     }
                 }, 1 << 16)) {
                TarExtractor.extract(in, rootfs, entry -> {
                    try {
                        files.write(entry + "\n");
                    } catch (IOException e) {
                        throw new RuntimeException(e);
                    }
                    long now = System.currentTimeMillis();
                    if (now - shown[0] >= 500) {
                        shown[0] = now;
                        progress.on("installing", read[0], size);
                    }
                });
            }
            if (!partial.renameTo(marker))
                throw new IOException("could not record the " + name + " pack");
        } finally {
            download.delete();
        }
    }

    /** Deletes the files the pack's install recorded (directories stay: base packages share them), then its record. */
    static void remove(Context ctx, String name) throws IOException {
        File marker = marker(ctx, name);
        File partial = new File(marker.getPath() + ".partial");
        File list = marker.exists() ? marker : partial;
        if (!list.exists())
            return;
        File rootfs = SessionService.rootfs(ctx);
        try (BufferedReader r = new BufferedReader(new FileReader(list))) {
            for (String line; (line = r.readLine()) != null; ) {
                String n = line.trim().replaceFirst("^\\./", "");
                if (n.isEmpty() || n.contains("..") || n.endsWith("/"))
                    continue;
                File f = new File(rootfs, n);
                if (!f.isDirectory())
                    f.delete();
            }
        }
        if (!list.delete())
            throw new IOException("could not remove the " + name + " pack's record");
    }

    private interface Bytes {
        void on(long done, long total);
    }

    private static String sha256(InputStream raw, long size, OutputStream out, Bytes progress) throws IOException {
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
                    progress.on(read, size);
                }
            }
        }
        StringBuilder hex = new StringBuilder(64);
        for (byte b : md.digest())
            hex.append(String.format(Locale.ROOT, "%02x", b));
        return hex.toString();
    }
}
