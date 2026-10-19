package android.view;

import android.os.Looper;

/**
 * Stub of the framework's hidden android.view.InputEventReceiver (AOSP frameworks/base, Apache-2.0): reads the input
 * events of an {@link InputChannel} on a looper. Only the members PowOS uses; the phone's own class runs.
 */
public abstract class InputEventReceiver {
    public InputEventReceiver(InputChannel inputChannel, Looper looper) {
        throw new RuntimeException("Stub!");
    }

    /** One event; the receiver must call {@link #finishInputEvent} for it. */
    public void onInputEvent(InputEvent event) {
        throw new RuntimeException("Stub!");
    }

    public final void finishInputEvent(InputEvent event, boolean handled) {
        throw new RuntimeException("Stub!");
    }

    public void dispose() {
        throw new RuntimeException("Stub!");
    }
}
