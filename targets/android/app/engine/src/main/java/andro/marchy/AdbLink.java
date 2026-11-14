package andro.marchy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.os.HandlerThread;
import android.provider.Settings;
import android.util.Log;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * The phone's own adb for the Linux side WITHOUT root (lib/android.sh: `powos android` screenshot/input/dumpsys/logcat/
 * am/settings; the razr's no-root log, 11-14: "the manager can't do what it can on a rooted phone"). Rooted mode has
 * 127.0.0.1:5555 with PowOS's key authorised by rooted.sh; without root the only shell-uid door is Android's Wireless
 * debugging adbd. Its TLS port is random (new each time Wireless debugging starts: a reboot, a Wi-Fi change) and is
 * only announced over mDNS, which the image's adb can't see (no mDNS under fakechroot). So the app finds it with
 * Android's own mDNS (NsdManager, only services on this phone's own addresses) and hands it over in run/adb-link:
 *
 *   package com.powos.app        whom `pm grant` names (the Linux side asks for WRITE_SECURE_SETTINGS once linked)
 *   wireless on|off              Android's adb_wifi_enabled
 *   keep on|off                  linked before AND allowed to write secure settings: Wireless debugging is turned
 *                                back on by the app after a reboot or a Wi-Fi change, so the link comes back by itself
 *   connect 127.0.0.1:<port>     adbd's TLS port, when Wireless debugging is on (no line otherwise)
 *
 * The key is the Linux side's own (~/.android/adbkey), paired ONCE: `powos android link` asks for "adb-link pair",
 * the app looks for the pairing service (Developer options > Wireless debugging > Pair device with pairing code)
 * and posts a notification the user types the six digits into; the port and the code go to run/adb-pair
 * ("127.0.0.1:<port> <code>", the app's private dir, read once and deleted by the Linux side, which runs `adb pair`).
 * Requests (AndroidRequests "adb-link [pair|keep on|keep off]"): refresh now / pair / remember the link.
 */
final class AdbLink {
    private static final String TAG = "AdbLink";
    static final String CONNECT = "_adb-tls-connect._tcp";
    static final String PAIRING = "_adb-tls-pairing._tcp";
    static final String FILE = "adb-link";
    static final String PAIR_FILE = "adb-pair";
    private static final String CHANNEL = "adb-link";
    private static final int NOTE = 0xadb1;
    private static final String ACTION = "andro.marchy.ADB_LINK_CODE";
    private static final String KEY_CODE = "code";
    private static final String PREF_KEEP = "adb_link_keep";
    private static final long PAIR_MS = 5 * 60_000L;

    /** The one live link (SessionService's), for AndroidRequests. */
    static volatile AdbLink current;

    private final Context ctx;
    private final File run;
    private final Handler bg;
    private volatile int pairPort = -1;
    private volatile String code;
    private volatile long pairUntil;

    private final BroadcastReceiver reply = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent i) {
            android.os.Bundle r = android.app.RemoteInput.getResultsFromIntent(i);
            CharSequence s = r == null ? null : r.getCharSequence(KEY_CODE);
            if (s != null)
                bg.post(() -> onCode(s.toString()));
        }
    };

    AdbLink(Context ctx, File run) {
        this.ctx = ctx;
        this.run = run;
        HandlerThread t = new HandlerThread("adb-link");
        t.start();
        bg = new Handler(t.getLooper());
        IntentFilter f = new IntentFilter(ACTION);
        if (android.os.Build.VERSION.SDK_INT >= 33)
            ctx.registerReceiver(reply, f, Context.RECEIVER_NOT_EXPORTED);
        else
            ctx.registerReceiver(reply, f);
    }

    void stop() {
        runCatching(() -> ctx.unregisterReceiver(reply));
        bg.removeCallbacksAndMessages(null);
        bg.getLooper().quitSafely();
    }

    // ---- what the Linux side reads (pure: AdbLinkTest) -----------------------------------------------------------

    /** run/adb-link's text. [connect] <= 0: no connect line (Wireless debugging off, or adbd not announced yet). */
    static String record(String pkg, boolean wireless, boolean keep, int connect) {
        StringBuilder b = new StringBuilder();
        b.append("package ").append(pkg).append('\n');
        b.append("wireless ").append(wireless ? "on" : "off").append('\n');
        b.append("keep ").append(keep ? "on" : "off").append('\n');
        if (connect > 0)
            b.append("connect 127.0.0.1:").append(connect).append('\n');
        return b.toString();
    }

    /** run/adb-pair's line, or null when [code] isn't Android's six-digit pairing code or no port is known. */
    static String pairLine(int port, String code) {
        String c = code == null ? "" : code.replaceAll("\\s", "");
        if (port <= 0 || !c.matches("[0-9]{6}"))
            return null;
        return "127.0.0.1:" + port + " " + c + "\n";
    }

    /**
     * The port of the first service ({host, port}) on one of [own] addresses: mDNS also sees every other phone's and
     * computer's Wireless debugging on the LAN; only this phone's adbd is ours. -1: none.
     */
    static int ownPort(List<String[]> found, Set<String> own) {
        for (String[] s : found) {
            String host = s[0] == null ? "" : s[0].replaceFirst("%.*$", "");
            if (own.contains(host)) {
                try {
                    return Integer.parseInt(s[1]);
                } catch (NumberFormatException ignored) {
                }
            }
        }
        return -1;
    }

    // ---- the running link ------------------------------------------------------------------------------------------

    /** Refresh soon (a network change: adbd restarts Wireless debugging on the new network in a moment). */
    void refreshSoon() {
        bg.removeCallbacks(refresh);
        bg.postDelayed(refresh, 3_000);
    }

    void refreshNow() {
        bg.removeCallbacks(refresh);
        bg.post(refresh);
    }

    void keep(boolean on) {
        ctx.getSharedPreferences(Prefs.NAME, Context.MODE_PRIVATE).edit().putBoolean(PREF_KEEP, on).apply();
        refreshNow();
    }

    private final Runnable refresh = this::refresh;

    private boolean keeps() {
        return ctx.getSharedPreferences(Prefs.NAME, Context.MODE_PRIVATE).getBoolean(PREF_KEEP, false)
                && ctx.checkSelfPermission("android.permission.WRITE_SECURE_SETTINGS") == PackageManager.PERMISSION_GRANTED;
    }

    private boolean wireless() {
        return Settings.Global.getInt(ctx.getContentResolver(), "adb_wifi_enabled", 0) == 1;
    }

    private boolean onWifi() {
        ConnectivityManager cm = ctx.getSystemService(ConnectivityManager.class);
        NetworkCapabilities c = cm.getNetworkCapabilities(cm.getActiveNetwork());
        return c != null && c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
    }

    private void refresh() {
        boolean keep = keeps();
        // Linked before: Wireless debugging back on after a reboot / a new Wi-Fi (Android turns it off), as Shizuku.
        if (keep && !wireless() && onWifi()) {
            try {
                Settings.Global.putInt(ctx.getContentResolver(), "adb_wifi_enabled", 1);
                Thread.sleep(2_000); // adbd starts its TLS server and announces it
            } catch (RuntimeException | InterruptedException e) {
                Log.w(TAG, "Wireless debugging not turned back on: " + e);
            }
        }
        boolean on = wireless();
        int port = on ? ownPort(discover(CONNECT, 2_500), ownAddresses()) : -1;
        write(new File(run, FILE), record(ctx.getPackageName(), on, keep, port));
        Log.i(TAG, "adb link: wireless " + on + ", keep " + keep + ", port " + port);
    }

    /** "adb-link pair": find the pairing dialog's port while the user types the code into the notification. */
    void pair() {
        bg.post(() -> {
            pairUntil = System.currentTimeMillis() + PAIR_MS;
            pairPort = -1;
            code = null;
            new File(run, PAIR_FILE).delete();
            notifyPair("Developer options > Wireless debugging > Pair device with pairing code, then type the code here.");
            lookForPairing();
        });
    }

    private void lookForPairing() {
        if (System.currentTimeMillis() > pairUntil) {
            ctx.getSystemService(NotificationManager.class).cancel(NOTE);
            return;
        }
        int p = ownPort(discover(PAIRING, 2_500), ownAddresses());
        if (p > 0)
            pairPort = p;
        if (handOver())
            return;
        bg.postDelayed(this::lookForPairing, 1_000);
    }

    private void onCode(String c) {
        code = c;
        if (pairLine(1, c) == null) {
            notifyPair("That isn't the six-digit pairing code - type it again.");
            return;
        }
        if (!handOver())
            notifyPair("Got the code - waiting for the pairing dialog (Wireless debugging > Pair device with pairing code).");
    }

    /** Port and code both known: run/adb-pair for the Linux side's `adb pair`, the notification done. */
    private boolean handOver() {
        String line = pairLine(pairPort, code);
        if (line == null)
            return false;
        write(new File(run, PAIR_FILE), line);
        code = null;
        pairUntil = 0;
        ctx.getSystemService(NotificationManager.class).cancel(NOTE);
        return true;
    }

    private void notifyPair(String text) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Android link", NotificationManager.IMPORTANCE_HIGH));
        Intent i = new Intent(ACTION).setPackage(ctx.getPackageName());
        PendingIntent pi = PendingIntent.getBroadcast(ctx, NOTE, i, PendingIntent.FLAG_MUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent dev = PendingIntent.getActivity(ctx, NOTE,
                new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Action enter = new Notification.Action.Builder(null, "Enter pairing code", pi)
                .addRemoteInput(new android.app.RemoteInput.Builder(KEY_CODE).setLabel("Pairing code").build())
                .build();
        nm.notify(NOTE, new Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setContentTitle("Link PowOS to Android")
                .setContentText(text)
                .setStyle(new Notification.BigTextStyle().bigText(text))
                .setContentIntent(dev)
                .setOnlyAlertOnce(true)
                .setTimeoutAfter(PAIR_MS)
                .addAction(enter)
                .build());
    }

    /** {host, port} of each [type] service mDNS finds within [ms]. */
    private List<String[]> discover(String type, long ms) {
        NsdManager nsd = ctx.getSystemService(NsdManager.class);
        List<NsdServiceInfo> seen = Collections.synchronizedList(new ArrayList<>());
        NsdManager.DiscoveryListener l = new NsdManager.DiscoveryListener() {
            @Override public void onStartDiscoveryFailed(String t, int c) {}
            @Override public void onStopDiscoveryFailed(String t, int c) {}
            @Override public void onDiscoveryStarted(String t) {}
            @Override public void onDiscoveryStopped(String t) {}
            @Override public void onServiceFound(NsdServiceInfo s) { seen.add(s); }
            @Override public void onServiceLost(NsdServiceInfo s) {}
        };
        List<String[]> out = new ArrayList<>();
        try {
            nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, l);
            Thread.sleep(ms);
        } catch (RuntimeException | InterruptedException e) {
            Log.w(TAG, "mDNS " + type + ": " + e);
        } finally {
            runCatching(() -> nsd.stopServiceDiscovery(l));
        }
        List<NsdServiceInfo> found;
        synchronized (seen) {
            found = new ArrayList<>(seen);
        }
        for (NsdServiceInfo s : found) {
            NsdServiceInfo r = resolve(nsd, s);
            if (r != null && r.getHost() != null)
                out.add(new String[] {r.getHost().getHostAddress(), String.valueOf(r.getPort())});
        }
        return out;
    }

    @SuppressWarnings("deprecation")
    private static NsdServiceInfo resolve(NsdManager nsd, NsdServiceInfo s) {
        final NsdServiceInfo[] got = {null};
        final Object done = new Object();
        try {
            nsd.resolveService(s, new NsdManager.ResolveListener() {
                @Override
                public void onResolveFailed(NsdServiceInfo i, int c) {
                    synchronized (done) {
                        done.notifyAll();
                    }
                }

                @Override
                public void onServiceResolved(NsdServiceInfo i) {
                    synchronized (done) {
                        got[0] = i;
                        done.notifyAll();
                    }
                }
            });
            synchronized (done) {
                if (got[0] == null)
                    done.wait(2_000);
            }
        } catch (RuntimeException | InterruptedException e) {
            return null;
        }
        return got[0];
    }

    private static Set<String> ownAddresses() {
        Set<String> own = new HashSet<>();
        try {
            for (NetworkInterface n : Collections.list(NetworkInterface.getNetworkInterfaces()))
                for (InetAddress a : Collections.list(n.getInetAddresses()))
                    own.add(a.getHostAddress().replaceFirst("%.*$", ""));
        } catch (Exception e) {
            Log.w(TAG, "own addresses: " + e);
        }
        return own;
    }

    /** Atomic, private (the app's run dir is the app's alone): the reader never sees half a file. */
    private static void write(File f, String s) {
        File tmp = new File(f.getParentFile(), "." + f.getName());
        try (FileWriter w = new FileWriter(tmp)) {
            w.write(s);
        } catch (IOException e) {
            return;
        }
        tmp.setReadable(false, false);
        tmp.setReadable(true, true);
        if (!tmp.renameTo(f))
            Log.w(TAG, "could not write " + f);
    }

    private static void runCatching(Runnable r) {
        try {
            r.run();
        } catch (RuntimeException ignored) {
        }
    }
}
