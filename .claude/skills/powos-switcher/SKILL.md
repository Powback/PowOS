---
name: powos-switcher
description: Use when working on PowOS's swipe-home / swipe-up-and-hold switcher, the recents transition, home's switcher layer (recents.tsx), home's page after going home, or the live-wallpaper picture capture - the event flow, known pitfalls, and the record-and-frame-step verification workflow.
---

## How a swipe up works (gesture -> page)
- NavGesture.kt (input monitor, PowOS is the recents provider) asks WM Shell's recents transition on the finger's DOWN
  (RecentsTransition.start), so the app's window follows from the first pixel. RecentsWatchdog.kt keeps SystemUI
  bound to the recents service (no binding = no gesture input at all).
- Over an app: Switcher.begin(task) -> page "recents.begin" {from, tasks}; every display frame RecentsTransition.apply
  -> Switcher.drag -> "recents.drag" {progress, x, y, home} (emitNow, a raw string). progress = window toward its card,
  home = how far into the home zone. Release: End.HOME settles progress->1, home->1 (window shrinks, alpha 0), then
  Switcher.end("home") -> "recents.end" {to:"home"} -> page collapse(false) (instant). Held: End.SWITCHER ->
  Switcher.settle (snapshot) -> "recents.end" {to:"switcher", snapshot} -> page landed() -> powos.recents.ready.
- Over home (no app window): NavGesture drives the layer itself (homeDrag/endOverHome, HOME_TRAVEL 0.4, 220 ms).
- Other events: recents.show/hide/tasks/update, switcher.toggle. Home's stop emits recents.tasks (cards laid out ahead).
- recents.tsx frame(p, x, y, home): CSS vars on the layer + an inline transform/opacity on `.screens` (home + AI page).

## Page after going home (manager decision 2026-10-21, launcher standard)
- From an app: page kept. The transition launches home with Switcher.EXTRA_RECENTS, so ShellActivity.onNewIntent
  sends no "system.home". A home gesture/press while home already shows: home intent -> "system.home" ->
  state.ts goHome() -> page 0 (closes drawer/menus too). 35fce41's "going home moves home to its first page" = Home on home.

## Pitfalls already paid for
- THE vanish bug (fixed 7424dca): `.screens` had no box (static, 0 px tall). Scaling it makes it the containing block
  of its position:fixed children, so .home/.ai-screen (top:0;bottom:0) became 0 px tall for the whole swipe and popped
  back when the transform was cleared. Symptom: bare wallpaper + "Clear all" + pet for 290-430 ms. `.screens` is now
  `position:absolute; inset:0`. Any transform on an ancestor of fixed UI needs a real box.
- Wrong guess (366aa8e, reverted): "Chromium drops opacity-0 tiles" - an opacity floor changed nothing. Measure first:
  the page's DOM state said visible while the screen showed nothing -> layout, not paint.
- Over an app home stays fully opaque during the drag (only recedes by scale); fades under the cards only in landed().
- Wallpaper loop (760cf6b): an announcement of a new picture must not re-look at the wallpaper (info(look=false));
  a live video wallpaper differs every frame and looped captures several times a second.

## Verify: record + frame-step (tools/phone/record/)
- Wait: ONE `AWAKE_ONLY=1 tools/phone/idle.sh --wait 120 1800 && tools/phone/record/run.sh <tag>` (run.sh doesn't
  wait itself; never loop adb; AWAKE_ONLY waits through doze and never wakes the screen).
- rec.js: CDP recorder injected into home's page (hooks __powosHost.emit for recents.*/system.*, logs every rAF
  where .screens' opacity/transform or the layer's classes change, rAF gaps, visibility). Install/read with
  cdp.ts through powos-vadb (adb forward tcp:9333 to webview_devtools_remote_<pid>).
- swipe.sh (run as root on the phone): touch-IRQ guard, home -> AI page, am start Settings, screenrecord on the
  cover display (--display-id 4630946316123810436; /sdcard is not writable for root's screenrecord: use
  /data/local/tmp + chmod 644), `input swipe 558 2475 558 1300 140`, screencaps, logcat -v epoch. `tools/phone/record/run.sh <tag>`
  does it all and pulls to ~/powos-rec/<tag>/ ($OUT).
- Frame-step: `ffmpeg -i hg.mp4 -vf scale=170:-1 -fps_mode passthrough k%02d.png`, then `tile=13x3` contact sheets;
  every frame between the swipe and the settle must show home's content.
- Logcat tags: PowosNavGesture (down/UP/outcome, lift, speed), PowosSwitcher (begin/show), PowosRecents
  ("gesture input on"), PowosRecentsWatchdog, PowosWallpaper (picture captures - count them), PowosGlassBlur.

## Floating app windows on the unfolded home (system/AppWindows.kt)
- The unfolded Android home, unchanged, is the PowOS desktop; apps float over it. The Plasma-hosted powos-shell is
  parked (`powos-desktop-shell` disabled, `taskbar off`; its windows.close/android flags and panel code stay).
- Mechanism: Android's own freeform (windowing mode 5). OxygenOS 16 coerces it to full screen unless the global
  developer setting `enable_freeform_support` = 1 (set on the phone 2026-10-22; no reboot needed; undo:
  `settings delete global enable_freeform_support`). Then `am start --windowingMode 5 -n <cmp>` gives
  `mode=freeform` and `am task resize <id> l t r b` moves/resizes it.
- In the app: AppWindows.launchOptions() -> Tasks.freeformOptions(bounds) (setLaunchBounds + hidden
  setLaunchWindowingMode, reflected: HACK row Tasks.kt) on AndroidAppCatalog.open's startMainActivity, only when
  smallestScreenWidthDp >= 600 and the setting is on; cascaded, half width x two thirds height. Folded: full screen.
- Dead ends (measured): OnePlus FlexibleWindowManager.startAnyActivity / calculateFlexibleWindowBounds (bounds come
  back empty) and OplusZoomWindowManager.startZoomWindow open apps full screen when called from outside OnePlus's
  launcher; startFlexibleWindowForRecentTasks makes a split "pocket", not a window; Settings is on OnePlus's
  no-floating list (pick Calculator for tests). Probe OEM framework calls with a d8'd class via
  `CLASSPATH=x.dex app_process /system/bin <Class>` as root, after dexdump of oplus-framework.jar.
- OxygenOS draws NO caption/title bar for freeform tasks: move/resize/minimise need our own (next slice), as do the
  running windows in the dock.
- Check: `tools/phone/verify/float-windows.sh` (forces the inner screen with `cmd device_state state 3`, swipes the
  lock face, launches Calculator through home's powos.apps.launch over CDP, asserts mode=freeform, shot.sh, then
  `cmd device_state state reset`). Queue it: `tools/phone/verify/queue.sh add <task> float-windows.sh`.

## Device-check rules learned
- One `AWAKE_ONLY=1 tools/phone/idle.sh --wait 120 MAX` call to wait (never loop adb); the verify lock
  (~/.cache/powos-verify.lock, verify/window-lock.sh) only after the wait; captures only via tools/phone/shot.sh
  (picks the ON display: the inner screen id 4630946704981769859, the cover 4630946316123810436).
- Home's foreground activity is com.powos.app/andro.marchy.HomeShell (alias of ShellActivity); HomeDesktop when the
  engine's desktop is home. `dumpsys device_state` mCommittedState OPENED/CLOSED says folded or not.
- shell/dev/gate.sh needs shell/node_modules (symlink it from a worktree that has one) or tsc is skipped.
