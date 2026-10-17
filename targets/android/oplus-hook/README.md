# PowOS hooks for OnePlus's launcher (LSPosed / Vector module)

With a third-party home - PowOS's launcher or desktop - OxygenOS 16 (OnePlus Open) loses things its own home has.
OnePlus's launcher (`com.android.launcher`) stays the gesture and recents provider; this module restores, inside it:

1. **Instant swipe to home.** OnePlus's `FallbackSwipeHandler.setHomeScaleAndAlpha` (older code than AOSP
   android16) never calls `setShow()` on the home task's leash, which the shell hid; the home animated in invisibly
   and the wallpaper showed ~1-2 s until the recents transition timed out. Hook adds AOSP's `setShow()`.
2. **Split screen / floating window gestures.** `OplusBaseSwipeUpHandler.onActivityInit` only takes the gesture's
   trigger panel from OnePlus's `Launcher`; with a third-party home it stays null. Hook inflates the same panel
   (`rapid_(multi_)trigger_panel_stub`) into `RecentsActivity`.
3. **Taskbar / "quick peek" dock.** `OverviewComponentObserver.updateOverviewTargets` sets
   `Settings.System enable_launcher_taskbar=0` whenever another app is home. Hook skips that (and its backup) when
   called from there; the user's own switch keeps working. After installing: turn the taskbar on once in Settings.

Found by reading the decompiled launcher against AOSP Launcher3 (android16-release); the system side (oplus-services)
doesn't check which app is home. All hooks are guarded: a launcher update that renames something only logs.
Confidence: 1 high, 2 verified 2026-10-17 on the Open (cover screen): the panel attaches to RecentsActivity's drag
layer, swipe-up-and-hold shows "Split View" / "Floating window", releasing on Floating window opens the app as a
floating window over PowOS's home (no RecentsActivity left behind), and Split View enters OnePlus's split; 3 high.

Build: `targets/android/build-oplus-hook.sh` (android-app-dev). Install: Zygisk on in Magisk, the Vector (LSPosed
fork, JingMatrix) Magisk module, this APK, then enable it in Vector with scope `com.android.launcher` and restart the
launcher (or reboot). Remove: disable the module in Vector.
