package andro.marchy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.wifi.WifiManager;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArraySet;
import java.util.zip.GZIPInputStream;

/**
 * Runs the no-root PowOS install ([InstallJob]) outside any activity: a foreground service (dataSync) with a progress
 * notification, a wake lock and a Wi-Fi lock, so a fold, the launcher coming back, the screen locking or the app being
 * swiped away never stops or restarts it. The job is persisted (files/install-job.properties) at every step and every
 * few seconds of progress; START_STICKY + that file resume it after the process is killed. InstallActivity attaches
 * through [listeners] and [current].
 */
public class InstallService extends Service {
    private static final String TAG = "InstallService";
    private static final String CHANNEL = "install";
    private static final int NOTIFICATION_ID = 7;
    private static final String EXTRA_CONF = "conf";

    /** Called on the worker thread at every progress/step change. */
    public static final Set<Runnable> listeners = new CopyOnWriteArraySet<>();

    private static volatile InstallJob current;
    private static volatile Thread worker;

    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;
    private long lastSaved, lastNotified;

    static File jobFile(Context ctx) {
        return new File(ctx.getFilesDir(), "install-job.properties");
    }

    /** The job as last known (in memory, else from disk); null when none was ever started. */
    static InstallJob current(Context ctx) {
        InstallJob j = current;
        if (j == null) {
            j = InstallJob.load(jobFile(ctx));
            if (current == null)
                current = j;
        }
        return j;
    }

    static boolean workerAlive() {
        Thread t = worker;
        return t != null && t.isAlive();
    }

    /** The no-root session waits while this is true (SessionPlan.WAIT_IMAGE): a job that is not done. */
    static boolean installing(Context ctx) {
        InstallJob j = current(ctx);
        return j != null && j.status != InstallJob.Status.DONE && j.step != InstallJob.Step.DONE
                && (workerAlive() || j.status == InstallJob.Status.RUNNING);
    }

    /** A job that must be finished before the desktop (MainActivity redirects to the install screen for it). */
    static boolean pending(Context ctx) {
        InstallJob j = current(ctx);
        return j != null && j.status != InstallJob.Status.DONE && j.step != InstallJob.Step.DONE;
    }

    /** The form's button: a new job with these answers, or a retry of the failed one; never a second worker. */
    static void start(Context ctx, String conf) {
        ctx.startForegroundService(new Intent(ctx, InstallService.class).putExtra(EXTRA_CONF, conf));
    }

    /** Restarts the worker for a job that was running when the process died. */
    static void resume(Context ctx) {
        ctx.startForegroundService(new Intent(ctx, InstallService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel(CHANNEL, "PowOS install", NotificationManager.IMPORTANCE_LOW));
        startForeground(NOTIFICATION_ID, notification(current(this)), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        wakeLock = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "powos:install");
        wakeLock.acquire(3 * 60 * 60 * 1000L); // bounded: a stuck download never holds the CPU for ever
        WifiManager wm = getApplicationContext().getSystemService(WifiManager.class);
        if (wm != null) {
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "powos:install");
            wifiLock.acquire();
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        synchronized (InstallService.class) {
            InstallJob job = current(this);
            String conf = intent == null ? null : intent.getStringExtra(EXTRA_CONF);
            if (!workerAlive()) {
                if (conf != null) {
                    if (job == null || job.step == InstallJob.Step.DONE || job.status == InstallJob.Status.DONE)
                        job = InstallJob.fresh(conf, InstallActivity.useBase(this), InstallActivity.downloadUrl(this));
                    else {
                        job.conf = conf; // the retry's answers; the download so far is kept
                        job.retry();
                    }
                } else if (job != null && job.status == InstallJob.Status.FAILED) {
                    job = null; // a sticky restart doesn't retry a failure on its own: the user does
                }
                if (InstallJob.shouldRun(job, false)) {
                    job.status = InstallJob.Status.RUNNING;
                    current = job;
                    save(job, true);
                    final InstallJob run = job;
                    worker = new Thread(() -> work(run), "powos-install");
                    worker.start();
                } else {
                    stopSelf();
                }
            }
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (wakeLock != null && wakeLock.isHeld())
            wakeLock.release();
        if (wifiLock != null && wifiLock.isHeld())
            wifiLock.release();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // --- the job ---

    private void work(InstallJob job) {
        try {
            File archive = archive(job);
            File local = localCopy(job);
            job.step = InstallJob.resumeStep(job, local.canRead() || archive.exists());
            if (job.step == InstallJob.Step.DOWNLOAD) {
                if (!local.canRead())
                    download(job, archive);
                set(job, InstallJob.Step.VERIFY, 0, -1, "Checking the download…");
            }
            File source = local.canRead() ? local : archive;
            if (job.step == InstallJob.Step.VERIFY) {
                String pin = job.base ? InstallActivity.pinnedSha256(this, InstallActivity.BASE_PIN_ASSET)
                        : InstallActivity.pinnedSha256(this, InstallActivity.PIN_ASSET);
                if (pin == null)
                    throw new IOException("this app has no rootfs checksum pinned: rebuild it after targets/android/build-rootfs.sh publishes the rootfs");
                String got = sha256(job, source);
                if (!got.equals(pin)) {
                    if (source == archive)
                        archive.delete(); // a bad/foreign file would fail every retry otherwise
                    throw new IOException("the rootfs's checksum doesn't match this app's (expected sha256 " + pin.substring(0, 16)
                            + "…, got " + got.substring(0, 16) + "…): refusing to install it. "
                            + (source == local ? "Remove " + local + ", or" : "The published rootfs (" + job.url
                            + ") is not the one this app was built for:") + " rebuild the app after the rootfs is published");
                }
                set(job, InstallJob.Step.UNPACK, 0, source.length(), "Unpacking…");
            }
            if (job.step == InstallJob.Step.UNPACK) {
                File rootfs = SessionService.rootfs(this);
                File partial = new File(rootfs.getPath() + ".partial");
                deleteTree(partial); // idempotent: an unpack that stopped halfway starts over from the checked archive
                extract(job, source, partial);
                File setup = new File(partial, "root/.config/andromarchy/setup.conf");
                setup.getParentFile().mkdirs();
                try (FileWriter w = new FileWriter(setup)) {
                    w.write(job.conf);
                }
                if (!partial.renameTo(rootfs))
                    throw new IOException("could not move the rootfs into place");
                archive.delete(); // ~1 GB we no longer need
                set(job, InstallJob.Step.PACKS, 0, -1, "Finishing…");
            }
            if (job.step == InstallJob.Step.PACKS) {
                // Not fatal: PowOS runs without it, and Settings > Storage adds the pack later (an offline phone
                // must still reach the desktop, as before this was a job).
                if (job.base && !Locale.getDefault().getLanguage().equals("en"))
                    try {
                        Packs.install(this, "languages", (phase, done, total) -> progress(job, done, total,
                                (phase.equals("installing") ? "Installing " : "Downloading ") + Locale.getDefault().getDisplayLanguage()
                                        + " (" + (done >> 20) + (total > 0 ? " / " + (total >> 20) : "") + " MB)"));
                    } catch (IOException e) {
                        Log.w(TAG, "languages pack not installed; Settings > Storage adds it later", e);
                    }
            }
            job.status = InstallJob.Status.DONE;
            set(job, InstallJob.Step.DONE, 1, 1, "PowOS is installed");
            SessionService.start(this); // the session waited for this (SessionPlan.WAIT_IMAGE)
        } catch (Throwable e) { // shown, never a crash: the user retries from the form
            Log.w(TAG, "install failed at " + job.step, e);
            job.fail(String.valueOf(e.getMessage()));
            save(job, true);
            notifyListeners();
        } finally {
            worker = null;
            finish(job);
        }
    }

    private File archive(InstallJob job) {
        return new File(getFilesDir(), localName(job) + ".download");
    }

    /** A local copy (adb push to the external files dir, or files/): used instead of a download. */
    private File localCopy(InstallJob job) {
        File external = new File(getExternalFilesDir(null), localName(job));
        return external.canRead() ? external : new File(getFilesDir(), localName(job));
    }

    private static String localName(InstallJob job) {
        return job.base ? "powos-rootfs-base.tar.gz" : InstallActivity.LOCAL_NAME;
    }

    /** Resumable: continues the bytes on disk with Range + If-Range (see InstallJob.resumeFrom). */
    private void download(InstallJob job, File archive) throws IOException {
        long from = InstallJob.resumeFrom(job, job.url, archive.length());
        HttpURLConnection c = (HttpURLConnection) new URL(job.url).openConnection();
        c.setInstanceFollowRedirects(true);
        c.setConnectTimeout(15_000);
        c.setReadTimeout(60_000);
        if (from > 0) {
            c.setRequestProperty("Range", "bytes=" + from + "-");
            c.setRequestProperty("If-Range", job.validator);
        }
        c.connect();
        int code = c.getResponseCode();
        if (code != 200 && code != 206)
            throw new IOException("download: HTTP " + code);
        boolean append = InstallJob.appends(from, code);
        long start = append ? from : 0;
        long len = c.getContentLengthLong();
        long total = len > 0 ? len + start : -1;
        String v = c.getHeaderField("ETag");
        if (v == null)
            v = c.getHeaderField("Last-Modified");
        job.validator = v == null ? "" : v;
        set(job, InstallJob.Step.DOWNLOAD, start, total, label("Downloading PowOS", start, total));
        byte[] buf = new byte[1 << 20];
        long done = start;
        try (InputStream in = c.getInputStream(); OutputStream out = new FileOutputStream(archive, append)) {
            for (int n; (n = in.read(buf)) > 0; ) {
                out.write(buf, 0, n);
                done += n;
                progress(job, done, total, label("Downloading PowOS", done, total));
            }
        }
        if (total > 0 && archive.length() != total)
            throw new IOException("the download was cut short at " + (archive.length() >> 20) + " MB; retry to continue it");
    }

    private String sha256(InstallJob job, File f) throws IOException {
        MessageDigest md;
        try {
            md = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IOException(e);
        }
        byte[] buf = new byte[1 << 20];
        long read = 0, size = f.length();
        try (InputStream in = new FileInputStream(f)) {
            for (int n; (n = in.read(buf)) > 0; ) {
                md.update(buf, 0, n);
                read += n;
                progress(job, read, size, label("Checking the download", read, size));
            }
        }
        StringBuilder hex = new StringBuilder(64);
        for (byte b : md.digest())
            hex.append(String.format(Locale.ROOT, "%02x", b));
        return hex.toString();
    }

    private void extract(InstallJob job, File archive, File partial) throws IOException {
        final long size = archive.length();
        long[] read = {0};
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
            TarExtractor.extract(in, partial, entry ->
                    progress(job, read[0], size, label("Installing", read[0], size) + "\n" + entry));
        }
    }

    private static String label(String what, long done, long total) {
        return what + " (" + (done >> 20) + (total > 0 ? " / " + (total >> 20) : "") + " MB)";
    }

    /** A new step: saved at once. */
    private void set(InstallJob job, InstallJob.Step step, long done, long total, String text) {
        job.step = step;
        job.done = done;
        job.total = total;
        job.text = text;
        save(job, true);
        notifyListeners();
        updateNotification(job, true);
    }

    /** Progress within a step: screens at most every 200 ms, the notification every second, disk every 3 s. */
    private void progress(InstallJob job, long done, long total, String text) {
        job.done = done;
        job.total = total;
        job.text = text;
        long now = System.currentTimeMillis();
        if (now - lastNotified < 200)
            return;
        notifyListeners();
        updateNotification(job, false);
        save(job, false);
    }

    private void save(InstallJob job, boolean now) {
        long t = System.currentTimeMillis();
        if (!now && t - lastSaved < 3000)
            return;
        lastSaved = t;
        try {
            job.save(jobFile(this));
        } catch (IOException e) {
            Log.w(TAG, "install job not saved", e);
        }
    }

    private static void notifyListeners() {
        for (Runnable r : listeners)
            try {
                r.run();
            } catch (RuntimeException e) {
                Log.w(TAG, "install listener", e);
            }
    }

    private long lastNotificationUpdate;

    private void updateNotification(InstallJob job, boolean force) {
        long now = System.currentTimeMillis();
        lastNotified = now;
        if (!force && now - lastNotificationUpdate < 1000)
            return;
        lastNotificationUpdate = now;
        getSystemService(NotificationManager.class).notify(NOTIFICATION_ID, notification(job));
    }

    private Notification notification(InstallJob job) {
        PendingIntent open = PendingIntent.getActivity(this, 1,
                new Intent(this, InstallActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder b = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("Installing PowOS")
                .setContentText(job == null ? "Starting…" : job.text.split("\n")[0])
                .setContentIntent(open)
                .setOnlyAlertOnce(true)
                .setOngoing(true);
        int pm = job == null ? -1 : job.permille();
        b.setProgress(1000, Math.max(pm, 0), pm < 0);
        return b.build();
    }

    /** The worker ended: done or failed. The foreground notification goes; a done/failed one stays for the user. */
    private void finish(InstallJob job) {
        stopForeground(STOP_FOREGROUND_REMOVE);
        boolean ok = job.status == InstallJob.Status.DONE;
        PendingIntent open = PendingIntent.getActivity(this, 2,
                new Intent(this, ok ? MainActivity.class : InstallActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE);
        getSystemService(NotificationManager.class).notify(NOTIFICATION_ID + 1, new Notification.Builder(this, CHANNEL)
                .setSmallIcon(ok ? android.R.drawable.stat_sys_download_done : android.R.drawable.stat_notify_error)
                .setContentTitle(ok ? "PowOS is installed" : "PowOS install stopped")
                .setContentText(ok ? "Tap to open PowOS" : job.error)
                .setContentIntent(open)
                .setAutoCancel(true)
                .build());
        stopSelf();
    }

    static void deleteTree(File f) {
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
