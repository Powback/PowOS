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
floating window over PowOS's home (no RecentsActivity left behind), and Split View enters OnePlus's split; 3 high;
4 verified (below).

5. **Dragging the app to Split View / Floating window on the big screen.** The targets showed, but the window stayed
   in the middle and nothing could be picked: the panel picks from the swipe's progress and a sideways offset that
   OnePlus takes from its recents view, which scrolls with the finger over its own home. A third-party home's
   switcher (RecentsActivity) is never scrolled by the gesture, so the offset stayed 0. Hooks: the finger's sideways
   travel (from the swipe handler's own motion events) is the panel's offset - set at the start of `updateProgress`,
   since OnePlus's per-frame reset goes through a setter ART inlines - and, while the finger is down, the window's
   x offset (`OplusRecentsViewImpl.getOffsetXForTSV`). Verified 2026-10-17 on the Open's inner screen (uinput finger
   + by hand): the window follows the finger, "Release to enter Split View" / Floating window highlight, and the drop
   splits / floats Chrome. When the window reaches a target OnePlus moves the other recents cards away by winding
   the recents view's enter animation back to 0 - off screen over its home, but full-screen-size (still visible) in
   RecentsActivity's grid: the switcher now fades out while a target is selected, back in if the finger leaves it.
   Picking the second app: OnePlus shows its home for that (tap an icon, it fills the other half);
   FallbackSwipeHandler starts the third-party home instead. The hook tags that home intent (powos.split_pick); as the
   PowOS desktop home the app writes run/split-pick, powos-android-tasks opens the app grid, and an Android app picked
   there starts on the phone's screen (powos-android-app) so it fills the split. As the launcher home (the cover) the
   launcher itself is the picker. Verified 2026-10-17 on the cover: Chrome on Split View, Gmail tapped, split.

4. **Revealing the taskbar in apps** (short swipe up). It stayed stashed for three reasons, all OnePlus assuming its
   own home: `FallbackActivityInterface` doesn't override `getTaskbarActivityContext()` (base returns null, so the
   swipe handler never reveals); `OplusTaskbarStashController.TransitionCallback.canResponseTransition()` requires
   OnePlus's `Launcher` activity with its transitions ended (never created with another home: always false); and
   `OplusTaskbarModelCallbacks.finishBindingItems()` defers putting icons into the taskbar until that activity exists
   (so it had 0 icons, which also fails the check). Hooks: the fallback returns the global taskbar context; no Launcher
   activity counts as "no launcher transition running" (OnePlus's other conditions kept); and the bound items are
   committed right away (`commitItemsToUI` doesn't use the Launcher). Verified 2026-10-17 on the Open (inner screen,
   uinput finger): swipe up a little in Settings and release, the taskbar (app drawer, recents, dock apps) slides up
   and the app stays (endTarget LAST_TASK). Earlier wrong lead, for the record: the consumer
   `TYPE_OTHER_ACTIVITY:TYPE_TASKBAR_STASH:TYPE_CURSOR_HOVER` is fine, that's the unstash consumer wrapping it.

6. **Split divider drag without the white flash** (SystemUI, scope `com.android.systemui`). While the divider is
   dragged, WM Shell's `SplitDecorManager` veils each resizing app in its TaskDescription background colour (white
   for most apps). Hook: `getResizingBackgroundColor(RunningTaskInfo)` returns PowOS's `#0f1115`, and the veil
   layers (`mBackgroundLeash`, `mGapBackgroundLeash`) are recoloured after `onResizing` /
   `drawNextVeilFrameForSwapAnimation` in case ART inlined the colour method. Signatures from the phone's
   SystemUI.apk (CPH2551_16.0.5.1301). Logcat: `PowOS-oplushook: split veil hooks installed in SystemUI (3 methods)`
   at SystemUI start, `split veil: dark #0f1115 (onResizing)` at the first drag. Needs SystemUI restarted with the
   scope on.

Build: `targets/android/build-oplus-hook.sh` (android-app-dev). Install: Zygisk on in Magisk, the Vector (LSPosed
fork, JingMatrix) Magisk module, this APK, then enable it in Vector with scopes `com.android.launcher` and `com.android.systemui` and restart
the launcher and SystemUI (or reboot). Remove: disable the module in Vector.
