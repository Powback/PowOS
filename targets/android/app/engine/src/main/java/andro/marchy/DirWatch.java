package andro.marchy;

import android.os.FileObserver;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * One inotify watch per folder for the whole process, shared by everyone who watches that folder.
 *
 * android.os.FileObserver can't share a folder: inotify gives every watch of one inode the same descriptor, and
 * FileObserver's thread keeps ONE observer per descriptor - the last one started takes every event - while
 * stopWatching() removes the descriptor for all of them. In the run dir this lost "android-request": the desktop
 * activity's focused-window watch took its events while it lived, and its onDestroy ended the requests' watch for the
 * rest of the process, so `android-request power logout` did nothing and KWin was never restarted onto a newly
 * installed package (2026-10-23 22:42, board linux-stale-window-tasks). Watch a folder others may watch through this.
 */
public final class DirWatch {
    /** An event of the watched folder: FileObserver's [event] (masked to the listener's) and the file's name. */
    public interface Listener {
        void onEvent(int event, String path);
    }

    /** What {@link #watch} returns: {@link #stop()} ends this listener only. */
    public static final class Handle {
        private final String key;
        private final int mask;
        private final Listener listener;
        private volatile boolean stopped;

        private Handle(String key, int mask, Listener listener) {
            this.key = key;
            this.mask = mask;
            this.listener = listener;
        }

        public void stop() {
            synchronized (DirWatch.class) {
                if (stopped)
                    return;
                stopped = true;
                Folder f = folders.get(key);
                if (f == null)
                    return;
                f.handles.remove(this);
                if (f.handles.isEmpty()) {
                    folders.remove(key);
                    f.observer.stopWatching();
                } else {
                    f.rewatch();
                }
            }
        }
    }

    private static final class Folder {
        final File dir;
        final List<Handle> handles = new ArrayList<>();
        FileObserver observer;
        int mask;

        Folder(File dir) {
            this.dir = dir;
        }

        /** The observer again with the union of the listeners' masks, when that changed. */
        void rewatch() {
            int m = 0;
            for (Handle h : handles)
                m |= h.mask;
            if (observer != null && m == mask)
                return;
            // The old one first: stopping it after would remove the shared descriptor the new one just got.
            if (observer != null)
                observer.stopWatching();
            mask = m;
            observer = new FileObserver(dir, m) {
                @Override
                public void onEvent(int event, String path) {
                    Handle[] now;
                    synchronized (DirWatch.class) {
                        now = handles.toArray(new Handle[0]);
                    }
                    for (Handle h : now) {
                        int e = event & h.mask;
                        if (e != 0 && !h.stopped)
                            h.listener.onEvent(e, path);
                    }
                }
            };
            observer.startWatching();
        }
    }

    private static final Map<String, Folder> folders = new HashMap<>();

    private DirWatch() {
    }

    /** [listener] hears [dir]'s events in [mask] (FileObserver's bits) on FileObserver's thread, until stopped. */
    public static synchronized Handle watch(File dir, int mask, Listener listener) {
        String key = dir.getAbsolutePath();
        Folder f = folders.get(key);
        if (f == null) {
            f = new Folder(dir);
            folders.put(key, f);
        }
        Handle h = new Handle(key, mask, listener);
        f.handles.add(h);
        f.rewatch();
        return h;
    }
}
