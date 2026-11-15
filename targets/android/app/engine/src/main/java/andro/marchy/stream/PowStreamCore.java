package andro.marchy.stream;

import java.nio.ByteBuffer;

/** Single-owner ABI wrapper. Only the receiver worker may call these methods. */
final class PowStreamCore implements AutoCloseable {
    static { System.loadLibrary("powstream_jni"); }
    static final int OK = 0, EMPTY = 1, SMALL = -2, CLOSED = -4;
    private long handle;
    private final Thread owner = Thread.currentThread();
    PowStreamCore(String endpoint, String token, byte[] pin) {
        handle = openNative(endpoint, token, pin);
        if (handle == 0) throw new IllegalStateException("PowStream bootstrap rejected locally");
    }
    private void check() {
        if (Thread.currentThread() != owner) throw new IllegalStateException("Wrong receiver thread");
        if (handle == 0) throw new IllegalStateException("Receiver closed");
    }
    int poll(ByteBuffer target, long[] meta) { check(); return pollNative(handle, target, meta); }
    int state() { check(); return stateNative(handle); }
    @Override public void close() {
        if (Thread.currentThread() != owner) throw new IllegalStateException("Wrong receiver thread");
        long old = handle;
        handle = 0;
        if (old != 0 && closeNative(old) != OK) throw new IllegalStateException("Native close failed");
    }
    private static native long openNative(String endpoint, String token, byte[] pin);
    private static native int pollNative(long handle, ByteBuffer target, long[] meta);
    private static native int stateNative(long handle);
    private static native int closeNative(long handle);
}
