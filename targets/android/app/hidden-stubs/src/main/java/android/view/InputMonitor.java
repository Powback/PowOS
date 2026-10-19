package android.view;

/**
 * Stub of the framework's hidden android.view.InputMonitor (AOSP frameworks/base, Apache-2.0): what
 * InputManager.monitorGestureInput returns - a channel that sees every touch on a display and can take a gesture away
 * from the windows under it ({@link #pilferPointers}).
 */
public final class InputMonitor {
    private InputMonitor() {
        throw new RuntimeException("Stub!");
    }

    public InputChannel getInputChannel() {
        throw new RuntimeException("Stub!");
    }

    public void pilferPointers() {
        throw new RuntimeException("Stub!");
    }

    public void dispose() {
        throw new RuntimeException("Stub!");
    }
}
