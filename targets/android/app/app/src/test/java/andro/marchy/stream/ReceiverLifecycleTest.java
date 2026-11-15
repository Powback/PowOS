package andro.marchy.stream;

import org.junit.Test;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;

/** Tests the production lifecycle directly, without an Android/codec stand-in in shipped code. */
public class ReceiverLifecycleTest {
    private void finish(ReceiverLifecycle lifecycle, AtomicReference<String> state, AtomicInteger retires) {
        if (!lifecycle.finishOnWorker()) return;
        retires.incrementAndGet();
        state.set(lifecycle.failedOnWorker() ? "FAILED" : "CLOSED");
    }

    @Test public void failureWinsWhileClosePausedAfterCasBeforeEnqueue() throws Exception {
        ReceiverLifecycle lifecycle = new ReceiverLifecycle();
        AtomicReference<String> state = new AtomicReference<>("CONNECTING");
        AtomicInteger retires = new AtomicInteger();
        CountDownLatch afterCas = new CountDownLatch(1), resume = new CountDownLatch(1);
        AtomicReference<Runnable> queued = new AtomicReference<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread caller = new Thread(() -> {
            try {
                lifecycle.requestClose(() -> {
                    afterCas.countDown();
                    try { assertTrue(resume.await(2, TimeUnit.SECONDS)); }
                    catch (InterruptedException e) { throw new AssertionError(e); }
                    queued.set(() -> {
                        lifecycle.closingOnWorker(() -> state.set("CLOSING"));
                        finish(lifecycle, state, retires);
                    });
                });
            } catch (Throwable e) { failure.set(e); }
        });
        caller.start();
        try {
            assertTrue(afterCas.await(2, TimeUnit.SECONDS));
            assertTrue(lifecycle.isClosing());
            assertEquals("CONNECTING", state.get()); // Caller never publishes CLOSING.
            assertTrue(lifecycle.failOnWorker());
            state.set("FAILED");
            finish(lifecycle, state, retires);
        } finally { resume.countDown(); }
        caller.join(2000);
        assertFalse(caller.isAlive());
        assertNull(failure.get());
        assertEquals("FAILED", state.get()); // Enqueue after worker exit cannot overwrite terminal.
        queued.get().run(); // Even if the late callback executes, retirement is idempotent.
        lifecycle.requestClose(() -> fail("Repeated close must not enqueue"));
        assertFalse(lifecycle.failOnWorker());
        assertEquals("FAILED", state.get());
        assertEquals(1, retires.get());
    }

    @Test public void normalCloseAndRepeatedCloseRetireOnce() {
        ReceiverLifecycle lifecycle = new ReceiverLifecycle();
        AtomicReference<String> state = new AtomicReference<>("CONNECTING");
        AtomicReference<Runnable> queued = new AtomicReference<>();
        AtomicInteger retires = new AtomicInteger();
        lifecycle.requestClose(() -> queued.set(() -> {
            lifecycle.closingOnWorker(() -> state.set("CLOSING"));
            assertEquals("CLOSING", state.get());
            finish(lifecycle, state, retires);
        }));
        assertEquals("CONNECTING", state.get());
        lifecycle.requestClose(() -> fail("Repeated close must not enqueue"));
        queued.get().run();
        lifecycle.closingOnWorker(() -> fail("Cannot publish after terminal"));
        finish(lifecycle, state, retires);
        lifecycle.requestClose(() -> fail("Closed receiver must not enqueue"));
        assertFalse(lifecycle.failOnWorker());
        assertEquals("CLOSED", state.get());
        assertEquals(1, retires.get());
    }

    @Test public void failureThenRepeatedCloseKeepsFailure() {
        ReceiverLifecycle lifecycle = new ReceiverLifecycle();
        AtomicReference<String> state = new AtomicReference<>("CONNECTING");
        AtomicInteger retires = new AtomicInteger();
        assertTrue(lifecycle.failOnWorker());
        lifecycle.closingOnWorker(() -> fail("Failure cannot become closing"));
        lifecycle.requestClose(() -> fail("Failure already requested cancellation"));
        finish(lifecycle, state, retires);
        finish(lifecycle, state, retires);
        lifecycle.requestClose(() -> fail("Terminal failure cannot enqueue"));
        assertEquals("FAILED", state.get());
        assertEquals(1, retires.get());
    }
}
