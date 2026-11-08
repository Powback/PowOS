package andro.marchy;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Properties;

/**
 * The no-root PowOS install as a persisted job (InstallService runs it, InstallActivity only shows it). Pure Java: the
 * state machine and its file format are JVM-tested (InstallJobTest).
 *
 * 2026-11-08, razr fold (no root): "the launcher keeps restarting the install when resized or when backgrounded or
 * locked". The install ran on a thread owned by InstallActivity; a fold (resize -> recreate), the launcher coming back
 * (HOME / unlock -> a new MainActivity -> a new InstallActivity) or process death showed the setup form again with no
 * progress, and the next "Install" deleted the download and started from 0 MB. Now the job lives in a foreground
 * service, its step and bytes are on disk, the download resumes (HTTP Range + If-Range, checked whole against the pin
 * afterwards), unpacking restarts cleanly into rootfs.partial, and every screen attaches to the job instead of
 * starting one.
 */
final class InstallJob {
    /** Steps in order; a job resumes at its persisted step. */
    enum Step {
        DOWNLOAD, VERIFY, UNPACK, PACKS, DONE
    }

    /** Whether a worker is on it: RUNNING after process death means "resume", see [onOpen]. */
    enum Status {
        RUNNING, FAILED, DONE
    }

    /** What a screen opened on the install does. */
    enum Attach {
        /** No job (or a finished one whose rootfs is gone): the setup form. */
        FORM,
        /** A worker is running it: show its progress. */
        WATCH,
        /** It was running when the process died: restart the worker (it resumes), show its progress. */
        RESUME,
        /** It stopped with an error: the form with the error; "Install" retries keeping what was downloaded. */
        FAILED,
        /** Finished: go on to the desktop. */
        DONE
    }

    Step step = Step.DOWNLOAD;
    Status status = Status.RUNNING;
    /** setup.conf (the form's answers), written into the rootfs at the end of UNPACK. */
    String conf = "";
    /** The base image instead of the full rootfs (InstallActivity.useBase at the start; fixed for the job). */
    boolean base;
    /** The download's URL; a resume only appends to bytes from this same URL. */
    String url = "";
    /** ETag or Last-Modified of the partial download: If-Range, so two versions of the image are never spliced. */
    String validator = "";
    /** Progress of the current step, in bytes (total -1 = unknown). */
    long done, total = -1;
    /** What the screen and the notification say. */
    String text = "";
    String error = "";

    /** The step's progress in per mille, or -1 when unknown. */
    int permille() {
        if (step == Step.DONE)
            return 1000;
        if (total <= 0)
            return -1;
        return (int) Math.max(0, Math.min(1000, done * 1000 / total));
    }

    /** The decision for a screen opened on the install (the form, the launcher's redirect, an app restart). */
    static Attach onOpen(InstallJob job, boolean rootfsReady, boolean workerAlive) {
        if (job == null)
            return rootfsReady ? Attach.DONE : Attach.FORM;
        if (job.status == Status.DONE || job.step == Step.DONE)
            return rootfsReady ? Attach.DONE : Attach.FORM; // removed since: a fresh install
        if (workerAlive)
            return Attach.WATCH;
        if (job.status == Status.FAILED)
            return Attach.FAILED;
        return Attach.RESUME;
    }

    /** Whether a start request (the form's button, a service restart) runs a worker; never a second one. */
    static boolean shouldRun(InstallJob job, boolean workerAlive) {
        return !workerAlive && job != null && job.status != Status.DONE && job.step != Step.DONE;
    }

    /**
     * Where the download continues: the bytes already on disk when they come from the same URL and the server gave a
     * validator for them (If-Range then makes it send the whole file again if it changed); otherwise from 0.
     */
    static long resumeFrom(InstallJob job, String url, long partialBytes) {
        if (job == null || partialBytes <= 0 || !url.equals(job.url) || job.validator.isEmpty())
            return 0;
        return partialBytes;
    }

    /** After the request: append on 206 from [from]; any other success starts the file over. */
    static boolean appends(long from, int httpCode) {
        return from > 0 && httpCode == 206;
    }

    /** The step to run when a worker (re)starts: a missing archive past DOWNLOAD (deleted, or a local copy taken away)
     *  sends it back to DOWNLOAD; a missing rootfs.partial at PACKS can't happen (renamed into place by then). */
    static Step resumeStep(InstallJob job, boolean archivePresent) {
        if ((job.step == Step.VERIFY || job.step == Step.UNPACK) && !archivePresent)
            return Step.DOWNLOAD;
        return job.step;
    }

    /** A fresh job for the form's answers. */
    static InstallJob fresh(String conf, boolean base, String url) {
        InstallJob j = new InstallJob();
        j.conf = conf;
        j.base = base;
        j.url = url;
        j.text = "Starting the download…";
        return j;
    }

    /** A retry of a failed job: same answers, same partial download. */
    void retry() {
        status = Status.RUNNING;
        error = "";
        text = "Retrying…";
    }

    void fail(String message) {
        status = Status.FAILED;
        error = message == null ? "unknown error" : message;
    }

    // --- persistence: a properties file, written atomically ---

    Properties toProperties() {
        Properties p = new Properties();
        p.setProperty("step", step.name());
        p.setProperty("status", status.name());
        p.setProperty("conf", conf);
        p.setProperty("base", Boolean.toString(base));
        p.setProperty("url", url);
        p.setProperty("validator", validator);
        p.setProperty("done", Long.toString(done));
        p.setProperty("total", Long.toString(total));
        p.setProperty("text", text);
        p.setProperty("error", error);
        return p;
    }

    /** Null for an unreadable or foreign file: the screen shows the form, as without a job. */
    static InstallJob fromProperties(Properties p) {
        try {
            InstallJob j = new InstallJob();
            j.step = Step.valueOf(p.getProperty("step"));
            j.status = Status.valueOf(p.getProperty("status"));
            j.conf = p.getProperty("conf", "");
            j.base = Boolean.parseBoolean(p.getProperty("base", "false"));
            j.url = p.getProperty("url", "");
            j.validator = p.getProperty("validator", "");
            j.done = Long.parseLong(p.getProperty("done", "0"));
            j.total = Long.parseLong(p.getProperty("total", "-1"));
            j.text = p.getProperty("text", "");
            j.error = p.getProperty("error", "");
            return j;
        } catch (RuntimeException e) {
            return null;
        }
    }

    static InstallJob load(File f) {
        if (!f.exists())
            return null;
        Properties p = new Properties();
        try (InputStream in = new FileInputStream(f)) {
            p.load(in);
        } catch (IOException e) {
            return null;
        }
        return fromProperties(p);
    }

    void save(File f) throws IOException {
        File tmp = new File(f.getPath() + ".tmp");
        try (OutputStream out = new FileOutputStream(tmp)) {
            toProperties().store(out, "PowOS install job (InstallJob)");
        }
        if (!tmp.renameTo(f))
            throw new IOException("could not save " + f);
    }

    InstallJob copy() {
        return fromProperties(toProperties());
    }
}
