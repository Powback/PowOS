package andro.marchy;

import java.util.Objects;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;

/**
 * The display connection's stop/start order, off the main thread (plain Java, JVM-tested: NativeStarterTest).
 *
 * Native.nativeStop joins the render and event threads and tears the connection down: 577 ms on the UI thread in a
 * recorded surfaceDestroyed (perf-1793409569119), and a start that waited for the queued stop on the main thread froze
 * it 450-560 ms on every page swipe (perf-1793735444160: windows.slide -> surfaceChanged -> startNative ->
 * awaitPendingStop, 190 janks in 50 s). Every stop runs on one serial thread; a [start] queues a stop there too (a start
 * always replaces the connection) and the start itself runs on [main] once that stop is done - the main thread never
 * waits. A stop or start that came later makes a queued start stale: it is dropped (the newest wins).
 *
 * A start for the very surface already connected, at the same size and format ([unchanged]), is skipped: a
 * surfaceChanged that changed nothing must not reconnect the desktop.
 */
public final class NativeStarter {
    private final ExecutorService stopThread;
    private final Executor main;
    private final Runnable stop;

    /** Bumped by every [start] and [stop]; a queued start runs only while it is still the newest. Main thread. */
    private int generation;
    private volatile Future<?> pending;
    /** What the running (or starting) connection is on: surface, width, height, format; null: unknown or none. */
    private Object connectedTo;

    public NativeStarter(ExecutorService stopThread, Executor main, Runnable stop) {
        this.stopThread = stopThread;
        this.main = main;
        this.stop = stop;
    }

    /** The key [start]/[unchanged] compare: the same Surface object at the same size and format. */
    public static Object key(Object surface, int width, int height, int format) {
        return java.util.Arrays.asList(System.identityHashCode(surface), width, height, format);
    }

    /** The connection is on [key] already (and nothing stopped it since). */
    public boolean unchanged(Object key) {
        return key != null && Objects.equals(key, connectedTo);
    }

    /**
     * Replaces the connection: a stop on the stop thread, then [start] on the main executor - unless another
     * [start]/[stop] came meanwhile. Returns at once. [key]: what it connects to (null: unknown, never [unchanged]).
     */
    public void start(Object key, Runnable start) {
        final int g = ++generation;
        connectedTo = key;
        pending = stopThread.submit(() -> {
            stop.run();
            main.execute(() -> {
                if (g == generation)
                    start.run();
            });
        });
    }

    /** Disconnects, on the stop thread; a start still queued is dropped. Returns at once. */
    public void stop() {
        ++generation;
        connectedTo = null;
        pending = stopThread.submit(stop);
    }

    /** A stop or start is still queued or running on the stop thread. */
    public boolean busy() {
        Future<?> f = pending;
        return f != null && !f.isDone();
    }

    /**
     * Blocks until the queued stop has run. Only for a caller that must not overlap it (a new fd handed to the native
     * side, which a stop closes); never a surface callback.
     */
    public void await() {
        Future<?> f = pending;
        if (f == null)
            return;
        try {
            f.get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (ExecutionException e) {
            android.util.Log.w("NativeStarter", "async nativeStop failed", e.getCause());
        }
        if (pending == f)
            pending = null;
    }
}
