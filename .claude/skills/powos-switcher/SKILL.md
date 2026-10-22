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
- OxygenOS draws NO caption for freeform tasks: PowOS's own frames (system/WindowFrames.kt + WindowFrame.kt +
  FreeformTasks.kt), owned by the recents service (created in onInitialize, like the pet).
  - Per visible freeform task, two TYPE_APPLICATION_OVERLAY windows titled "PowOS window bar <id>" / "PowOS window
    grip <id>": a 40 dp glass bar above the task's top (icon, label, minimise, close) and a 36 dp grip disc on its
    lower-right corner. Glass = GlassBlur.wholeWindowOf(view, radius, corners) via WindowBlur(cornersDp) + 42% dark tint.
  - Tracking: a hand-made ITaskStackListener Binder (any transaction = "changed", debounced 80 ms) -> getRunningTasks
    (recents provider sees all) -> TaskInfo.configuration.windowConfiguration bounds/mode (reflected). A bar under a
    higher window's bounds is hidden (overlays sit above every app). None while keyguard, Switcher.open (its setter
    refreshes), or not AppWindows.floating.
  - Drag: the frame moves at once, IActivityTaskManager.resizeTask(id, rect, RESIZE_MODE_USER=1) coalesced on one
    worker thread. Close = Tasks.remove. Minimise = WindowContainerTransaction.reorder(TaskInfo.token, false) via
    WindowOrganizer.applyTransaction (assumed: lands under home; unverified until the check passes).
  - Dock: WindowFrames.running (Compose state) -> ShellBridge "windows.list"/"windows.changed"/"windows.restore";
    shell state.ts `windows`, home.tsx `windowed` dot (.dock .app.windowed[.minimised]) + DockWindows (unpinned
    apps with a window, after the pinned ones). ShellBridge.launch: an app with a window is restored, not relaunched.
- Check: `verify/float-windows.sh` (forces the inner screen with `cmd device_state state 3` - folded,
  apps open full screen by design, so a folded "not freeform" proves nothing; swipes the lock face, launches
  Calculator through home's bridge call apps.launch over CDP, asserts mode=freeform; then the frame: bar window, drag
  moves, grip resizes, minimise -> visible=false, launch restores, close; always `cmd device_state state reset`).
  Exits 1 + "FAIL:" on any step, 3 on a real touch. Queue it: `queue.sh add --close <task> float-windows.sh`.
- `powos` is NOT a page global (bridge.ts's module export; CDP `powos.x()` = ReferenceError). From CDP call the
  bridge as the page does: `PowosHost.postMessage(JSON.stringify([id, method, JSON.stringify(args)]))`, answer via
  `__powosHost.resolve(id, v)` (float-windows.sh `hcall` wraps it). Under queue.sh (LOCK_HELD=1) window_lock sets no
  EXIT trap, so WL_TRAP never runs: a check sets its own restore trap.
- JS side: `powos.floating` (list/restore/desktop, the phone only); `powos.windows` is the desktop taskbar's.
- One desktop per home page (shell ui/desktops.ts, started by app.tsx after load()): a window belongs to the page id
  it opened on (`placed`, store "home.windows" task id -> page id; -1 = AI page; a gone page -> the page on screen).
  Page change -> `floating.desktop(hideIds)` -> WindowFrames.desktop: the others minimised (reorder to bottom), no
  frame, `away` in windows.list; the rest raised bottom-most first; a no-op folded. restore/launch -> "windows.raised"
  -> home goes to its page. A bar let go within EDGE_DP (28) of a side -> WindowFrames.edges -> "windows.edge"
  {id, side} -> toEdge: window + home to the next page in one batch() (never hidden on the way); no page there: stays.
  Gate: desktops (gate.mjs desktopsCheck/Edge/Reloaded). Device: verify/float-desktops.sh (host events, no swipes).

## Device-check rules learned
- Captures only via tools/phone/shot.sh (picks the ON display: inner 4630946704981769859, cover 4630946316123810436).
- Home's foreground activity is com.powos.app/andro.marchy.HomeShell (alias of ShellActivity); HomeDesktop when the
  engine's desktop is home. `dumpsys device_state` mCommittedState OPENED/CLOSED says folded or not.
- shell/dev/gate.sh checks git HEAD (commit first), needs shell/node_modules; on a busy Mac READY_MS=40000.
