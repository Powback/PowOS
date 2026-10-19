package andro.marchy;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.os.StatFs;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.zip.GZIPInputStream;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.FilterInputStream;
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

/**
 * First launch: what Omarchy's setup form asks that still applies here (keyboard layouts, name and email; the
 * language and time zone come from Android), then the rootfs download and extraction. SessionService then runs
 * first-boot.sh, which applies the answers (setup.conf).
 */
public class InstallActivity extends Activity {
    /** PowOS: the PowOS rootfs (targets/android/build-rootfs.sh), served by android-app-dev's web server on the LAN/VPN
     *  (android.pow/apk = ~/Projects/android-app-dev/output). Was Andromarchy's Omarchy rootfs on GitHub. */
    static final String ROOTFS_URL = "http://android.pow/apk/powos-rootfs.tar.gz";
    /** A local copy in the app's external files dir (Android/data/andro.marchy/files/, no permission needed) is used
     *  instead when present: offline installs and tests. */
    static final String LOCAL_NAME = "powos-rootfs.tar.gz";
    /** The rootfs's sha256, pinned in the APK: assets/powos-rootfs.sha256, written by targets/android/build-rootfs.sh
     *  when it publishes the tarball (so the APK built after a publish pins exactly that file). Both the download and
     *  a local copy are checked against it before anything is unpacked; a mismatch refuses the install. */
    static final String PIN_ASSET = "powos-rootfs.sha256";
    private static final long NEEDED_BYTES = 12L << 30; // archive + extracted rootfs, with room for apps

    // {xkb layout, label}: the common ones; the first selected is the physical keyboard's.
    private static final String[][] LAYOUTS = {
            {"us", "English (US)"}, {"gb", "English (UK)"}, {"fr", "Français (AZERTY)"}, {"ara", "العربية"},
            {"de", "Deutsch"}, {"es", "Español"}, {"it", "Italiano"}, {"pt", "Português"}, {"br", "Português (BR)"},
            {"be", "Belgique"}, {"ch", "Suisse"}, {"ca", "Canada (FR)"}, {"nl", "Nederlands"}, {"tr", "Türkçe"},
            {"ru", "Русский"}, {"ua", "Українська"}, {"pl", "Polski"}, {"gr", "Ελληνικά"}, {"il", "עברית"},
            {"ir", "فارسی"}, {"jp", "日本語"}, {"kr", "한국어"}, {"cn", "中文"}, {"in", "हिन्दी"},
    };

    private WebView page;

    // The page (assets/install.html, design: "first launch.html" at the repo root) calls these, as "A".
    private final Object bridge = new Object() {
        /** [{id, label, on}]: Android's language's layout first and on, then US English (on). */
        @JavascriptInterface
        public String layouts() {
            String lang = Locale.getDefault().getLanguage();
            String suggested = lang.equals("ar") ? "ara" : lang.equals("en") ? "us" : lang.equals("uk") ? "ua"
                    : lang.equals("he") ? "il" : lang.equals("fa") ? "ir" : lang.equals("ja") ? "jp"
                    : lang.equals("ko") ? "kr" : lang.equals("zh") ? "cn" : lang.equals("hi") ? "in"
                    : lang.equals("el") ? "gr" : lang.equals("pt") && Locale.getDefault().getCountry().equals("BR") ? "br"
                    : lang;
            JSONArray out = new JSONArray();
            try {
                for (String[] l : LAYOUTS)
                    if (l[0].equals(suggested))
                        out.put(new JSONObject().put("id", l[0]).put("label", l[1]).put("on", true));
                for (String[] l : LAYOUTS)
                    if (!l[0].equals(suggested))
                        out.put(new JSONObject().put("id", l[0]).put("label", l[1]).put("on", l[0].equals("us")));
            } catch (JSONException e) {
                throw new RuntimeException(e);
            }
            return out.toString();
        }

        @JavascriptInterface
        public void install(String name, String email, String layouts) {
            start(name, email, layouts);
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        page = new WebView(this);
        page.setBackgroundColor(Color.rgb(0x12, 0x13, 0x1d));
        page.getSettings().setJavaScriptEnabled(true);
        page.addJavascriptInterface(bridge, "A");
        page.loadUrl("file:///android_asset/install.html");
        setContentView(page);
    }

    /** Calls a function of the page with JSON-encoded arguments. */
    private void call(String fn, Object... args) {
        JSONArray a = new JSONArray();
        for (Object o : args)
            a.put(o);
        String js = fn + ".apply(null, " + a + ")";
        runOnUiThread(() -> page.evaluateJavascript(js, null));
    }

    private void start(String name, String email, String layouts) {
        File files = getFilesDir();
        if (new StatFs(files.getPath()).getAvailableBytes() < NEEDED_BYTES) {
            call("failed", "not enough free space: about " + (NEEDED_BYTES >> 30) + " GB are needed");
            return;
        }
        String conf = "KB_LAYOUTS=" + layouts.replaceAll("[^a-z,]", "") + "\nFULL_NAME=" + quote(name)
                + "\nEMAIL=" + quote(email) + "\n";
        new Thread(() -> {
            try {
                installRootfs(conf);
                runOnUiThread(() -> {
                    startActivity(new Intent(this, MainActivity.class));
                    finish();
                });
            } catch (Throwable e) { // shown, never a crash: the user can retry
                call("failed", String.valueOf(e.getMessage()));
            }
        }).start();
    }

    private static String quote(String s) { // setup.conf is sourced by bash
        return "'" + s.trim().replace("'", "'\\''") + "'";
    }

    private void installRootfs(String conf) throws IOException {
        File rootfs = SessionService.rootfs(this);
        File partial = new File(rootfs.getPath() + ".partial");
        deleteTree(partial); // a previous attempt that stopped halfway
        String pin = pinnedSha256();
        File external = new File(getExternalFilesDir(null), LOCAL_NAME);
        // or in files/ (adb run-as, or a rootfs build on the device)
        final File local = external.canRead() ? external : new File(getFilesDir(), LOCAL_NAME);
        // The download goes to a file first and is checked whole before a single entry is unpacked: nothing from an
        // archive that doesn't match the pin ever lands in the rootfs. Not named LOCAL_NAME, so a leftover is never
        // mistaken for a local copy.
        File download = new File(getFilesDir(), LOCAL_NAME + ".download");
        download.delete();
        try {
            File archive;
            String got;
            if (local.canRead()) {
                archive = local;
                got = sha256(new FileInputStream(local), local.length(), null, "Checking the rootfs");
            } else {
                HttpURLConnection c = (HttpURLConnection) new URL(ROOTFS_URL).openConnection();
                c.setInstanceFollowRedirects(true); // GitHub release assets redirect to their storage host
                c.connect();
                if (c.getResponseCode() != 200)
                    throw new IOException("download: HTTP " + c.getResponseCode());
                try (OutputStream out = new FileOutputStream(download)) {
                    got = sha256(c.getInputStream(), c.getContentLengthLong(), out, "Downloading the rootfs");
                }
                archive = download;
            }
            if (!got.equals(pin))
                throw new IOException("the rootfs's checksum doesn't match this app's (expected sha256 "
                        + pin.substring(0, 16) + "…, got " + got.substring(0, 16) + "…): refusing to install it. "
                        + (archive == local ? "Remove " + local + ", or" : "The published rootfs (" + ROOTFS_URL
                        + ") is not the one this app was built for:") + " rebuild the app after the rootfs is published");
            extract(archive, partial);
        } finally {
            download.delete();
        }
        File setup = new File(partial, "root/.config/andromarchy/setup.conf");
        setup.getParentFile().mkdirs();
        try (FileWriter w = new FileWriter(setup)) {
            w.write(conf);
        }
        if (!partial.renameTo(rootfs))
            throw new IOException("could not move the rootfs into place");
    }

    /** Unpacks the (already checked) archive into partial, with progress. */
    private void extract(File archive, File partial) throws IOException {
        final long size = archive.length();
        long[] read = {0};
        long[] shown = {0};
        InputStream counting = new FilterInputStream(new BufferedInputStream(new FileInputStream(archive), 1 << 20)) {
            @Override
            public int read(byte[] b, int off, int len) throws IOException {
                int n = super.read(b, off, len);
                if (n > 0)
                    read[0] += n;
                return n;
            }
        };
        try (InputStream in = new GZIPInputStream(counting, 1 << 16)) {
            TarExtractor.extract(in, partial, entry -> {
                long now = System.currentTimeMillis();
                if (now - shown[0] < 200)
                    return;
                shown[0] = now;
                String what = "Installing (" + (read[0] >> 20) + (size > 0 ? " / " + (size >> 20) : "") + " MB)\n" + entry;
                call("progress", size > 0 ? read[0] * 1000 / size : -1, what);
            });
        }
    }

    /** The pinned sha256 (64 lowercase hex), or an error saying this APK has none. */
    private String pinnedSha256() throws IOException {
        String line = null;
        try (BufferedReader r = new BufferedReader(new InputStreamReader(getAssets().open(PIN_ASSET),
                StandardCharsets.US_ASCII))) {
            line = r.readLine();
        } catch (IOException e) {
            // no asset: handled below
        }
        String hex = line == null ? "" : line.trim().split("\\s+")[0].toLowerCase(Locale.ROOT);
        if (!hex.matches("[0-9a-f]{64}"))
            throw new IOException("this app has no rootfs checksum pinned (assets/" + PIN_ASSET
                    + "): rebuild it after targets/android/build-rootfs.sh publishes the rootfs");
        return hex;
    }

    /** sha256 of a stream (closed afterwards), copied to out when given, with progress under label. */
    private String sha256(InputStream raw, long size, OutputStream out, String label) throws IOException {
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
                if (now - shown >= 200) {
                    shown = now;
                    call("progress", size > 0 ? read * 1000 / size : -1,
                            label + " (" + (read >> 20) + (size > 0 ? " / " + (size >> 20) : "") + " MB)");
                }
            }
        }
        StringBuilder hex = new StringBuilder(64);
        for (byte b : md.digest())
            hex.append(String.format(Locale.ROOT, "%02x", b));
        return hex.toString();
    }

    private static void deleteTree(File f) {
        File[] children = f.isDirectory() && !isSymlink(f) ? f.listFiles() : null;
        if (children != null)
            for (File c : children)
                deleteTree(c);
        f.delete();
    }

    private static boolean isSymlink(File f) {
        try {
            return java.nio.file.Files.isSymbolicLink(f.toPath());
        } catch (Exception e) {
            return false;
        }
    }
}
