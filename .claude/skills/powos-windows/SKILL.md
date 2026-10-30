---
name: powos-windows
description: Use when working on PowOS window tasks - floating Android windows (taskbar, title bar, maximise/resize/density), the swipe-up switcher and recents transition, desktop/Plasma modes (powos-shell host, KWin), or Linux windows in the dock/switcher - including writing and landing a KWin patch.
---

## Quick recipe
- Files: `targets/android/app/.../system/{WindowFrames,FreeformTasks,NavGesture,RecentsTransition,AppWindows,
  TaskLeash,WindowTasks,OemCaption}.kt`, `shell/ui/recents.tsx`, `shell/hosts/wide.ts`, `sources/powos-shell/` (Qt
  desktop host), `shell/hosts/desktop.ts`+`layout.ts`, `shell/ui/desktop.tsx`/`.css`. KWin:
  `targets/android/pkgs/kwin/` (see "Writing a KWin patch" below for the patch/number workflow).
- Build: Kotlin compile check before pushing to origin: `tools/phone/compile-check.sh`; ship/install:
  `tools/phone/ship-apk.sh --note "..."` (never build by hand). Desktop host (on-phone, ~20s):
  `sources/powos-shell/dev/phone.sh build`; status/render: `dev/phone.sh status|cdp 'JS'|page NAME|shot NAME`.
- Check, emu first then phone: `tools/phone/verify/queue.sh add --dev emu <board-task-slug> <script>.sh` (example: `add --dev emu desktop-mode-stabilisation-move-resize-maximise float-desktops.sh`; result lands in ~/.cache/powos-verify-queue/done/<id>.log, partial while running). Window/recents UI is emu+phone; phone-only (Linux session, KWin
  install): `linux-float.sh`, `fold.sh`, `one-title-bar.sh`, `plasma-modes.sh plasma|shell|together`,
  `plasma-transparent.sh`, `plasma-notify.sh`, `plasma-app.sh` (queue `kwin-install.sh MIN` first if KWin is behind).
- Land: `tools/agents/land.sh "msg" -- <paths> --ship "..." --queue <check args>`.
- Friction: `tools/agents/friction add --area <switcher|desktop> --kind <...> "<title>" --repro "<cmd>"`.

### desktop (paused 2026-10-22)
- Plasma checks are PHONE ONLY (Plasma session). After landing shell files, the desktop host's own shell copy needs `sources/powos-shell/dev/phone.sh build` separately.
- Friction: `tools/agents/friction add --area desktop ...`.

## switcher



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
- Maximise / app full screen (window-max, 2026-10-23): maximise = resizeTask to AppWindows.area; the restore entry
  (WindowFrames.Max) is kept until the task LISTS the new bounds (at 80 ms it often still lists the old: the old
  retainAll dropped it there, so restore did nothing), then while it keeps them. Double tap on the bar = maximise
  (WindowFrame.barTapped, in release). App's own full screen: Chrome's HTML full screen calls
  Activity.requestFullscreenMode (dex: "DisplayEdgeToEdgeFullscreen" feature gate); adopt() used to float any visible
  full-screen task back - now tasks seen floating (`windowed`) are left full screen, their bounds kept (`fullBefore`)
  and set back when they float again (backFromFullScreen). Linux: KWin 0021 "fullscreen <id> 1|0" (cap fullscreen) ->
  PowosWindowActivity.appFullScreen (immersive) -> WindowTasks.fullScreenTask -> WindowFrames.appFullScreen ->
  FreeformTasks.setFullScreen (WCT mode UNDEFINED/FREEFORM + bounds as a change transition). Before 0021 an exported
  floating window going full screen stayed in its task, scaled down (0017 fitsWindow), frame + dock around it.
  (f468af79 "bare resizeTask changed NOTHING": the button never fired - see CORRECTION below; Calculator + Kate stayed put;
  float-windows' maximise FAILed too) - maximise now runs a TaskLeash session (909be605), resizeTask only as fallback.
  HWC Disp Frame is in the inner panel's landscape space: screen (l t r b) = panel (t, W-r, b, W-l) (window-max sfrow).
  Not yet measured: whether WM grants Chrome's requestFullscreenMode with freeform tasks on a full-screen display. Check: verify/window-max.sh calc|kate|video
  (recordings in ~/.cache/powos-verify/window-max/<round>/). KWin installs through verify/linux-float.sh (newest
  out/pkgs/kwin-* in any worktree: never leave a stale same-version build there).
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
- Swipe/close = quit the app (kwin 0042, pkg 3.48, 2026-10-30): Tasks.remove -> WindowTasks.quitting(taskId) marks the
  PowosWindowActivity; its onDestroy sends "quit <id>" (cap "quit"; older KWin: "closed"). KWin closeWindow()s it (full
  screen too, any export-new), 3 s later `powos-app-quit <pid>` if the pid still runs, has no other window and no modal
  dialog. Helper (session/powos-app-quit): Steam game -> `powos game <appid> stop` (reaper ancestor / SteamAppId env),
  else pid's tree; never Steam client/FEXServer/session/KWin/Xwayland. Logs: logcat WindowTasks "quit N", KWin "quit N:",
  $XDG_RUNTIME_DIR/powos-app-quit.log. Back still sends "closed". Launch windows (splash, id 0) send nothing yet.
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
- `android-request power logout` (the checks' fresh session) did nothing on 2026-10-23 22:42: no new session.log
  start, same KWin pid. The run dir had two FileObservers (AndroidRequests + MainActivity's focused-window): one
  inotify descriptor, the last started takes every event, and either one's stopWatching ends both. Run-dir watches go
  through engine DirWatch (one shared watch per folder). Checks restart/install KWin via verify/kwin-up.sh (kwin_up
  MIN; its FAIL says whether the app took the request).
- Session restarts (kwin 0023, 3.27): KWin's window ids restart at 1, Android keeps the old window tasks (seen 2678,
  2679), and restoreLinux matched Kate to the dead one ("FAIL no window task in 30 s", launch "ok null"). KWin sends
  `session <uuid> <ids>` (also on the app's `hello`); the task data carries `?session=`; WindowTasks.finishStale
  removes every other window task without telling KWin; appIdOfTask / "open" only use live() activities. Logcat:
  WindowTasks "KWin session ..", ".. not this KWin's, finished"; PowosWindow ".. not the running KWin's".
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

- One title bar per window (kwin 0026, 3.30): KWin's `decor <id> 1|0` (isDecorated: xdg-decoration/server-decoration
  mode, _MOTIF_WM_HINTS, _GTK_FRAME_EXTENTS) -> WindowTasks.kwinBar -> WindowFrames.ownBar -> WindowFrame.App.ownBar:
  no bar window, grip only. Its own bar's drag: KWin cancels the interactive move, sends `move <id>` ->
  PowosWindowActivity.appMove -> WindowFrames.appMove -> WindowFrame's Drag (buttons off). Logcat WindowTasks "decor N",
  "move N", PowosWindowFrame "its own title bar, no bar", "moved by its own title bar". Check: verify/one-title-bar.sh.
  0033 (3.38): the hand-over only for an EXPORTED window. A task created but never live (no "window task N live")
  left its window on the Plasma desktop, and every title-bar drag there (KDE decoration or CSD) was cancelled: the
  user's "i cant move plasma windows" (2026-10-28, hyprland.log: 11x "window task 11 asked to be moved" on the cover).
  0034 (3.39), the cause of the never-live task: a task goes live only when its activity's consumer connects; one
  made while the screen is off or the phone folds (the desktop is "off" for that gap: "desktop on screen: false",
  "window task 11 has KWin's title bar", "desktop on screen: true") is stopped at once / covered by the desktop and
  stays in fallback for good while its window is on Plasma. Now setDesktopShown(true) closes every task that never
  went live ("window task N never went live: its window stays on the desktop") and the app drops it (WindowTasks
  closedOpening: a "close" before the activity registered finishes it on register). Grep for never-live tasks:
  "has KWin's title bar|draws its own" with no "window task N live" before the next "connected to daemon at".
  Not the same as Java's PowosWindowActivity.live() (the appIdOfTask HACK, still unproven).
  Open: a CSD drag (Brave, task 13) INSIDE a live task logged no "asked to be moved" at all - the move request never
  started KWin's move (unmeasured why: X11 vs Wayland Brave, implicit-grab serial for task touches).
- Launch windows (LaunchWindows.java): Runtime.openRooted opens one at the tap (no window task for the app yet); KWin's
  first `open` for the app id becomes it (logcat WindowTasks "open N (id): in its launch window", PowosWindow "launch
  window: now window N"); the helper's exit + 3 s ends one still waiting. Not yet for games (Runtime.launch).
  Check: verify/launch-window.sh (task within 1.5 s of the tap, same task + bounds once Steam's window comes).

## Latest hand-off
- State (2026-10-24): one title bar (kwin 0026, pkg 6.7.5-3.30: "decor"/"move") + launch windows (LaunchWindows.java)
  are on origin; nothing ran on the phone (ships/queue paused). Queued: one-title-bar.sh (installs 3.30 via
  linux-float.sh first) and launch-window.sh, both --close on their board tasks.
- Gotchas: the 3.30 package lives only in csd-launch's out/pkgs (keep it until the check ran). kwin patch numbers
  collide between agents (0025 was taken twice): look at origin's pkgs/kwin right before you add one. Steam's own bar
  does ask (_NET_WM_MOVERESIZE), but X11Window::NETMoveResize (events.cpp) drops it unless InputRedirection has a
  button/touch down - and a task's touches go straight to the seat (0020), so it never had one: no "asked to be moved"
  in hyprland.log, no "move" in logcat (2026-10-28). kwin 0039 (3.44) counts seat->isTouchSequence() too. Any
  core-KWin "is a button/touch down?" gate needs the seat, not InputRedirection, for a task's touches. An adopted launch window keeps
  its launch data as the task's base intent (finishStale/kept, onSaveInstanceState carry the window's own).
- Next: read both check results; if no "move N" in logcat on a Steam bar drag, find how Steam moves itself (X
  configure requests?) and map that to the task; launch windows for games (Runtime.launch); Steam's own
  minimise/maximise buttons on a task.

## Fold / unfold with apps and games running (2026-10-24, fold-launch)
- Unfold used to make Plasma's desktop (HomeDesktop) Android's default home and start it (FoldWatcher.unfolded, setting
  home_screen "auto"): it covered the web home; Android's recents transition then targeted HomeDesktop while PowOS's Home
  brought HomeShell - home flipped between the two per gesture (events log 23:48:48-58: wm_task_to_front 2733/2742).
  Now auto = HomeShell on both screens; FoldWatcher's fold/unfold moves only run when the "desktop" setting made
  HomeDesktop home (HomeScreen.desktopIsHome). Check: no HomeDesktop task appears after `cmd device_state state 3`.
- Android (OxygenOS 16) keeps a freeform task freeform through a FOLD, at its inner bounds (t2741 [556,366][1916,2074] on
  the 1116 px cover, visible=false): its switcher card grew to that box. FoldedWindows (PowosRecentsService config change
  + AppWindows.taskOptions) makes every freeform task full screen when !AppWindows.floating; logcat PowosFoldedWindows.
- Main logcat rolls in ~2 min; the EVENTS buffer (wm_task_to_front, wm_create_activity, FoldScreenSwitching_*) keeps
  ~15 min: `logcat -d -b events` for what happened when the user reports a state minutes later.
- Check: verify/fold-launch.sh app:<id> (game launched folded, unfold, Home, refold, switcher on the cover).

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
- Window bounds API facts (dex of this build, 2026-10-23, window-core #5): IShellTransitions has registerRemote(2),
  unregisterRemote(3), registerRemoteForTakeover, getShellApplyToken, getHomeTaskOverlayContainer, setHome/Focus-
  TransitionListener, forceCancelRecentsTransition, notifyLauncherStateChange, (un)registerRemoteTaskListener
  (IOplusTaskListener), updateRemoteTransitionState - NO startTransition: a launcher can't have Shell start a WCT's
  transition. WM core startNewTransition(type, wct) = new Transition + startCollectOrQueue + the WCT applied in it
  (OnePlus hooks: shouldSkipStartTransition, fillExtendInfo); applyTransaction = ActionChain "applyTransactLegacy"
  (collected into a transition only if one is collecting). Shell's onTransitionReady for a token it didn't start:
  Log.wtf "Got transitionReady for non-pending transition" + a fallback ActiveTransition, then dispatchReady (remotes'
  filters, handlers) - so that E line comes with EVERY startNewTransition PowOS makes; it is not itself the failure.
- CORRECTION (window-core #6, 2026-10-23 23:30): there was NO maximise revert. The title bar's buttons never fired on a
  tap in any device run (window-max calc/kate 18:16 + 23:10, float-windows 15:20: not one "maximised" line for a button
  tap); every "maximised/restored" line in those logs was the DOUBLE TAP (bar path, 4 actions -> 2 lines, 8 s apart),
  which always stuck. So "lands +0.1 s, old again +0.35 s" and "bare resizeTask changed nothing" (f468af79) measured a
  button that did nothing. Why a clickable child of the bar never got its click is not known (the UP reached
  com.powos.app); since 053f2d38 the buttons are marks the bar's own touch handler (Drag) hit-tests at the lift and
  each tap logs PowosWindowFrame "task N <button>: tapped|let go off it".
- Raising (4fc2f82f): a touch on a frame no longer calls moveTaskToFront at the DOWN (a TO_FRONT transition of its own,
  still collecting when the drag's CHANGE started a few ms later; 2 empty TO_FRONT transitions per double tap in the
  23:18 log). A window not in front (WindowFrames.isFront: first of `running`) comes up in the drag's start WCT or
  maximise's (TaskLeash.reorder, same transition), a plain tap's at the lift.
- Leash-off resize = stale crop (resize-probe 20:26, measured): WM had the new bounds, the app window too, but the
  app's INPUT frame stayed cut to the old width (the task surface's crop: WM Shell syncs a freeform leash only inside a
  transition on this ROM) - the new part blank, its touches to home. So resizes go through the leash again (the
  68a3b4ed stopgap removed, `powos_leash_resize` unused).
- window-max.sh (3dac79bd): one phone call per look (grab: bounds, mode, bar, HWC), WM/Shell/OnePlus logs via
  `logcat -t <mark>` right after each change appended on the phone (wm.txt; the whole-logcat capture + 4 calls per
  look ran both diag rounds past 300 s; each adb call over the VPN ~2.5 s), button taps as DOWN / touched windows / UP.
- The user (2026-10-23, on "no launcher path"): "that's the beauty, we own the full stack". The phone is rooted, so a
  missing Shell API is not a stopping point: fix at the platform level (memory: fix-at-platform-level). Candidates:
  give WM Shell the entry point (a PowOS window-bounds handler running in SystemUI's process, so its transitions are
  Shell's own pending ones and its drag owns the leash like desktop mode's DragPositioningCallback), or fix the WM
  core / OnePlus code that undoes the size once the diag probes name it. Pick from the measurement, not a guess.
- Likely (not measured): a session holds its transition open for the whole gesture and ignores mergeAnimation, so every
  other transition on Shell's track waits behind it (input window gone / old bounds 5 s while a resize leash was open).
- Leash-on resize history: one run kept the old bounds 5 s with no app input window (resize-probe 1837, no logs kept),
  others left a "Transition Root: Task=N" layer. Likely the DOWN's moveTaskToFront racing the drag's CHANGE (fixed in
  4fc2f82f, not yet measured). Every leash start logs ShellTransitions E "transitionReady for non-pending" (expected).
- resize-probe.sh's `input:` grep needs the name right after the hex id: PowosWindowActivity (Kate) never matches, so
  "no input window" for Kate there is the probe's, not the phone's. Kate's bar loss after the flicks: the window under it
  (WireGuard) came to the front after the first flick (am stack order), so its bounds hid Kate's bar - who raised it is open.
- Framework/SystemUI dex dumps for codes: ~/.cache/powos-caption/{framework,sysui}/*.dex (dexdump in powos-vadb:
  `docker cp` the dex in, /opt/android-sdk/build-tools/35.0.0/dexdump -d).
- The bar's close worked on 0f098c06 for Calculator, Dolphin, Gwenview (desk-probe r3 touch state: the bar window
  gets the DOWN, nobody pilfers). The r2a failures (APK 367633db) stayed unexplained.
- Stacking order (2026-10-23): getRunningTasks sorts by LAST-ACTIVE time, not z. A window raised by a WCT reorder
  (restore, desktop switch) kept its old place, so a lower window's bar lay over the front one's (a drag on
  Calculator's bar moved Chrome: PowosTaskLeash "task <other id> move") and the dock's front was wrong. FreeformTasks.list
  now sorts by IActivityTaskManager.getAllRootTaskInfos (ATMS walks root tasks top to bottom; MANAGE_ACTIVITY_TASKS).
  Overlay frames stack in ADD order: WindowFrames.restack re-adds out-of-order frames whose reach (bar + grip) overlap
  (logcat PowosWindowFrames "frames restacked"). Minimise logs "minimise task N: done|refused (front was M)".
- HWC "Disp Frame" rects are in the PANEL's orientation: the inner screen is installOrientation 3, so raw = the window
  turned (l t r b = top, W-right, bottom, W-left). e2e-lib screenrect converts; window-rec/window-live use it.
- tools/phone/adb.sh pull to a NEW local file: fixed (it mounted only existing paths; window-rec's mp4s were lost).
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
- BUILT 2026-10-24 (shell/PanelLift.kt, page side ui/panellift.ts, "p.hello"/"p.lift 1|0"/"p.lifted 1|0" on the
  native port; check verify/panel-lift.sh): while a home panel is open, put HOME's window surface above the
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
- Home's own pages would draw over the windows once lifted: .home.over-windows hides .home-content (visibility, not
  opacity - gesture.ts reads opacity keyframes from CSS) while windows show, set BEFORE the lift (lift waits 2 rAF) and
  cleared only after "p.lifted 0". The bars are relative-layered UNDER home (blurred with their windows), not alpha 0;
  their WindowState surface (ViewRootImpl.getSurfaceControl) has z 0 in its own token, like home's, so setLayer(0)
  restores both. WindowFrames.underPanel holds new frames/raises meanwhile.
- Touch in a Linux window task (kwin 0020, 3.24): AnlandWindowTask::touchTarget picks a watched window in stacking
  order that isShown, readyForPainting, opacity > 0 and hitTest(pos), else the task's window (by frame alone Steam's
  steamwebhelper POPUP_MENU helpers, override-redirect, no WM_TRANSIENT_FOR, took taps). Note Xwayland delivers a
  touch by X stacking at ROOT coords, not by the wl_surface KWin picked: every Kept X window on any desktop overlaps
  there. KWin log lines: "touch at .. to ..", "also draws ..", "the window took .. itself .. sized back" (an X client's
  own configure, e.g. Steam restoring 1659x1746, is permitted by X11Window::configureRequest; 0020 refits, 5 tries).
  Check: verify/steam-input.sh (size = task +-4 px, LIBRARY tap, library scroll, Kate; OUT/steam.mp4, kate.mp4, kwin.txt).
- NO X11 window in a task took a tap (2026-10-23, Steam + its dialogs; kwin 0022, 3.26): exported windows live on the
  "Android tasks" desktop, never current, so X11Window::updateVisibility made them Kept (hiddenPreview), and
  Workspace::propagateWindows stacks Kept windows UNDER KWin's guard window: a root-sized, mapped, override-redirect
  InputOnly X window (the first ids of KWin's X connection: 0x200000 null focus, 0x200001 guard). Xwayland picks the X
  window for a touch/click by X stacking at root coordinates, so the guard took all of them (and internalKeep drops
  input focus). Read it without input: `xwininfo -root -children` + `xwininfo -id <id>` (Class InputOnly, IsViewable).
  0022: every window a task watches carries powosShownByTask -> shown (Mapped, stacked above the guard); focus() and a
  touch on a dialog raise the window (all task windows overlap at the same root place, X takes the top one). Wayland
  windows (Kate, Dolphin) never went through X: a failure there is something else.
  Check: verify/linux-touch.sh (Kate/Dolphin via apps.launch, a WAYLAND_DEBUG Kate, an X11 Kate + X stacking; LEASH=off).

## Latest hand-off
2026-10-24, popup-dock (kwin 0027 + move clamp; both on origin, ship requested).
- State: `WindowFrame.moved()` stops a window's bottom at `AppWindows.area().bottom` (home's dock top, the same limit
  opening, maximise and resize use); a window already lower keeps its top as the limit (no jump). kwin 0027 (6.7.5-3.31):
  `Workspace::setPopupAreaHandler` -> xdg_popup placement inside `AnlandWindowTask::area()` for task windows, their
  dialogs and their popups; desktop (Plasma app) windows keep the output's area.
- Checks: `window-dock.sh` (emulator, task floating-window-never-covers-dock) FAILED only on "no title bar window"
  (Calculator's missing bar, the other agent's regression) - re-queue it with `--dev emu --close` once that lands.
  `plasma-modes.sh popup` (closes linux-window-popups-not-clipped) + `plasma` queued on the phone.
- Gotchas: no patched KWin tree exists - fetch kwin-6.7.5.tar.xz, apply 0001-00NN, diff (friction f86). A fresh
  worktree needs out/powos-rootfs.tar.gz symlinked from powos-multiplatform before `build-pkgs.sh kwin` (f87).
  The checks install the newest kwin pkg from this or a sibling worktree: keep popup-dock's out/pkgs until they ran.
- Open: X11 override-redirect menus (Steam) place themselves and still clip.

## Latest hand-off (Linux session)
- 2026-10-24: logout (`android-request power logout`) was silently lost: two FileObservers on the run dir share one
  inotify watch (last started gets every event; any stopWatching ends both). Fixed by engine DirWatch (79b0867f), used
  by AndroidRequests, MainActivity's focused-window watch and widgets' file(). Likely the 22:42 trigger, not measured;
  confirm: close the desktop task, `android-request socket-test`, socket-test.log must update.
- Rooted logout path: power() kills the app -> Restarter -> MainActivity -> SessionService -> new `su` session;
  powos-rooted-session kills the old pgid. A manual logout brought up a new KWin in < 45 s.
- Checks: verify/kwin-up.sh (kwin_install / kwin_restart / kwin_up MIN, gate 6.7.5-3.28) in linux-session,
  linux-touch, steam-input. Queued: linux-session (--close), linux-touch LEASH=asis (--close), steam-input.
- Open: X11 taps on 3.28 (0022) unproven; floating-windows PASS also needs Dolphin + Steam typing in a recording;
  logout brings the Plasma desktop to front (web-shell-only mode may not want it).

## desktop



**Paused by the user, 2026-10-22:** no work on the separate Plasma desktop (powos-shell); the desktop is the PowOS
home unfolded / widescreen. powos-desktop-shell is disabled on the phone; the code stays.

## The desktop now (2026-10-22)
- The desktop is the PowOS home unfolded/widescreen, with Android apps as floating windows. The windows side
  (taskbar, focus/minimise/close, Android windows, switcher) belongs to this skill's switcher section (above).
- Wide home = shell/hosts/wide.ts, wrapped around the phone's bridge (bridge.ts) for home's page only (no ?mode=),
  at >= 700 CSS px (inner display 821, cover 404). Two host pages are shown side by side as one page of cols*2+1
  columns, with a free column between them so they never merge across the seam. Cells map both ways at the bridge
  (right page x+cols+1; a move goes back to the half its middle is over), widgets.page maps to the pair's left page
  (the host keeps a page's neighbours live), and fold/unfold emits home.changed. ShellHome.kt's GRID_COLUMNS (6) is
  one layout for both screens, so never persist wide cells.
- The wide pill (width min(560px, 100% - 2*edge)) and the centred dock are the @media (min-width: 700px) block at the
  end of ui/shell.css. The pill's height is the drawer skill's.
- Merging touching tiles: grid.tsx joins() joins only whole covered edges (widgets skill, fixed 2026-10-22). On
  mode=desktop joins() returns nothing.
- "Flat grey slabs" on the inner display are not missing blur: the user's wallpaper is pure black in its top third,
  behind the tiles, and a frost of black is black. Blur regions are sent (glass-native, __glass.live.counts).
- The monospace font is the theme's own --font, the same folded and unfolded. It is not a load failure.
- The ">" dock icon is Konsole's real icon. Chrome's and Camera's white plates are their Android icons.

## Plasma as an app + the web launcher's Linux backend (plan: docs/DESKTOP-WEB-SHELL.md, last section)
- Drawer "Plasma" = l:org.powos.plasma (session/plasma/org.powos.plasma.desktop, OnlyShowIn=X-PowOS so Kickoff hides
  it; the export accepts X-PowOS). Exec powos-plasma = PLASMA_COMMAND: Runtime.launch -> showDesktop() (MainActivity).
- Linux list: powos-apps-export (KService's rules over XDG dirs) -> run/powos-apps. powos-apps-watch (autostart,
  python inotify on ~/.cache ksycoca6_*, which kded6 rebuilds on an app dir change) reruns it; the app's FileObserver
  on icons/.icon-names (the export's last rename) -> reloadPowosApps(). Unit android-apps. Launch: powos-open-task.
- KF6 6.31 sends NO org.kde.KSycoca.notifyDatabaseChanged on D-Bus (kbuildsycoca6 measured silent): watch the file.
- Check: verify/plasma-app.sh (watcher idle, entry, kbuildsycoca6 -> new export, apps.list, apps.launch from HomeShell -> MainActivity or its alias HomeDesktop + plasmashell/KWin up, powos-shell not).
- Slice 3 (unit plasma-bridge): session/powos-plasma-bridge (python-dbus + GLib, autostart) <-> run/plasma/{out,in}/*.json
  (".name" then rename) <-> PlasmaBridge.kt (FileObserver, main process only). Notifications: a WATCHER of Plasma's
  server (org.kde.NotificationManager.RegisterWatcher; it calls our /NotificationWatcher org.kde.NotificationWatcher
  .Notify(u s u s s s as a{sv} i) with its id), posted as Android notifications tag "plasma", id = Plasma's id, extras
  powos.linux.app/entry/icon -> Notifications.item's app name, notificationJson's icon (linux app by entry/Icon=/name,
  else l:org.powos.plasma) and pkg "linux:<entry|app>" (else the shade groups it as PowOS's own). Closing: Plasma sends
  NotificationClosed TARGETED to the sender only, so a monitor-only connection (BecomeMonitor, one match rule) reads it;
  reason 1 (popup timed out) keeps it on Android. Android swipe = delete intent -> CloseNotification; buttons/tap ->
  org.kde.NotificationManager.InvokeAction. Skipped: app "PowOS agents" (comms-mcp already posts AgentMail).
- Clipboard: Klipper (inside plasmashell, org.kde.klipper /klipper) clipboardHistoryUpdated/get/setClipboardContents.
  Android reads the clip only while one of the app's windows has focus (READ_CLIPBOARD_IN_BACKGROUND is signature|role,
  the IME is SwipeKeyboard): listener + PowosWindowActivity.focusHook. KWin's Anland path also syncs while MainActivity
  is up; both dedupe on the last text. KDE Connect is in the rootfs, 0 devices paired: its notifications ride the watcher.
- Check: verify/plasma-notify.sh (bridge idle, notify-send -w -> shade list, notifications.dismiss -> gone + notify-send
  returns, Klipper <-> clipboard.read/write, the user's clip put back).

## Three modes (the user, 2026-10-24: Plasma and the web shell both first-class, alone and together)
- Rule: a window lives in ONE world. Opened in the Plasma app = a KDE window on Plasma's desktop (stays there after
  going home); opened from the web shell = an Android window task. Design + recommendation: docs/DESKTOP-NATIVE.md.
- App -> KWin "desktop 1|0" (MainActivity onStart/onStop -> WindowTasks.desktopShown; cap "desktop", kwin 0025,
  6.7.5-3.29): while on screen new windows stay on the desktop, maximize is KWin's, its windows get powosDesktopOwned
  and export-new's sweep skips them. Older KWin: the app sends export-new 0 while the desktop is on screen.
- Restarter (logout/reboot from the session): reopens MainActivity only if the desktop was on screen, else starts
  SessionService behind the web shell.
- Checks: verify/plasma-modes.sh plasma|shell|together (kwin_up 3.29 first; KWin facts via a loaded KWin script ->
  "PMW|..." lines in /run/powos-app/hyprland.log).

## Plasma's desktop wallpaper (org.powos.transparent: TRANSPARENT, never a picture)
- The containment keeps wallpaperplugin=org.powos.transparent (set once by the update script
  session/plasma/powos-transparent-desktop.js). It draws NOTHING and clears the window's fill, so the real Android
  wallpaper + frost show behind the app, seamless with home. The user wants this (2026-10-23, angry regression).
- Never draw the wallpaper in Plasma: cb40fa5 showed ShellWallpaper's /run/powos-app/powos-wallpaper-<ms>.jpg there
  (to fix black task snapshots); live that was a second crystal at another scale/offset (KWin scale 2.25), black at
  the top. Reverted. The app still writes those files (unused). Task snapshots / recents of the desktop show its
  widgets on black (Android leaves the wallpaper out) - open; fix it on the Android side, not with a Plasma picture.
- Wrong desktop again? Look: containment's wallpaperplugin (appletsrc), the installed main.qml (no Image), plasmashell
  started after the QML's mtime (it loads the QML once; rooted.sh deploy doesn't restart it, the check does),
  KWin script powos-translucent-desktop loaded.
- The wallpaper is OxygenOS's LIVE video wallpaper (FoldN3OpBlueWallpaper): its frame changes (a clip on unlock/fold),
  and home's widgets/status text are lit over its black sky - neither is a reference for "black". The 10-23 FAIL
  (0.117 black) was exactly that; measured 2026-10-24 with home's UI rects left out: 0.991 match, 0.009 black.
  SurfaceFlinger's stack is the structural proof: Wallpaper, then MainActivity's SurfaceView (isOpaque=false).
- KWin's own capture works on the phone (2026-10-23): `spectacle -b -n -f -o FILE` as the session user gives a
  2268x2440 RGBA PNG WITH alpha (transparent desktop = alpha 0). The ScreenShot2 D-Bus API itself refuses a plain
  python caller (NoAuthorized); PIL exists in PowOS for measuring. Check: verify/plasma-transparent.sh (home shot vs desktop shot where KWin alpha=0).
- A KWin capture taken while the session is frozen (desktop not in front) after a session start is ALL BLACK: the
  deleted ksplashqml window (stackingOrder, deleted=true) stays painted until frames resume. Bring the desktop up
  first. And a black frame "matches" a picture's black sky - compare only the picture's lit pixels.
- QML: /usr/lib/qt6/bin/qmllint in PowOS lints a deployed wallpaper; deploy rootfs files with
  `PATH="$PWD/tools/phone/bin:$PATH" targets/android/rooted/rooted.sh deploy --note|--silent`.

## Shot checks (shell/dev/shots.mjs, after each scene)
- Errors per shot: overlapping tiles (>1 px), partial joins, uneven gutters on mode=desktop, missing glyphs.
  SHOTS_STRICT=1 fails the run and gate.sh --shots. gate.sh mounts the real nerd_symbols.ttf. Output dirs under $HOME.

## Paused Plasma host: what's left on the phone
- Off: ~/.config/powos/desktop-shell.off (autostart start --auto then does nothing); unified sleep freezes its tree.
- Left data: shell-data/desktop-*, ~/.local/share/powos/net (Hue key copy; net-secret.sh remove), desktop-wallpaper.jpg
  and Omarchy current/theme from `dev/phone.sh wallpaper|theme` (HACK row dev/phone.sh; fix: the app writes them).
- dev/phone.sh render NAME WxH: off-screen second powos-shell (own profile, --disable-gpu), fresh frame when frozen.

The plan, the bridge table and what's shared: docs/DESKTOP-SHELL.md. The phone's rules: docs/AGENT-HANDBOOK.md.

## How it fits
- powos-shell (C++/Qt 6): one QWebEngineView per role per screen, made a layer surface by LayerShellQt (src/view.*:
  ShellView; src/home.*: the home; src/panel.*: phase 0's bar, not started by default). Serves shell/ on
  powos://shell/ (base $POWOS_SHELL_DIR, overrides ~/.config/powos/shell, hot reload), _app/<id>/ from
  ~/.local/share/powos/apps/<id>/current/ui, _font/symbols through fontconfig, icons on powos://icon/.
- Home: bottom layer, every edge, exclusive zone 0, keyboard on demand, scope "dock" (KWin: a special window: not
  a task, not an Android task, blurred). The background layer shares KWin's desktop layer with plasmashell's window.
  POWOS_HOME_LAYER=background / POWOS_HOME_SCOPE=... try others.
- Bridge (src/bridge.cpp): the phone's contract, PowosHost.call(id, method, argsJson) over QWebChannel, plus the native
  port (PowosNative + MessagePort): b.hello -> b.state, b.r -> KWindowEffects::enableBlurBehind (KWin 6.7:
  ext_background_effect_v1; the capability arrives ~0.5 s late, so a "no" is re-asked - HACK). Natively: apps (KSycoca,
  ApplicationLauncherJob), windows (TasksModel), store (~/.local/share/powos/shell-data, the phone's names), theme
  (~/.local/state/omarchy/current/theme/colors.toml, mapped as ui/Theme.kt), ai (`powos manager --once-stdin
  --json-events`, items kept in store desktop-chat).
- In the page (shell/hosts/desktop.ts, picked when PowosHost.name === "powos"): home layout + recents over the store
  (hosts/layout.ts, shared with the mock), keyboard/speech/widget screens as no-ops.
- STDB: the page's own ws://127.0.0.1:3410 (shell/apps/stdb.ts), unchanged. One failed first connect per database at
  start, then connected: not a loop. The page's fetch() to STDB's HTTP fails from powos: (CORS): no evidence of anything.

## On the phone (KWin on the Anland backend, rooted session)
    sources/powos-shell/dev/phone.sh build          # this tree -> built on the phone (~20 s), /usr/lib/powos/desktop-shell
    sources/powos-shell/dev/phone.sh start|stop|status   # status: RSS + CPU ticks per process (host, zygotes, renderer)
    sources/powos-shell/dev/phone.sh cdp 'JS'       # evaluate in the desktop page (DevTools on 127.0.0.1:9333, dev runs only)
    sources/powos-shell/dev/phone.sh page NAME      # Chromium's render -> /home/powos/design-qa/desktop-NAME.png
    sources/powos-shell/dev/phone.sh shot NAME      # KWin's capture (spectacle)
- The phone's Qt is 6.12 with QtWebEngine 6.11, which works (measured). Install nothing: units/phone/powos-desktop-shell.json.
- While the "PowOS" activity isn't in front, the session is frozen: KWin sends no frame callbacks, a newly started
  surface never commits, and KWin's capture shows the last painted frame (Plasma's clock stuck, ghosts of closed
  windows: deleted=true in stackingOrder). Report it; never unfreeze it or bring the activity up yourself. Android's
  screencap of the activity then shows only the wallpaper (Plasma's own panel isn't in it either).
- KWin scripts for window facts (workspace.stackingOrder: caption, resourceClass, dock, deleted, frameGeometry); their
  print() lands in /run/powos-app/hyprland.log (KWin's stdout, read via tools/phone/user.sh). Never call
  org.kde.KWin showDebugConsole: it opens a window on the desktop.
- QtWebEngine draws classic scrollbars (the phone's WebView overlays its own): desktop.css hides them, scrolling stays.
- Rest cost, measured 2026-10-21 over 60 s settled: host 3 ticks, renderer 0, zygotes 0; ~250 + 230 + 145 MB RSS.

## Renders and checks
- shell/dev/gate.sh boots mode=desktop with the other pages, idle check included.
- `SHOTS_ONLY='^desktop' shell/dev/gate.sh --tree --shots DIR --wallpaper FILE`: desktop, desktop-launcher,
  desktop-chat at plasma (558x1198) and laptop (1280x800) sizes; report.json has contrast per text.
  Use the phone's real wallpaper too, not only the light fallback. The desktop scenes drop the launcher's transform
  and will-change, else the emulated backdrop blur never reaches the wallpaper (an unblurred render under-states
  contrast). SHOTS_PROBE='JS' prints a value per shot (e.g. 404s from performance entries). Islands show their fault
  tile headless (no STDB); real island data only from `dev/phone.sh page`.
  Headless-only errors: STDB refused (no STDB in the container), /_font/symbols 404 (the mock doesn't serve it).
- The launcher on the desktop has a deeper dim (tint + 42%, desktop.css), measured with the blur emulated: the
  reference fill left 54 of 67 labels under 4.5:1 over a light wallpaper. Contrast wins over the reference look;
  re-measure (both wallpapers, three themes) before changing it.
- host.net (src/net.cpp, apps/net.ts's n.req over the native port) mirrors ShellNet.kt. Its secrets and pins are
  the desktop's own (~/.local/share/powos/net, 0600, key "<app>/<name>"). On the phone the Hue key was copied from
  the Android app's store with the user's say (2026-10-21), root-side and never printed:
      sources/powos-shell/dev/net-secret.sh copy local.lights hue      # -> "copied"
      sources/powos-shell/dev/net-secret.sh remove local.lights hue    # the way back -> "removed"
  Lights then loads its rooms and scenes. Never pair, switch, toggle or dim a light yourself; read state only.
- Shell files ship as usual: commit, rebase, push to origin, `tools/phone/ship.sh request --note "..."`; the
  desktop host's own copy of shell/ only changes with dev/phone.sh build.

## Next
Slice 2 (Linux windows in the dock + switcher) is done through WindowTasks, not the plasma-v1 bridge: KWin's "open"
carries the app id; details in the switcher skill (Linux windows in the dock + switcher). Next: inline replies (NotificationReplied), images in
clipboard/notifications. Paused host: hotkey, dictation, theme mirror, widget picker, x86 Plasma, input region, OWL widgets.

## Writing a KWin patch, reserving a number, and finding a built package (friction f76/f86/f87/f98/f111/f116/f121)
- **Never download kwin-6.7.5 and hand-apply 0001..00NN to write patch 00NN+1.** Run
  `targets/android/pkgs/kwin/src-tree.sh` - it reads PKGBUILD's own `_patches` list (never drifts from the real
  set), downloads the pristine source through the shared Mac-side cache (cached after the first call, on any
  worktree), applies every existing patch as its own git commit, and prints the tree path plus the next free
  patch number. Edit in that tree, then `git diff` (or `git format-patch -1 HEAD`, renumbered) for the new patch.
- **Reserve the number before you write it into a filename or PKGBUILD's pkgrel:**
  `tools/agents/pkg-claim.sh reserve-patch targets/android/pkgs/kwin` / `reserve-pkgrel targets/android/pkgs/kwin`
  - it checks this worktree, origin, AND a shared claims ledger together, so two agents in two worktrees never
    both land patch 0025 / pkgrel 3.29 (that happened once: different filenames, so git saw no conflict and both
    merged). `tools/agents/land.sh` also refuses a push whose patch number or pkgrel doesn't clear origin's, as a
    backstop if a reservation gets skipped.
- **Build inputs `build-pkgs.sh` needs that git ignores** (`out/powos-rootfs.tar.gz`, `pkgs/steam/sysvipc-emu.tar.gz`)
  and **every package it builds** (kwin, steam, fex-emu, gtk2, ...) live in a shared, content-addressed cache
  (`tools/agents/build-inputs-cache.sh`, `~/.cache/powos-build-inputs`, never pruned - hardlinked, so keeping
  every version costs no real disk space). `worktree.sh new` links the gitignored inputs into a fresh worktree
  automatically; `build-pkgs.sh` fills in anything still missing and lands every build there too, so the kwin
  3.29/3.30/3.31 and steam 29 packages are findable even after the worktree that built them is gone.
- **Installing a newest build:** `kwin-up.sh`'s and `linux-float.sh`'s lookups, and `pkg-install.sh <name>` (a
  bare name, not just a path - e.g. `pkg-install.sh kwin`), all check the shared cache as well as sibling
  worktrees. You don't need to keep a worktree alive, or hand-hardlink a package out of one, just to install it.
- **A check that needs a new KWin installed first:** queue `tools/phone/verify/kwin-install.sh MIN` ahead of the
  feature check, same board task - queue.sh runs a window's jobs in queue order, so the feature check finds KWin
  already there instead of paying for the install + session restart inside its own budget.

## Latest hand-off
2026-10-24 (plasma-modes): three modes landed (30d37122 kwin 0025/3.29, ed129de0 app `desktop 1|0` + Restarter,
08671d8d checks + docs/DESKTOP-NATIVE.md). Nothing phone-verified: ship + verify queue were paused by the user.
- Queued: plasma-transparent.sh (--close transparent task), plasma-modes.sh plasma (--close) / shell / together on
  in-the-plasma-app-linux-windows-show-as-normal-k. plasma/together need the new APK AND kwin 3.29 (kwin-up.sh's
  lookup now also checks the shared build-inputs cache, ~/.cache/powos-build-inputs/pkgs - 3.29/3.30/3.31 are all
  there, so worktree plasma-modes no longer needs to stay alive just to hold 3.29; see "Writing a KWin patch" below).
- Gotchas: the wallpaper is a live video; home's UI is no pixel reference. The Docker data disk was full: build kwin with
  PKG_SCRATCH=/var/tmp/powos-pkgs. KWin source for a new patch: `targets/android/pkgs/kwin/src-tree.sh` (see
  "Writing a KWin patch" above the hand-off) - never hand-apply 0001-00NN again.
- Unverified: a restart from home starts SessionService without MainActivity; KWin must come up without the desktop's
  surface (check linux-session.sh). Full-screen apps from Plasma still become their own tasks (deliberate).
- Next: popups of task windows clipped (DESKTOP-NATIVE slice 4, KWin); user's decision on the design note (board
  native-desktop-architecture, waiting).
