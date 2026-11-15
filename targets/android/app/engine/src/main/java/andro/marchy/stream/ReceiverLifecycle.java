package andro.marchy.stream;

import java.util.concurrent.atomic.AtomicBoolean;

/** Cancellation is cross-thread; state publication and retirement belong exclusively to the worker. */
public final class ReceiverLifecycle {
    private final AtomicBoolean requested = new AtomicBoolean();
    private boolean finished;
    private boolean failed;

    public boolean isClosing() { return requested.get(); }

    /** enqueue must only enqueue worker work, never publish state on the requesting thread. */
    public void requestClose(Runnable enqueue) {
        if (requested.compareAndSet(false, true)) enqueue.run();
    }

    /** Worker only. Late queued close work must not overwrite a terminal result. */
    public void closingOnWorker(Runnable publishClosing) {
        if (!finished && !failed) publishClosing.run();
    }

    /** Worker only. Returns false after retirement has already started. */
    public boolean failOnWorker() {
        if (finished) return false;
        requested.set(true);
        failed = true;
        return true;
    }

    /** Worker only. Exactly one caller may retire native/codec resources and publish terminal state. */
    public boolean finishOnWorker() {
        if (finished) return false;
        requested.set(true);
        finished = true;
        return true;
    }

    public boolean failedOnWorker() { return failed; }
}
