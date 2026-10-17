package andro.marchy;

import android.view.Surface;

/**
 * JNI transport surface for the display consumer. All methods bind by name to
 * {@code Java_andro_marchy_Native_*} in {@code jni/native_consumer.c}.
 *
 * The shared library is loaded by {@link MainActivity}'s static initializer (a
 * single {@code .so} backs this class, MainActivity and CameraServices), so this
 * class only declares the natives — matching the existing CameraServices pattern.
 */
public final class Native {
    private Native() {}

    public static native void nativeConfigure(String socketPath, boolean useRoot,
                                              String helperPath, String bridgePath);
    public static native void nativeSetCompatibleMode(boolean enabled);
    public static native void nativeSetCompatibleFd(int fd);

    // With static natives there is no `thiz`, so native is handed the object it
    // calls back into (the Clipboard instance hosting nativeSetClipboardText /
    // nativeClipListening / nativeClipboardSync). It is stored as the global ref
    // used by the event thread's clipboard callbacks.
    public static native void nativeStart(Surface surface, Object callbackTarget);
    public static native void nativeStop();
    public static native void nativeSetCustomResolution(int width, int height);
    public static native void nativeSendTouch(int action, float x, float y, int pointerId);
    public static native void nativeSendTouchFrame();
    public static native void nativeSendKey(int action, int keycode);
    public static native void nativeSendMouseMotion(float x, float y, float dx, float dy);
    public static native void nativeSendMouseButton(int button, boolean pressed);
    public static native void nativeSendMouseScroll(int axis, float value);
    public static native void nativeSetRefreshRate(float hz);
    public static native void nativeSendClipboard(byte[] data);
    public static native void nativeSendTextInput(byte[] data);
    public static native void nativeSetMicEnabled(boolean enabled);
    public static native void nativeSetAudioLatency(int speakerMs, int micMs);
    public static native void nativeSetAudioKeepalive(boolean enabled);

    // PowOS: more surfaces - a PowOS window in its own Android task (PowosWindowActivity), on its own display daemon
    // (SessionService.windowDaemonSocket). Pixels and input only; the calls above stay the desktop's.
    // A handle is valid from nativeStartWindow (0 = failed) until nativeStopWindow.
    public static native long nativeStartWindow(Surface surface, String socketPath);
    public static native void nativeStopWindow(long handle);
    public static native void nativeSetWindowRefreshRate(long handle, float hz);
    public static native void nativeSendWindowTouch(long handle, int action, float x, float y, int pointerId);
    public static native void nativeSendWindowTouchFrame(long handle);
    public static native void nativeSendWindowKey(long handle, int action, int keycode);
}
