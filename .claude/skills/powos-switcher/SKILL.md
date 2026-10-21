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

## Verify: record + frame-step (~/hg, Mac)
- Wait: ONE `tools/phone/idle.sh --wait 120 1800` (never loop adb). Screen must already be on.
- ~/hg/rec.js: CDP recorder injected into home's page (hooks __powosHost.emit for recents.*/system.*, logs every rAF
  where .screens' opacity/transform or the layer's classes change, rAF gaps, visibility). Install/read with
  ~/hg/cdp.ts through powos-vadb (adb forward tcp:9333 to webview_devtools_remote_<pid>).
- ~/hg/swipe.sh (run as root on the phone): touch-IRQ guard, home -> AI page, am start Settings, screenrecord on the
  cover display (--display-id 4630946316123810436; /sdcard is not writable for root's screenrecord: use
  /data/local/tmp + chmod 644), `input swipe 558 2475 558 1300 140`, screencaps, logcat -v epoch. ~/hg/run2.sh <tag>
  does it all and pulls to ~/hg/<tag>/.
- Frame-step: `ffmpeg -i hg.mp4 -vf scale=170:-1 -fps_mode passthrough k%02d.png`, then `tile=13x3` contact sheets;
  every frame between the swipe and the settle must show home's content.
- Logcat tags: PowosNavGesture (down/UP/outcome, lift, speed), PowosSwitcher (begin/show), PowosRecents
  ("gesture input on"), PowosRecentsWatchdog, PowosWallpaper (picture captures - count them), PowosGlassBlur.
