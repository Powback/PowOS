package andro.marchy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.util.Log;

import java.io.File;
import java.nio.file.Files;
import java.util.concurrent.ConcurrentHashMap;

/**
 * One progress surface for long first-run jobs (Powback/PowOS#11: the first Steam launch spent 3+ minutes adding the
 * gaming pack, fetching Valve's bootstrap and letting Steam update itself, all of it on stderr nobody saw): an ongoing
 * Android notification with a progress bar per job, named for people ("Adding gaming support (0.9 GB)").
 *
 * Two sources: the app's own jobs call [update]/[finish]/[failed] (Packs), and the Linux session writes
 * run/progress-ID.state (the powos-progress helper, atomically by rename; each job its own file, so a fast update
 * never overwrites another job's or a request's), which AndroidRequests' run-dir watch hands to [fromFile]:
 *   line 1 "DONE TOTAL" (bytes or any unit; TOTAL 0 = indeterminate), "done", or "failed MESSAGE"; line 2 the title.
 */
public final class Progress {
    private static final String TAG = "Progress";
    private static final String CHANNEL = "powos-progress";
    /** The last title per job: a "failed" line keeps the job's name. */
    private static final ConcurrentHashMap<String, String> titles = new ConcurrentHashMap<>();
    /** Per job: the last percent shown, so a busy job doesn't re-post the same notification many times a second. */
    private static final ConcurrentHashMap<String, Integer> shown = new ConcurrentHashMap<>();

    private Progress() {}

    private static NotificationManager nm(Context ctx) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm != null && nm.getNotificationChannel(CHANNEL) == null)
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Downloads and setup", NotificationManager.IMPORTANCE_LOW));
        return nm;
    }

    private static int nid(String id) {
        return 0x50570000 | (id.hashCode() & 0xffff);
    }

    /** Job [id] ([title]) at [done] of [total] (total <= 0: indeterminate). Any thread. */
    public static void update(Context ctx, String id, String title, long done, long total) {
        int pct = total > 0 ? (int) Math.min(100, Math.max(0, done * 100 / total)) : -1;
        String was = titles.put(id, title);
        Integer last = shown.put(id, pct);
        if (last != null && last == pct && title.equals(was))
            return;
        NotificationManager nm = nm(ctx);
        if (nm == null)
            return;
        Notification.Builder b = new Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setContentText(pct >= 0 ? pct + "%" : "")
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setProgress(100, Math.max(pct, 0), pct < 0);
        nm.notify(nid(id), b.build());
    }

    /** Job [id] is done: its notification goes. */
    public static void finish(Context ctx, String id) {
        titles.remove(id);
        shown.remove(id);
        NotificationManager nm = nm(ctx);
        if (nm != null)
            nm.cancel(nid(id));
    }

    /** Job [id] failed with [message]: a notification that stays until dismissed. */
    public static void failed(Context ctx, String id, String message) {
        String title = titles.remove(id);
        shown.remove(id);
        NotificationManager nm = nm(ctx);
        if (nm == null)
            return;
        nm.notify(nid(id), new Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_error)
                .setContentTitle((title == null ? id : title) + " failed")
                .setContentText(message)
                .setAutoCancel(true)
                .build());
    }

    /** A job id from a file name "progress-ID.state", or null. */
    static String idOf(String name) {
        if (name == null || !name.startsWith("progress-") || !name.endsWith(".state"))
            return null;
        String id = name.substring("progress-".length(), name.length() - ".state".length());
        return id.matches("[A-Za-z0-9._-]{1,64}") ? id : null;
    }

    /** run/progress-ID.state changed: shown as [update], [finish] or [failed]. */
    static void fromFile(Context ctx, File f) {
        String id = idOf(f.getName());
        if (id == null)
            return;
        String[] lines;
        try {
            lines = new String(Files.readAllBytes(f.toPath())).split("\n", 3);
        } catch (Exception e) {
            return; // replaced meanwhile: the next event has it
        }
        Parsed p = parse(lines[0], lines.length > 1 ? lines[1].trim() : "");
        if (p == null) {
            Log.w(TAG, "bad progress line for " + id + ": " + lines[0]);
            return;
        }
        if (p.kind == Kind.DONE) {
            finish(ctx, id);
            f.delete();
        } else if (p.kind == Kind.FAILED) {
            failed(ctx, id, p.message);
            f.delete();
        } else {
            update(ctx, id, p.title.isEmpty() ? id : p.title, p.done, p.total);
        }
    }

    enum Kind { PROGRESS, DONE, FAILED }

    /** A state file's content, parsed (pure: unit-tested). */
    static final class Parsed {
        final Kind kind;
        final long done, total;
        final String title, message;

        Parsed(Kind kind, long done, long total, String title, String message) {
            this.kind = kind;
            this.done = done;
            this.total = total;
            this.title = title;
            this.message = message;
        }
    }

    /** [state] ("DONE TOTAL" | "done" | "failed MESSAGE") with [title]; null when it is none of those. */
    static Parsed parse(String state, String title) {
        String s = state == null ? "" : state.trim();
        if (s.equals("done"))
            return new Parsed(Kind.DONE, 0, 0, title, "");
        if (s.equals("failed") || s.startsWith("failed "))
            return new Parsed(Kind.FAILED, 0, 0, title, s.length() > 7 ? s.substring(7).trim() : "");
        String[] n = s.split("\\s+");
        if (n.length != 2)
            return null;
        try {
            return new Parsed(Kind.PROGRESS, Long.parseLong(n[0]), Long.parseLong(n[1]), title, "");
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
