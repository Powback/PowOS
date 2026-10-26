# JNI entry points (see src/main/cpp/wlbridge.c) are found by name.
-keepclasseswithmembernames class dev.omalauncher.wayland.Native { native <methods>; }

# The web shell's host API (shell/ShellBridge.kt) is called from JavaScript by name.
-keepclassmembers class dev.omalauncher.shell.ShellBridge { @android.webkit.JavascriptInterface <methods>; }

# The gesture input and the recents animation subclass and read hidden framework classes, compiled against stand-ins
# (hidden-stubs, compileOnly): R8 doesn't see them, so it mustn't warn about them, and the receiver's onInputEvent
# override (called by the framework) must keep its name.
-dontwarn android.view.InputEventReceiver
-dontwarn android.view.InputMonitor
-dontwarn android.view.RemoteAnimationTarget
-keep class dev.omalauncher.system.gesture.GestureMonitor$Receiver { *; }

# Run as root with app_process from this APK (system/OemCaption.kt): its main must keep its name.
-keep class dev.omalauncher.system.OemCaption { public static void main(java.lang.String[]); }
