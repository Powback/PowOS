# PowOS hooks for OnePlus's launcher (LSPosed / Vector module)

With a third-party home - PowOS's launcher or desktop - OxygenOS 16 (OnePlus Open) loses things its own home has.
OnePlus's launcher (`com.android.launcher`) stays the gesture and recents provider; this module restores, inside it:

1. **Instant swipe to home.** OnePlus's `FallbackSwipeHandler.setHomeScaleAndAlpha` (older code than AOSP
   android16) never calls `setShow()` on the home task's leash, which the shell hid; the home animated in invisibly
   and the wallpaper showed ~1-2 s until the recents transition timed out. Hook adds AOSP's `setShow()`.
2. **Split screen / floating window gestures.** `OplusBaseSwipeUpHandler.onActivityInit` only takes the gesture's
   trigger panel from OnePlus's `Launcher`; with a third-party home it stays null. Hook inflates the same panel
   (`rapid_(multi_)trigger_panel_stub`) into `RecentsActivity`.
3. **Taskbar.** `OverviewComponentObserver.updateOverviewTargets` sets `Settings.System enable_launcher_taskbar=0`
   whenever another app is home. Hook drops exactly that write, at `Settings.System.put*` (caller seen in the stack
   trace): a hook on `updateOverviewTargets` itself never ran, ART inlines that private method. The user's own switch
   keeps working. After installing: turn the taskbar on once in Settings. Verified 2026-10-17: the setting survives
   a launcher restart; the launcher's dump shows the (transient) taskbar present.

Found by reading the decompiled launcher against AOSP Launcher3 (android16-release); the system side (oplus-services)
doesn't check which app is home. All hooks are guarded: a launcher update that renames something only logs.
Confidence: 1 high, 2 verified 2026-10-17 on the Open (cover screen): the panel attaches to RecentsActivity's drag
layer, swipe-up-and-hold shows "Split View" / "Floating window", releasing on Floating window opens the app as a
floating window over PowOS's home (no RecentsActivity left behind), and Split View enters OnePlus's split; 3 high.

**Known gap: revealing the transient taskbar in apps (checked 2026-10-17).** With a third-party home the taskbar is
enabled and present (3. above) but a short swipe up in an app doesn't reveal it; it stays stashed. Tested on the phone
with a uinput touchscreen (real finger timing). Findings for the next attempt: AbsSwipeUpHandler only reveals it when
`activityInterface.getTaskbarActivityContext()` is non-null, and FallbackActivityInterface doesn't override it (base
returns null); but returning `TaskbarUtils.getTaskbarActivityContext()` there (plus re-setting the handler's
mTaskbarCanResponseTouch/thresholds) was not enough: OplusBaseTouchInteractionService (~l.1050) gives the gesture a
TaskbarStashInputConsumer, not the TaskbarUnstashInputConsumer whose detector the handler needs (dumpsys shows
TYPE_OTHER_ACTIVITY:TYPE_TASKBAR_STASH). Why: the gesture's consumer reaches that check already wrapped (dumpsys: TYPE_OTHER_ACTIVITY:TYPE_TASKBAR_STASH:TYPE_CURSOR_HOVER), so `delegate instanceof OtherActivityInputConsumer` fails and no unstash consumer is made - whichever app is home. The stash consumer's own reveal, a long press on the handle, is taken by Circle to Search (tried: it opens). Fixing it means re-routing every navigation gesture in OnePlus's TouchInteractionService; not done speculatively (a mistake breaks home/back/recents phone-wide).

Build: `targets/android/build-oplus-hook.sh` (android-app-dev). Install: Zygisk on in Magisk, the Vector (LSPosed
fork, JingMatrix) Magisk module, this APK, then enable it in Vector with scope `com.android.launcher` and restart the
launcher (or reboot). Remove: disable the module in Vector.
