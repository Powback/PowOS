package dev.omalauncher.system

import android.util.Log
import org.lsposed.hiddenapibypass.HiddenApiBypass

/**
 * The hidden framework calls the system slots make (docs/NATIVE-SYSTEM-UI.md): ActivityTaskManager's task calls (a
 * task's snapshot, removing one, starting one from recents), StatusBarManager's disable flags, the gesture input's
 * monitor and the recents transition's pieces. The system grants their
 * permissions to PowOS as the recents provider, but the calls themselves are @hide, and a privileged app isn't exempt
 * from the hidden API checks - only a platform-signed one is.
 *
 * HACK: lifts the hidden API checks for those classes only, with org.lsposed.hiddenapibypass (Apache-2.0, what
 * Lawnchair ships). Real fix: none for an app - the calls are the system UI's own, made from a platform-signed
 * process, which PowOS can't be without OnePlus's key.
 */
object HiddenApi {
    private const val TAG = "PowosHiddenApi"

    /** Class prefixes (JNI signatures) the slots call into. */
    private val classes =
        arrayOf(
            "Landroid/app/ActivityTaskManager",
            "Landroid/app/IActivityTaskManager",
            // The task stack listener (FreeformTasks.listen): ITaskStackListener.Stub.asInterface is hidden; without the
            // exemption the listener never registered (no task events for the running bar or the window frames).
            "Landroid/app/ITaskStackListener",
            // A task's windowing mode and bounds (FreeformTasks.list): Configuration.windowConfiguration and
            // WindowConfiguration are test-api, blocked for apps - logcat "windowConfiguration ... denied", every task
            // skipped, so windows.list was always empty (a floating Calculator on no home page, 2026-10-23).
            "Landroid/content/res/Configuration;",
            "Landroid/app/WindowConfiguration;",
            "Landroid/window/TaskSnapshot",
            // The floating windows (FreeformTasks): a task's bounds and mode (Configuration.windowConfiguration is
            // blocked: without it list() found no windows - no frames, no density, empty windows.list, 2026-10-23), its
            // token and the WindowContainerTransactions (bounds, density, reorder) applied through WindowOrganizer.
            "Landroid/content/res/Configuration;->windowConfiguration",
            "Landroid/app/WindowConfiguration",
            "Landroid/app/TaskInfo",
            "Landroid/window/WindowContainerTransaction",
            "Landroid/window/WindowContainerToken",
            "Landroid/window/WindowOrganizer",
            "Landroid/app/StatusBarManager",
            // The gesture input (system/gesture/GestureMonitor): the display's input monitor and its receiver.
            "Landroid/hardware/input/InputManager",
            "Landroid/view/InputMonitor",
            "Landroid/view/InputEventReceiver",
            // The recents transition (system/gesture/RecentsTransition): its windows, the transient launch, the app's
            // IApplicationThread.
            "Landroid/view/RemoteAnimationTarget",
            "Landroid/app/ActivityOptions",
            "Landroid/content/ContextWrapper",
            "Landroid/app/ActivityThread",
            // The window blurs (shell/WindowBlur, shell/GlassBlur): a window's surface (View.getViewRootImpl,
            // ViewRootImpl.getSurfaceControl / createBackgroundBlurDrawable) and its blur (Transaction.setBackgroundBlurRadius / setBlurRegions).
            "Landroid/view/View;",
            "Landroid/view/ViewRootImpl",
            "Landroid/view/SurfaceControl",
            // The framework's own blur-region encoding (GlassBlur.Codec): the OEM's region layout, never guessed.
            "Lcom/android/internal/graphics/drawable/BackgroundBlurDrawable",
            // The live wallpaper behind home (shell/WallpaperBackdrop): its surface mirrored, captured by the compositor.
            "Landroid/view/WindowManagerGlobal",
            "Landroid/view/IWindowManager",
            "Landroid/window/ScreenCapture",
        )

    @Volatile private var done = false

    /** Once per process, before the first hidden call; false if this Android refuses (the calls then fail alone). */
    fun allow(): Boolean {
        if (done) return true
        synchronized(this) {
            if (done) return true
            done = runCatching { HiddenApiBypass.addHiddenApiExemptions(*classes) }.onFailure { Log.w(TAG, "can't lift the hidden API checks", it) }.getOrDefault(false)
            return done
        }
    }
}
