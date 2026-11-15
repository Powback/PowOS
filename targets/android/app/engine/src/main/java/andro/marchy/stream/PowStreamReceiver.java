package andro.marchy.stream;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Surface;
import java.nio.ByteBuffer;
import java.util.ArrayDeque;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Transport + async hardware decoder on an EXISTING window Surface. No auth acquisition or UI. */
public final class PowStreamReceiver implements AutoCloseable {
    public enum State { CONNECTING, WAITING_IDR, DECODING, RENDERED, CLOSING, CLOSED, FAILED }
    public static final class Progress {
        public final State state;
        public final String detail;
        Progress(State state, String detail) { this.state = state; this.detail = detail; }
    }
    private static final int MAX_AU = 4 * 1024 * 1024;
    private final HandlerThread thread = new HandlerThread("PowStreamReceiver");
    private final Handler worker;
    private final Surface surface; // Borrowed: never release the caller's Surface.
    private final ReceiverLifecycle lifecycle = new ReceiverLifecycle();
    private final CountDownLatch stopped = new CountDownLatch(1);
    private final ArrayDeque<Integer> inputs = new ArrayDeque<>();
    private final H264Continuity continuity = new H264Continuity();
    private final long[] meta = new long[6];
    private ByteBuffer bytes = ByteBuffer.allocateDirect(256 * 1024);
    private PowStreamCore core;
    private MediaCodec codec;
    private boolean pending;
    private long presentationUs;
    private volatile Progress progress = new Progress(State.CONNECTING, "Starting authenticated transport");

    /** Caller authenticates bootstrap over trusted HTTPS and supplies its decoded certificate hash.
     * Strings are transient, never logged/stored. Surface must remain alive until awaitClosed succeeds.
     */
    public PowStreamReceiver(String endpoint, String token, byte[] certSha256, Surface surface) {
        if (endpoint == null || token == null || token.isEmpty() || certSha256 == null
                || certSha256.length != 32 || surface == null || !surface.isValid())
            throw new IllegalArgumentException("Valid authenticated bootstrap and Surface required");
        this.surface = surface;
        byte[] pin = certSha256.clone();
        thread.start(); worker = new Handler(thread.getLooper());
        worker.post(() -> {
            if (lifecycle.isClosing()) return;
            try {
                core = new PowStreamCore(endpoint, token, pin);
                tick();
            } catch (Exception | LinkageError e) { fail("Native open failed"); }
            finally { java.util.Arrays.fill(pin, (byte)0); }
        });
    }
    public Progress progress() { return progress; }
    private void report(State state, String detail) { progress = new Progress(state, detail); }

    private void tick() {
        if (lifecycle.isClosing()) return;
        try {
            if (!surface.isValid()) throw new IllegalStateException("Surface destroyed");
            int state = core.state();
            if (state < 0 || state >= 2) { fail("Transport closed or failed; refresh bootstrap before reopening"); return; }
            if (state == 1 && progress.state == State.CONNECTING) report(State.WAITING_IDR, "Connected; awaiting SPS/PPS + IDR");
            if (!pending) receive();
            feed();
            if (!lifecycle.isClosing()) worker.postDelayed(this::tick, 4);
        } catch (Exception e) { fail("Receive/decode failed"); }
    }
    private void receive() throws Exception {
        bytes.clear();
        int result = core.poll(bytes, meta);
        if (result == PowStreamCore.SMALL) {
            if (meta[0] <= 0 || meta[0] > MAX_AU) throw new IllegalStateException("Oversized AU");
            bytes = ByteBuffer.allocateDirect((int)meta[0]);
            return; // A newer AU may replace the pending native slot; retry on the next tick.
        }
        if (result == PowStreamCore.EMPTY) return;
        if (result != PowStreamCore.OK) throw new IllegalStateException("Native poll failed");
        if (meta[0] <= 0 || meta[0] > bytes.capacity() || meta[2] <= 0 || meta[3] <= 0
                || meta[2] > 8192 || meta[3] > 8192) throw new IllegalStateException("Invalid AU geometry");
        bytes.limit((int)meta[0]);
        H264Continuity.Action action = continuity.accept(bytes, meta[1], (int)meta[2], (int)meta[3]);
        if (action == H264Continuity.Action.DROP) {
            // Do not leave pre-gap output queued for presentation while awaiting recovery.
            releaseCodec();
            report(State.WAITING_IDR, "Reference/format discontinuity; awaiting SPS/PPS + IDR");
            return;
        }
        if (action == H264Continuity.Action.RECREATE) configure();
        pending = true;
    }
    private void configure() throws Exception {
        releaseCodec();
        MediaFormat format = MediaFormat.createVideoFormat("video/avc", (int)meta[2], (int)meta[3]);
        format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
        format.setInteger(MediaFormat.KEY_PRIORITY, 0);
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, MAX_AU);
        format.setByteBuffer("csd-0", ByteBuffer.wrap(H264Continuity.nal(bytes, 7)));
        format.setByteBuffer("csd-1", ByteBuffer.wrap(H264Continuity.nal(bytes, 8)));
        codec = MediaCodec.createDecoderByType("video/avc");
        codec.setCallback(callback, worker);
        codec.configure(format, surface, null, 0);
        codec.start();
        report(State.DECODING, "Decoder configured; awaiting output");
    }
    private void feed() {
        if (!pending || inputs.isEmpty() || codec == null) return;
        int index = inputs.removeFirst();
        ByteBuffer input = codec.getInputBuffer(index);
        if (input == null || input.capacity() < bytes.remaining()) throw new IllegalStateException("Codec input too small");
        input.clear(); input.put(bytes.duplicate());
        // Local monotonic presentation order only. Server timestamps are a different clock domain.
        presentationUs = Math.max(presentationUs + 1, System.nanoTime() / 1000);
        codec.queueInputBuffer(index, 0, bytes.remaining(), presentationUs, 0);
        pending = false;
    }
    private final MediaCodec.Callback callback = new MediaCodec.Callback() {
        @Override public void onInputBufferAvailable(MediaCodec source, int index) {
            if (source != codec || lifecycle.isClosing()) return;
            try { inputs.addLast(index); feed(); }
            catch (Exception e) { fail("Decoder input failed"); }
        }
        @Override public void onOutputBufferAvailable(MediaCodec source, int index, MediaCodec.BufferInfo info) {
            if (source != codec || lifecycle.isClosing()) return;
            try {
                source.releaseOutputBuffer(index, true);
                report(State.RENDERED, "Decoded output submitted to Surface (not a glass timestamp)");
            } catch (Exception e) { fail("Decoder output failed"); }
        }
        @Override public void onOutputFormatChanged(MediaCodec source, MediaFormat format) {
            if (source == codec && !lifecycle.isClosing()) report(State.DECODING, "Decoder output format changed");
        }
        @Override public void onError(MediaCodec source, MediaCodec.CodecException error) {
            if (source == codec && !lifecycle.isClosing()) fail("MediaCodec failure; close and reopen with fresh bootstrap");
        }
    };
    private void releaseCodec() {
        MediaCodec old = codec; codec = null;
        inputs.clear(); pending = false;
        if (old != null) old.release();
    }
    private void fail(String detail) {
        if (!lifecycle.failOnWorker()) return;
        report(State.FAILED, detail);
        finish();
    }
    /** Nonblocking cancellation. No JNI call can race native close: all are on worker. */
    @Override public void close() {
        lifecycle.requestClose(() -> worker.postAtFrontOfQueue(() -> {
            lifecycle.closingOnWorker(() -> report(State.CLOSING, "Cancelling receiver"));
            finish();
        }));
    }
    /** Bounded wait for callers OFF the UI/receiver thread. False means resources still closing.
     * Android vendor codec release is not a hard-realtime operation; never free Surface on timeout.
     */
    public boolean awaitClosed(long timeoutMs) throws InterruptedException {
        if (Thread.currentThread() == thread) throw new IllegalStateException("Cannot join receiver thread");
        if (timeoutMs < 0 || timeoutMs > 5000) throw new IllegalArgumentException("0..5000ms required");
        return stopped.await(timeoutMs, TimeUnit.MILLISECONDS);
    }
    private void finish() {
        if (!lifecycle.finishOnWorker()) return;
        worker.removeCallbacksAndMessages(null);
        boolean failed = lifecycle.failedOnWorker();
        try {
            if (core != null) { PowStreamCore old = core; core = null; old.close(); }
        } catch (Exception e) { failed = true; }
        try { releaseCodec(); } catch (Exception e) { failed = true; }
        report(failed ? State.FAILED : State.CLOSED, failed ? "Receiver failed; resources retired" : "Receiver closed");
        thread.quitSafely(); stopped.countDown();
    }
}
