# JNI entry points (see src/main/cpp/wlbridge.c) are found by name.
-keepclasseswithmembernames class dev.omalauncher.wayland.Native { native <methods>; }

# The web shell's host API (shell/ShellBridge.kt) is called from JavaScript by name.
-keepclassmembers class dev.omalauncher.shell.ShellBridge { @android.webkit.JavascriptInterface <methods>; }
