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
- Launches PowOS doesn't make (another app, `am start`, a system notification) open full screen: WindowFrames.adopt
  makes any visible full-screen standard task (not PowOS's own) a window (FreeformTasks.toWindow: WCT setWindowingMode
  + setBounds), once per task per unfold (adopted, cleared folded); logcat "was full screen: now a window".
  Checks: verify/launch-paths.sh (home launch, plain am start, recents after a fold), dock-taskbar.sh (focus /
  minimise / restore by real dock taps), float-touch.sh (touches inside a window stay the app's).
- No title bars at all + logcat "permission denied for window type 2038": the SYSTEM_ALERT_WINDOW app op was reset
  (`appops get com.powos.app SYSTEM_ALERT_WINDOW` = default). WindowFrames.overlayGrant re-grants it through root
  (start + a refused frame, once a minute). Frames stay type 2038 (under the shade); 2017 would cover the shade.
  ROOT CAUSE (2026-10-23): the manifest had dropped `uses-permission SYSTEM_ALERT_WINDOW` (fold veil removal, 10-16):
  then `appops set ... allow` returns 0 and the op STAYS default. Declared again in app/AndroidManifest.xml.
- linux-float.sh's image open: KDE picks Gwenview (InitialPreference 8) though xdg-mime says Brave; launch kioclient
  with `setsid -f` from user.sh - a nohup'd one died with the session (Gwenview never started).
- Wide layout (hosts/wide.ts "home.wide"): an item missing from one host read keeps its wide cell (pruning it re-placed
  WireGuard at the first free cell, the middle column). wide-home.sh asserts the cells survive fold + unfold and don't
  overlap; a cell away from its side-by-side spot is the user's move (a note, never "fixed").
- Size: 60% x 70% of the screen in AppWindows.area (under status + title bar, above home's bottom bar, whose top the
  page reports: desktops.ts tellBar -> "windows.area" -> AppWindows.barTop), cascaded 40 dp.
- Density (the user: "content zoom too much"): a 1134 px window at 442 dpi is 410 dp = the app's PHONE layout, far
  bigger than the same app full screen (821 dp, tablet layout). Fix = a real per-task density:
  WindowContainerTransaction.setDensityDpi(task token, dpi) via WindowOrganizer.applyTransaction (FreeformTasks.density;
  what AOSP desktop mode does). AppWindows.windowDpi = 0.8 x screen dpi (354): 60% width = 615 dp, tablet layout.
  WindowFrames.dense gives 0 (= screen's) back to a task that stops being a window (folded, made full screen).
  REAL CAUSE (2026-10-23, APK 29878604): FreeformTasks.list() found NO windows in the app - Configuration.
  windowConfiguration is hidden-API `blocked,test-api` and wasn't in HiddenApi's exemptions (logcat: "hiddenapi:
  Accessing hidden field ...Configuration;->windowConfiguration ... from FreeformTasks ... denied"), so dense() never
  ran (also no frames, empty windows.list). Now exempt (+ WindowConfiguration, TaskInfo, WindowContainerTransaction/
  Token, WindowOrganizer); a failed read logs "can't read task N's window". New hidden call: check logcat for
  `hiddenapi.*denied` from your class first. Linux windows (PowOS's own package) get no density (pixel-for-pixel).
  Linux side: KWin output scale 2.25 since 2026-10-23 (session/powos-output-scale, once: physical dpi x 0.8 / 160 =
  Android's window px/dp; then the user's). X11 follows (Xwayland Scale, Xft.dpi 216, GTK X11 scale 2 x 108 dpi); a
  Wayland Qt app's QScreen dpr says 3 (wl_output's integer), its windows get 2.25. Apps from the drawer run in
  powos-run.sh's env: it must carry XDG_CURRENT_DESKTOP=KDE etc. (from plasmashell), else Qt = Fusion, light, Sans 9.
  Check: verify/linux-look.sh (FACTS_ONLY=1 = read-only part, fine outside the queue).
  Earlier reading, likely wrong (the in-app call never ran): set on the first refresh after a launch it does NOT stick (2026-10-23, APK 29878432: call succeeds, task stays 442
  dpi, 492 dp; the same WCT from root 3 s later -> 354 dpi), so dense reads the task's configuration.densityDpi back
  (FreeformTasks.Window.dpi) and sets it again every 500 ms until it shows (8 tries; logcat PowosWindowFrames "task N
  at X dpi: set Y"). Root probe: ~/.cache/powos-fwdpi/src/Dpi.java (d8'd, `CLASSPATH=.. app_process /system/bin Dpi
  <task> [dpi]`); IActivityTaskManager.getTasks has the tokens. WOC CONTROLLABLE_CONFIGS here = 0x20003C00 (has density).
  Not used: `wm density` (per display); OnePlus flexible/zoom window scale (a scaled surface; its calls refuse
  non-launcher callers anyway); `am compat` downscale (per package, not per window; not tried).
- Dock taps are a taskbar's (desktops.ts dockTap, AppCell onTap): the app of the window in front (first non-minimised,
  non-away in windows.list) -> "windows.minimise"; else apps.launch (restores a window, ShellBridge.launch, or launches).
  Linux windows: the same path by their `app` key (see Linux windows in the dock + switcher). Gate: dockTapCheck.
- Title bar: minimise, maximise (WindowFrames.maximise: whole AppWindows.area, again = the bounds before; moved by hand
  = ordinary again), close. Tap offsets from the right: close 21 dp, maximise 55, minimise 89.
- Dead ends (launching, measured): OnePlus FlexibleWindowManager.startAnyActivity/calculateFlexibleWindowBounds (empty
  bounds), OplusZoomWindowManager.startZoomWindow: full screen unless OnePlus's launcher asks; startFlexibleWindowFor-
  RecentTasks = a split "pocket". Settings is on OnePlus's no-floating list (test with Calculator). Probe framework
  calls as root: d8'd class, `CLASSPATH=x.dex app_process /system/bin <Class>` (dexdump oplus-framework.jar first).
- PowOS's own frames (system/WindowFrames.kt + WindowFrame.kt +
  FreeformTasks.kt), owned by the recents service (created in onInitialize, like the pet).
  - The SYSTEM caption (back/min/max/close strip inside the task, under PowOS's bar) is AOSP WM Shell's
    CaptionWindowDecoration in SystemUI: shown for EVERY freeform task, no launch flag turns it off (OnePlus's
    FlexibleCaptionView/"androidx.activity.HasCaption" is only for its own flexible-window scenarios). Off via
    system/OemCaption.kt: a root-registered fabricated overlay com.android.shell:PowosNoCaption sets SystemUI's
    dimen/freeform_decor_caption_height to 0 dp (`cmd overlay fabricate` can't write dimensions; app_process from the
    APK). Check `cmd overlay list com.android.systemui | grep Powos` = [x]; logcat PowosOemCaption.
    The same overlay zeroes WM Shell's drag-resize handles (freeform_resize_handle/_corner, edge_handle_in/outset,
    desktop_mode_corner_resize_large): its 15 dp top-edge band sat where PowOS's bar is. `cmd overlay dump <id>` lists them.
  - Per visible freeform task, overlays "PowOS window bar <id>" (26 dp window above the task: 18 dp frost bar under an
    8 dp clear touch strip; buttons span both) / "PowOS window grip <id>" (36 dp disc, lower right). Material = frost v2
    (system/Frost.kt: theme.css's --frost-* formula in Kotlin from Palette + the wallpaper's colour hints for the tone
    flip; blur 360 dp, veil, tint, sheen, 1 px lit edge). Keep Frost.kt in step with theme.css/shell.css frost; check it
    against the page: CDP computed backgroundImage of `.ai-screen .tile` (matched to 0.01, 2026-10-23). Each new frame
    logs `PowosWindowFrame task N bar <px> ... fill=#..` (what verify/window-chrome.sh reads).
  - Tracking: a hand-made ITaskStackListener Binder (any transaction = "changed", debounced 80 ms) -> getRunningTasks
    (recents provider sees all) -> TaskInfo.configuration.windowConfiguration bounds/mode (reflected). A bar under a
    higher window's bounds is hidden (overlays sit above every app). None while keyguard, Switcher.open (its setter
    refreshes), or not AppWindows.floating.
  - Drag: the frame moves at once (DragLayer, in-process per frame), the task through FreeformTasks.Live: per move
    WindowContainerTransaction.setBounds (+ setDragResizing on while resizing) via WindowOrganizer.applyTransaction,
    newest target only, one worker thread; the lift sets the last bounds + drag-resizing off. Through resizeTask the
    app's content only took the new size after the lift (likely a queued change transition per call). Logcat
    PowosWindowResize: live calls per drag, sizes on the way, call ms. Check: verify/window-chrome.sh (bar px, frost
    line, app window mid-drag between before and after). Close = Tasks.remove. Minimise = WindowContainerTransaction.reorder(TaskInfo.token, false) via
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
- Linux windows in the dock + switcher (slice 2, 2026-10-23): a Linux window's task is PowOS's own package
  (PowosWindowActivity), so the package names nothing. ShellBridge.linuxApp(id, pkg, caption): WindowTasks.appIdOfTask
  (KWin's desktopFileName from "open") -> LinuxApp.matches, else the caption's app name (KDE: "<doc> — <App>"; X11 apps
  without a desktop file name). windows.list gets `app` "l:<id>" from it (dock: DockWindows, dockTap -> restoreLinux);
  tasks() uses taskApp(t): a Linux window's card = its app's key + icon + caption, Plasma's desktop (MainActivity) =
  l:org.powos.plasma, never PowOS's own launcher entry (the generic card before). Dock recents leave out apps that have
  a window (else twice in the wide dock: DockWindows + DockTray). Closing a card (Tasks.remove) closes the KWin window
  only with 0018 running (export-new: "closed" -> closeWindow); older KWin puts it back on the hidden desktop.
  Check: verify/linux-dock.sh (dock cell once + icon, card key/icon/label, minimise + launch = focused, card close ->
  no dolphin process). Queue with --close.
  KWin closes a window on "closed" only with export-new 1 (else: back on the hidden desktop, the app keeps running);
  WindowTasks.closed re-sends export-new first. Logs: logcat WindowTasks "KWin caps:", "export-new N", "closed N";
  KWin's anland info lines in /run/powos-app/hyprland.log (QT_LOGGING_RULES in powos-rooted-session); the display
  daemon's control connects in the app's files/run/andromarchy.log.
- BLACK Linux windows (Kate, Dolphin, games; 2026-10-23): the consumer's daemon address was set only by MainActivity
  (the Plasma desktop) - after an app restart with no desktop opened, every window consumer tried the old socket FILE
  every 500 ms (logcat Andromarchy "connecting to .../display_daemon.sock ... connect_to_deamon failed"; the app's
  files/run/andromarchy.log shows "producer connected" but never "consumer connected" for the surface). Now
  MainActivity.configureConsumer(ctx), also called by PowosWindowActivity.onCreate. KWin logs "window task N live" only
  once a consumer connects: no such line = nothing reaches the window.
- X11 child windows (kwin 0019, 3.23): an Xwayland window is added before it has its wl_surface, so export-new skipped
  it for good. user.sh's environment has no WAYLAND_DISPLAY/XDG_SESSION_TYPE: a Qt app started there is an X11 window,
  unlike the session's; run as the session does with plasmashell's /proc/<pid>/environ (linux-float.sh `ses`).
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
  -> the window MOVES to the page on screen (2026-10-23; home no longer jumps to the window's page). A bar let go within EDGE_DP (28) of a side -> WindowFrames.edges -> "windows.edge"
  {id, side} -> toEdge: window + home to the next page in one batch() (never hidden on the way); no page there: stays.
  Gate: desktops (gate.mjs desktopsCheck/Edge/Reloaded). Device: verify/float-desktops.sh (real page swipes from an
  empty spot found over read-only CDP, same bounds back, reopen from page 2, home's process killed and back).
  A page turns at a quarter of .pages' width or a 0.45 css px/ms flick (gesture.ts settlePages): an injected swipe
  must start where the whole 35%-width swipe fits (freept $2 way, $3 length) - the leftmost empty spot, left of a
  window, clamped it to 207 px and home rightly stayed (float-desktops FAIL 05:25, 2026-10-23: the check's bug).
- Windows never got a page (the user, twice, 2026-10-23): desktops.ts only places what windows.list has, and that is
  WindowFrames.running, refreshed ONLY by the task stack listener. ITaskStackListener wasn't hidden-API exempt
  (b8fd224), so the listener never registered: the list stayed at the service's start-up read (Calculator visible,
  windows.list empty, nothing placed or hidden). Logcat PowosWindowFrames: "frames on, task listener on|MISSING" at
  start, and "windows (floating=.. keyguard=.., N task events): id:pkg@bounds ..." on every change - N stuck at 0 or a
  visible window absent = the listener again.

- A cold launch's window behind home (bf-return "launch-front", 2026-10-23): powos-open-task showed the FIRST matching
  window - a throwaway one of the launch (Steam's, ~3 s after the tap, closed 4 s later; "open 1 ()" in WindowTasks)
  - said "task" and exited; the game's real window (Unity, 55-75 s later) got no task (no WindowTasks "open" at all)
  and drew behind HomeShell. Now a launch's shown window must last SETTLE_S (8 s); one closing first is replaced by
  the next match, and a show KWin refuses is retried (an Xwayland window's surface comes late). stderr: "window N
  closed ... showing the next one". Check: verify/launch-front.sh (glxgears: window, full screen, throwaway first).
- Wide dock: pinned + DockWindows share the bar's left end; past 6 cells they ran on under the search pill (a
  Calculator window's icon under it, the dock-taskbar tap opened the drawer). The page sets --cells, slots shrink.

## Device-check rules learned
- Captures only via tools/phone/shot.sh (picks the ON display: inner 4630946704981769859, cover 4630946316123810436).
- Home's foreground activity is com.powos.app/andro.marchy.HomeShell (alias of ShellActivity); HomeDesktop when the
  engine's desktop is home. `dumpsys device_state` mCommittedState OPENED/CLOSED says folded or not.
- shell/dev/gate.sh checks git HEAD (commit first), needs shell/node_modules; on a busy Mac READY_MS=40000.
- windows.list empty (a floating Calculator on no page, 2026-10-23): FreeformTasks.list reads each task's
  Configuration.windowConfiguration - test-api, DENIED for apps (logcat "hiddenapi: ... windowConfiguration ... denied"
  under tag com.powos.app), so every task was skipped. HiddenApi.kt now exempts Configuration; + WindowConfiguration;.
  The running bar was NOT this (it reads getRunningTasks only). Device checks: capture logcat live from the launch
  (`timeout 40 logcat -T 1 -s ... &` on the phone): the 256 KiB main buffer rotates in seconds; and no single quotes
  inside a `su -c '...'` helper (float-desktops' missing.txt was empty from that).
- E2E round 2 probe (verify/desk-probe.sh, 2026-10-23): windows.list bounds never changed after a bar drag or grip
  resize (no task-stack event for a bounds change), so home's inWindow (907927a) refused page swipes inside where the
  window HAD been. Now WindowFrame's lift calls WindowFrames.changed() (refresh at 80 + 600 ms). Still open: with the
  caption overlay on, a sideways swipe in the app's top ~40 dp drags the TASK (system drag, not ours) and PowOS's bar
  and the list stay behind; and the bar's close left Calculator and Dolphin open (now logged: PowosWindowFrame
  "close task N: removed|NOT removed", PowosTasks "removeTask(N) said no").
- Fixed (desk-r3, 2026-10-23): a 0 dp SystemUI caption gives its input window an EMPTY crop = no crop, so its
  touchable region is the whole task and its root (the caption = DragDetector) drags the task from anywhere
  (`dumpsys input | grep "Caption of Task"`). OemCaption makes it 1 px; WindowFrame's bar window reaches 1 px into the
  task over it (OemCaption.CAPTION_PX). The 1 px captionBar inset is by design (float-windows checks its input row).
- A task's bounds set with WindowOrganizer.applyTransaction move it in WM only: WM Shell owns the leash, so the app's
  content AND its touches stayed at the old place until a minimise. Bar moves now go to WM once at the lift, as
  WindowOrganizer.startNewTransition(TRANSIT_CHANGE, wct) (FreeformTasks.Live.end); live resizes keep applyTransaction.
- Live content (system/TaskLeash.kt, 2026-10-23, NOT yet measured on the device): at a drag's first move PowOS
  registers a remote with WM Shell (IShellTransitions, bundle key = its descriptor "com.android.wm.shell.shared.
  IShellTransitions"; codes from sysui dex: registerRemote 2, unregisterRemote 3; filter: type CHANGE, a freeform task
  in mode CHANGE), starts a CHANGE transition that sets the first target bounds, and plays it itself: startAnimation
  (IRemoteTransition code 1; framework dex: merge 2, takeOver 3, consumed 4, abort 5) gives the task leash; each move
  sets its position + crop in a Transaction applied with the drag layer's draw (applyTransactionOnDraw); the lift
  finishes it (IRemoteTransitionFinishedCallback 1: WCT setBounds final [+ setDragResizing off], sct = final place).
  No leash in 600 ms = the old way (FreeformTasks.Live). Watchdog 15 s (an open transition holds all of WM Shell's
  others). Off: `settings put global powos_live_leash 0`. Logcat PowosTaskLeash ("leashes [..] after N ms",
  "finished (..) N live frames"); WM Shell logs "RemoteTransitionHandler: Found filter". Check: verify/window-live.sh
  (SurfaceFlinger HWC "Disp Frame" of the app's layer mid-drag/mid-resize, finger still down; --page = mid-swipe).
- Framework/SystemUI dex dumps for codes: ~/.cache/powos-caption/{framework,sysui}/*.dex (dexdump in powos-vadb:
  `docker cp` the dex in, /opt/android-sdk/build-tools/35.0.0/dexdump -d).
- The bar's close worked on 0f098c06 for Calculator, Dolphin, Gwenview (desk-probe r3 touch state: the bar window
  gets the DOWN, nobody pilfers). The r2a failures (APK 367633db) stayed unexplained.
- Touch evidence in a check: `input motionevent DOWN`, then `dumpsys input` TouchStatesByDisplay lists the windows
  the finger went to + pilferingPointerIds, then UP (desk-probe dtap/touched).

## Panels vs floating windows: who is above whom (measured 2026-10-23, read-only dumps; nothing shipped)
- WM + SurfaceFlinger order (inner screen): DefaultTaskDisplayArea (HomeShell task, then freeform tasks ABOVE it) <
  Leaf:3:12 (TYPE_APPLICATION_OVERLAY 2038: PowOS window bar/grip, DragLayer, OEM overlays) < status bar (Leaf 15) <
  SystemUI NotificationShade (17) < Leaf:18 (2017 STATUS_BAR_SUB_PANEL: PowOS shade + control center, quick tools,
  pull-up panel, pet) < VOICE_INTERACTION 2031 (assist / PowOS AI overlay). `dumpsys SurfaceFlinger` "Layer Hierarchy"
  shows it (Task=N under DefaultTaskDisplayArea#14, "PowOS shade" under Leaf:18:18).
- So the SHADE, control center and AI overlay are already above every window (their own windows), and their blur
  (WindowBlur on the shade window = a blur region over it) blurs what is under it, windows included. Still to measure
  on the device with a window open; if the user still sees a window over the shade, it is something else (a transition
  leash, TaskLeash's remote) - capture `dumpsys SurfaceFlinger` while it happens.
- The DRAWER (+ its search, chat), EDIT MODE and home's menus live in HomeShell's own WebView window
  (com.powos.app/andro.marchy.HomeShell, #631 = ViewRootImpl.getSurfaceControl, BLAST child under it), which is under
  every freeform task: that is why windows cover them. Its frost blur is a blur region on that window (GlassBlur), so
  it only blurs what is under HOME (the wallpaper), never the windows.
- Page signal for "a home panel is open": gesture.ts `drawerOpen` (search and chat are drawer states) || state.ts
  `editing`. pull.tsx (the pull-up panel over apps, its own 2017 window) has drawerOpen too: send only from home.
- Fix chosen (not built; window features frozen): while a home panel is open, put HOME's window surface above the
  tasks instead of moving the tasks (no task leash needed, windows stay live and resumed, WM state untouched):
  `Transaction.setRelativeLayer(home#631, anchor, -1)` with `anchor` = a 1x1 transparent, not-touchable 2038 window
  of PowOS's own (in Leaf:3:12, above the task area, below the status bar/shade). Then home's frost blur region blurs
  the windows like the wallpaper, and touch follows (input order is built from SF's layer tree), the IME follows
  (ImeContainer is relative to #631, z=1). Restore: `setLayer(home#631, 0)` (WM's z for the main window; WM resends
  a layer only when its own value changes, so it won't fight). Window bars/grips: alpha 0 on their surfaces in the same
  transaction, alpha 1 back (WM's cached alpha) - not relative-layered, since their WM z (index in the shared token)
  isn't known for the restore. Drop the lift on: page off (drawer settled shut, not editing), AppWindows.options
  (every launch), Switcher.open, HomeShell onStop, fold (!AppWindows.floating), page reload. Re-apply on task events.
  Rejected: reorder/minimise windows behind home (WM makes them invisible: no live content, nothing to blur); task
  leash z via a remote transition (an open transition blocks WM Shell; restoring needs WM's z for each task);
  moving the drawer into an overlay window (big rewrite of home's gestures/state, the drawer owner's).
- Open question for the build: home's content (1-p opacity) draws over the windows from the drawer's first frame; lift
  at drawer start (rule: panels always above) and check a mid-open frame for a pop.
