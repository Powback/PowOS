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
- From an app: page kept (home launched with Switcher.EXTRA_RECENTS: no "system.home"). Home while home shows:
  "system.home" -> state.ts goHome() -> page 0 (closes drawer/menus too).

## Pitfalls already paid for
- Vanish bug: a transform on `.screens` (then static, 0 px) made it the containing block of its fixed children ->
  .home 0 px tall for the swipe (bare wallpaper). `.screens` is `position:absolute; inset:0`: any transformed ancestor
  of fixed UI needs a real box.
- Over an app home stays fully opaque during the drag (only recedes by scale); fades under the cards only in landed().
- Reopen ghost (2026-10-23): a card opened grows (`opening`, .recents-expand: screen-sized, object-fit cover) and the
  layer stays till "recents.hide", which only comes from home STOPPING. A floating window leaves home in sight: the
  grown card stayed behind the window as a zoomed full-screen copy. Now tasks() sends `floats` (unfolded) and
  `window` (a freeform task's bounds, CSS px): the card grows to the window's box; a full-screen task that will float
  opens straight out of its card (no grow); ShellBridge.openTask calls Switcher.hide() 150 ms after a floating open.
- A visible floating window is never backgrounded, so the system's task snapshot of it is stale (full-screen time, old
  size): ShellHost /_task/<id> takes it fresh (Tasks.capture) for a visible freeform task; its ?v= carries WxH.
- Wallpaper loop: announcing a new picture must not re-look at the wallpaper (info(look=false)): a video loops.

## Verify: record + frame-step (tools/phone/record/)
- Queue `tools/phone/record/run.sh <tag>` (queue.sh; pulls to ~/powos-rec/<tag>/): rec.js (CDP recorder in home's page:
  recents.*/system.* emits, every rAF where .screens/the layer change, rAF gaps) + swipe.sh as root (touch-IRQ guard,
  Settings, screenrecord in /data/local/tmp on the ON display, `input swipe 558 2475 558 1300 140`, logcat -v epoch).
- Frame-step: `ffmpeg -i hg.mp4 -vf scale=170:-1 -fps_mode passthrough k%02d.png` + `tile=13x3` sheets; every frame
  between the swipe and the settle must show home's content.
- Logcat: PowosNavGesture, PowosSwitcher, PowosRecents, PowosRecentsWatchdog, PowosWallpaper, PowosFreeform.

## Floating app windows on the unfolded home (system/AppWindows.kt)
- The unfolded Android home is the PowOS desktop; apps float over it (Plasma-hosted powos-shell parked).
- Mechanism: Android's freeform (mode 5); OxygenOS 16 coerces it to full screen unless global `enable_freeform_support`
  = 1 (set 2026-10-22, no reboot; undo `settings delete global ...`). `am start --windowingMode 5 -n <cmp>` floats.
- In the app: AppWindows.options(ctx, base)/bundle() -> Tasks.freeformOptions(bounds, base) (setLaunchBounds + hidden
  setLaunchWindowingMode) when smallestScreenWidthDp >= 600 and the setting is on; folded: base (full screen). EVERY
  launch path uses it: AndroidApps.open (dock/drawer/search), ShellBridge.openTask (recents: taskOptions, an existing
  window keeps its bounds), Notifications.startOptions, AppWidgets click, TileHost, QuickSettings, WidgetServices
  url/androidApp, Media open, ShellNative/OpenBridge links, ShellScreens.start, PowosAiActivity.open, and the Linux
  side's `android-request open <pkg>` (engine AndroidRequests.openOptions, set by Runtime). New launch site: use it.
- Size: 60% x 70% of the screen in AppWindows.area (under status + title bar, above home's bottom bar, whose top the
  page reports: desktops.ts tellBar -> "windows.area" -> AppWindows.barTop), cascaded 40 dp.
- Density (the user: "content zoom too much"): a 1134 px window at 442 dpi is 410 dp = the app's PHONE layout, far
  bigger than the same app full screen (821 dp, tablet layout). Fix = a real per-task density:
  WindowContainerTransaction.setDensityDpi(task token, dpi) via WindowOrganizer.applyTransaction (FreeformTasks.density;
  what AOSP desktop mode does). AppWindows.windowDpi = 0.8 x screen dpi (354): 60% width = 615 dp, tablet layout.
  WindowFrames.dense gives 0 (= screen's) back to a task that stops being a window (folded, made full screen).
  Set on the first refresh after a launch it does NOT stick (2026-10-23, APK 29878432: call succeeds, task stays 442
  dpi, 492 dp; the same WCT from root 3 s later -> 354 dpi), so dense reads the task's configuration.densityDpi back
  (FreeformTasks.Window.dpi) and sets it again every 500 ms until it shows (8 tries; logcat PowosWindowFrames "task N
  at X dpi: set Y"). Root probe: ~/.cache/powos-fwdpi/src/Dpi.java (d8'd, `CLASSPATH=.. app_process /system/bin Dpi
  <task> [dpi]`); IActivityTaskManager.getTasks has the tokens. WOC CONTROLLABLE_CONFIGS here = 0x20003C00 (has density).
  Not used: `wm density` (per display); OnePlus flexible/zoom window scale (a scaled surface; its calls refuse
  non-launcher callers anyway); `am compat` downscale (per package, not per window; not tried).
- Dock taps are a taskbar's (desktops.ts dockTap, AppCell onTap): the app of the window in front (first non-minimised,
  non-away in windows.list) -> "windows.minimise"; else apps.launch (restores a window, ShellBridge.launch, or launches).
  Linux/KWin windows: HOOK in dockTap until the Plasma backend lists them to the web launcher. Gate: dockTapCheck.
- Title bar: minimise, maximise (WindowFrames.maximise: whole AppWindows.area, again = the bounds before; moved by hand
  = ordinary again), close. Tap offsets from the right: close 21 dp, maximise 55, minimise 89.
- Dead ends (launching, measured): OnePlus FlexibleWindowManager.startAnyActivity/calculateFlexibleWindowBounds (empty
  bounds), OplusZoomWindowManager.startZoomWindow: full screen unless OnePlus's launcher asks; startFlexibleWindowFor-
  RecentTasks = a split "pocket". Settings is on OnePlus's no-floating list (test with Calculator). Probe framework
  calls as root: d8'd class, `CLASSPATH=x.dex app_process /system/bin <Class>` (dexdump oplus-framework.jar first).
- OxygenOS draws NO caption for freeform tasks: PowOS's own frames (system/WindowFrames.kt + WindowFrame.kt +
  FreeformTasks.kt), owned by the recents service (created in onInitialize, like the pet).
  - Per visible freeform task, overlays "PowOS window bar <id>" (40 dp glass bar above the task) / "PowOS window grip
    <id>" (36 dp disc, lower right). Glass = WindowBlur(cornersDp) + 42% dark tint.
  - Tracking: a hand-made ITaskStackListener Binder (any transaction = "changed", debounced 80 ms) -> getRunningTasks
    (recents provider sees all) -> TaskInfo.configuration.windowConfiguration bounds/mode (reflected). A bar under a
    higher window's bounds is hidden (overlays sit above every app). None while keyguard, Switcher.open (its setter
    refreshes), or not AppWindows.floating.
  - Drag: the frame moves at once, IActivityTaskManager.resizeTask(id, rect, RESIZE_MODE_USER=1) coalesced on one
    worker thread. Close = Tasks.remove. Minimise = WindowContainerTransaction.reorder(TaskInfo.token, false) via
    WindowOrganizer.applyTransaction (FreeformTasks.transact, shared with density).
  - Dock: WindowFrames.running (Compose state) -> ShellBridge "windows.list"/"windows.changed"/"windows.restore";
    shell state.ts `windows`, home.tsx `windowed` dot (.dock .app.windowed[.minimised]) + DockWindows (unpinned
    apps with a window, after the pinned ones). ShellBridge.launch: an app with a window is restored, not relaunched.
- Check: `verify/float-windows.sh` (forces the inner screen with `cmd device_state state 3` - folded, apps open full
  screen by design; launches Calculator via home's apps.launch over CDP: freeform, task dpi 70-95% of the screen's and
  >= 600 dp, 60x70% above the bar (screencap onto the board task); bar, drag, grip, maximise/back, minimise, restore,
  dock icon tap minimise/restore, close, recents tasks.open of a full-screen task floats; always `state reset`).
  Exits 1 + "FAIL:" on any step, 3 on a real touch. Queue it: `queue.sh add --close <task> float-windows.sh`.
- Linux windows (KWin's, pkgs/kwin 0013/0018 -> engine WindowTasks "open" -> PowosWindowActivity): the hooks
  (AndroidRequests.openOptions, WindowTasks.raiseTask, WindowTasks.setFloating) are set in App.onCreate - set lazily
  by Runtime, KWin's "caps" could come first and "export-new" was never sent. "open" for an id that has an activity
  raises its task (Tasks.open + AppWindows.taskOptions: a full-screen one floats), never a second activity; logcat
  WindowTasks "open N (app): floating | full screen | its task T back".
- Child windows (Dolphin -> Gwenview, a 2nd window) float only with KWin 6.7.5-3.22+ (0018 "export-new") RUNNING:
  `pacman -Q kwin` on the phone was 3.21 on 2026-10-23 (no caps, no export-new; each image Dolphin opened went to the
  hidden desktop: six Gwenview windows). 0018 on, existing desktop windows are all exported at once. KDE opens PNGs in
  Gwenview through KIO (`kioclient exec`) even though `xdg-mime query default image/png` says Brave.
- Check: verify/linux-float.sh (installs the newest built kwin pkg + a fresh session if older, Dolphin via
  apps.launch, an image via kioclient exec = one Gwenview task, freeform; close closes it). Queue with --close.
- `powos` is NOT a page global: from CDP post `PowosHost.postMessage(JSON.stringify([id, method, JSON.stringify(args)]))`,
  answer via `__powosHost.resolve(id, v)` (float-windows.sh `hcall`). Under queue.sh a check sets its own EXIT trap.
- JS side: `powos.floating` (list/restore/desktop/minimise/maximise/area, phone only); `powos.windows` = desktop taskbar.
- Unfolded, a home page is a wide page (hosts/wide.ts: one per pair of host pages; the user's layout = one page), so
  page ids in "home.windows" are wide page ids. Wide, state.ts pages = the tile pages + the pages live windows are on
  (desktopPages, set by desktops.ts) + always ONE empty desktop after them (dynamic workspaces; 2026-10-23 the wide
  home had page 1 + the library only, and the library counted as page 1: nothing hid). The app library is a desktop of
  its own (id -2). Gate: desktopsWide.
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
