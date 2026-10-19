package android.view;

import android.graphics.Rect;
import android.os.Parcel;
import android.os.Parcelable;

/**
 * Stub of the framework's hidden android.view.RemoteAnimationTarget (AOSP frameworks/base, Apache-2.0): a window
 * handed to the recents animation (WM Shell's IRecentsAnimationRunner.onAnimationStart). Only the members PowOS reads.
 */
public class RemoteAnimationTarget implements Parcelable {
    public static final int MODE_OPENING = 0;
    public static final int MODE_CLOSING = 1;

    public int taskId;
    public int mode;
    public SurfaceControl leash;
    public Rect screenSpaceBounds;

    public static final Creator<RemoteAnimationTarget> CREATOR = null;

    private RemoteAnimationTarget() {
        throw new RuntimeException("Stub!");
    }

    @Override
    public int describeContents() {
        throw new RuntimeException("Stub!");
    }

    @Override
    public void writeToParcel(Parcel dest, int flags) {
        throw new RuntimeException("Stub!");
    }
}
