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


import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * First launch: what Omarchy's setup form asks that still applies here (keyboard layouts, name and email; the
 * language and time zone come from Android), then the rootfs download and extraction. SessionService then runs
 * first-boot.sh, which applies the answers (setup.conf). The install itself is a job of InstallService (InstallJob):
 * this screen only starts it and attaches to it, so a fold, the launcher coming back, a lock or an app restart shows
 * the running job's progress instead of a fresh form (2026-11-08 razr: "keeps restarting the install").
 */
public class InstallActivity extends Activity {
    /** PowOS: the PowOS rootfs (targets/android/build-rootfs.sh), served by android-app-dev's web server on the LAN/VPN
     *  (android.pow/apk = ~/Projects/android-app-dev/output). Was Andromarchy's Omarchy rootfs on GitHub. */
    public static final String ROOTFS_URL = "http://android.pow/apk/powos-rootfs.tar.gz";
    /** A local copy in the app's external files dir (Android/data/andro.marchy/files/, no permission needed) is used
     *  instead when present: offline installs and tests. */
    static final String LOCAL_NAME = "powos-rootfs.tar.gz";
    /** The rootfs's sha256, pinned in the APK: assets/powos-rootfs.sha256, written by targets/android/build-rootfs.sh
     *  when it publishes the tarball (so the APK built after a publish pins exactly that file). Both the download and
     *  a local copy are checked against it before anything is unpacked; a mismatch refuses the install. */
    static final String PIN_ASSET = "powos-rootfs.sha256";
    /** The base image (tools/split-rootfs.py: the full rootfs minus the packs and docs: ~1 GB of the 7 GB), used
     *  instead whenever this APK pins it and every pack it leaves out ([Packs]): gaming is added from the app on first
     *  use, languages right after the install when Android's language isn't English. Rooted installs keep the full one. */
    static final String BASE_URL = "http://android.pow/apk/powos-rootfs-base.tar.gz";
    static final String BASE_PIN_ASSET = "powos-rootfs-base.sha256";
    static final String[] PACKS = {"gaming", "apps", "dev", "languages"};
    private static final long NEEDED_BYTES = 12L << 30; // archive + extracted rootfs, with room for apps
    /** The base's need: its archive (1.04 GB) + unpacked (2.8 GiB) + room. Not the full rootfs's 12 GB: that refused
     *  the slim install on exactly the phones it is for (the 6 GB emulator, 4.3 GiB free). Packs are added later. */
    private static final long BASE_NEEDED_BYTES = 4L << 30;

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
        page.setWebViewClient(new android.webkit.WebViewClient() {
            @Override
            public void onPageFinished(WebView v, String url) {
                loaded = true;
                show();
            }
        });
        InstallService.listeners.add(onJob);
        page.loadUrl("file:///android_asset/install.html");
        setContentView(page);
    }

    /** Calls a function of the page with JSON-encoded arguments. */
    private void call(String fn, Object... args) {
        JSONArray a = new JSONArray();
        for (Object o : args)
            a.put(o);
        String js = fn + ".apply(null, " + a + ")";
        runOnUiThread(() -> {
            if (page != null)
                page.evaluateJavascript(js, null);
        });
    }

    /** The page shows the job's state; the job itself runs in InstallService, never in this activity. */
    private final Runnable onJob = this::show;
    private volatile boolean loaded, resumed, leaving;

    /** Attaches the page to the install job (InstallJob.onOpen): progress, a resume after process death, the error,
     *  or on to the desktop when it finished. Called on page load, on resume and on every job change. */
    private void show() {
        if (!loaded)
            return;
        InstallJob job = InstallService.current(this);
        InstallJob.Attach a = InstallJob.onOpen(job, SessionService.rootfsReady(this), InstallService.workerAlive());
        switch (a) {
            case FORM:
                return;
            case RESUME:
                InstallService.resume(this);
                // fall through: its progress shows at once (super-optimistic), the worker picks up from the saved step
            case WATCH:
                call("running", job.permille(), job.text);
                return;
            case FAILED:
                call("running", job.permille(), job.text);
                call("failed", job.error);
                return;
            case DONE:
                runOnUiThread(() -> {
                    if (resumed && !leaving) {
                        leaving = true;
                        startActivity(new Intent(this, MainActivity.class));
                        finish();
                    }
                });
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        show();
    }

    @Override
    protected void onPause() {
        resumed = false;
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        InstallService.listeners.remove(onJob);
        page = null;
        super.onDestroy();
    }

    private void start(String name, String email, String layouts) {
        File files = getFilesDir();
        long needed = useBase() ? BASE_NEEDED_BYTES : NEEDED_BYTES;
        if (new StatFs(files.getPath()).getAvailableBytes() < needed) {
            call("failed", "not enough free space: about " + (needed >> 30) + " GB are needed");
            return;
        }
        String conf = "KB_LAYOUTS=" + layouts.replaceAll("[^a-z,]", "") + "\nFULL_NAME=" + quote(name)
                + "\nEMAIL=" + quote(email) + "\n";
        // A running job is never restarted (InstallJob.shouldRun): a second tap, or a tap on a recreated page, attaches.
        call("running", 0, "Starting the download…");
        InstallService.start(this, conf);
    }

    private static String quote(String s) { // setup.conf is sourced by bash
        return "'" + s.trim().replace("'", "'\\''") + "'";
    }

    /** Whether this APK can install the base image: it pins the base and every pack (see [BASE_URL]). */
    private boolean useBase() {
        return useBase(this);
    }

    static boolean useBase(android.content.Context ctx) {
        if (pinnedSha256(ctx, BASE_PIN_ASSET) == null)
            return false;
        for (String p : PACKS)
            if (!Packs.available(ctx, p))
                return false;
        return true;
    }

    /** What a first install downloads from this APK: the base image when it can ([useBase]), the full rootfs otherwise
     *  (the home's install tile shows its size). */
    public static String downloadUrl(android.content.Context ctx) {
        return useBase(ctx) ? BASE_URL : ROOTFS_URL;
    }

    /** The sha256 pinned in an asset (64 lowercase hex), or null when the asset is missing or holds none. */
    static String pinnedSha256(android.content.Context ctx, String asset) {
        String line = null;
        try (BufferedReader r = new BufferedReader(new InputStreamReader(ctx.getAssets().open(asset),
                StandardCharsets.US_ASCII))) {
            line = r.readLine();
        } catch (IOException e) {
            return null;
        }
        String hex = line == null ? "" : line.trim().split("\\s+")[0].toLowerCase(Locale.ROOT);
        return hex.matches("[0-9a-f]{64}") ? hex : null;
    }
}
