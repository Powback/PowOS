---
name: powos-gestures
description: Use when working on PowOS's edge gestures (Good Lock-style handles, short/held x straight/up/down), Quick Tools, the bottom-corner pull-up panels over apps, the overlay window hosts (OverlayHost, QuickToolsHost, PullHost, ShadeHost's pull) or the pull down on home opening the shade window - how the input reaches each, the bridge events, pitfalls, logs and the on-device check.
---

## The input path (one input monitor, consumers in order)
- GestureMonitor.kt: InputManager.monitorGestureInput (MONITOR_INPUT via the recents role). On each finger DOWN the
  consumers are asked in order (PowosRecentsService.startGestures): **CornerPull(NavGesture) -> EdgeGestures ->
  ShadeHost.pull**. The first whose onDown says true follows the gesture; TAKE pilfers (windows + other monitors get a
  cancel). `takesOnDown` (EdgeGestures) pilfers at the FIRST event after the down - never inside the DOWN's own
  delivery: pilfered there, the dispatcher sent the monitor a second DOWN and none of the moves (Quick Tools dead,
  "edge: down" logged twice; InputDispatcher: "pilfer points from a channel without any on-going pointer streams").
- Order matters: ShadeHost.pull accepts any finger on home's body while homePull is on, so the bar's strip (nav,
  corners) and the edge handles must come first.
- SystemUI's EdgeBackGestureHandler ("[Gesture Monitor] edge-swipe", OPlus "NoBackGesture" logs) is also a spy;
  whoever pilfers first wins. The edge handles pilfer at the first move, before its threshold, so Back never wins inside the handle; above/below the handle nothing is touched. Pilfering on down costs the
  app the taps in that 18 dp strip (the same trade-off Good Lock makes).

## Edge gestures
- EdgeGestureClassifier.kt (pure, EdgeGestureClassifierTest): the direction is decided after `trigger` px of travel
  (sensitivity high 18 / normal 28 / low 44 dp): straight <= 30 deg, up/down <= 75 deg, steeper = along the edge (none).
  Long = held still (6 dp) 300 ms after deciding; the host polls `hold()` every 50 ms, because a resting finger sends no moves.
- EdgeConfig.kt <-> screens.tsx GesturesScreen: the page store `edgeGestures` = files/shell-data/edgeGestures.json
  (FileObserver reloads it). Keys short|long.straight|up|down. Actions: quicktools back home recents previous
  notifications control assistant drawer playpause none app:<pkg>. Defaults: right on, lower half (0.5..1, clamped
  above the nav strip), straight=back, up=quicktools, down=notifications; left off (all short = back).
- Off when: keyguard/bouncer/dozing/lock face, either shade open, Quick Tools open, IME visible (SYSUI bit 18 on this
  phone - read from SystemUI's getSystemUiStateString via dexdump).
- Back = ISystemUiProxy.onBackEvent(null) (HACK row; SystemUI sends down+up itself). Assistant =
  PowosVoiceInteractionService.show() (showSession). Drawer = home intent with EXTRA_HOME_PANEL -> "home.panel".
- Handles: TYPE_NAVIGATION_BAR_PANEL (2024) non-touchable strip windows "PowOS edge handle left|right".

## Window hosts (OverlayHost.kt base: TYPE_STATUS_BAR_SUB_PANEL 2017, full screen, kept warm GONE)
- show() visible not touchable -> armOpen() touchable+focused only after PageWatchdog.probe answers (a dead page must
  never leave an invisible touch-eating window) -> armShut(), and the page says closed (else hide after 1.5 s).
  Home/recents/screen-off (ACTION_CLOSE_SYSTEM_DIALOGS) dismiss.
- QuickToolsHost: mode=quicktools (ui/quicktools.tsx: control.tsx's Tile/Slider, onShut hook). Events "qt.drag"
  {side,y(css px),q}, "qt.settle" {open}; page calls powos.overlay.closed(). Blur = native region under the card only
  (nativeglass.ts OVER_WALLPAPER includes "quicktools"; glass.ts TINT_ONLY too).
- PullHost: mode=pull (design-QA's ui/pull.tsx). "pull.begin" {kind apps|ai}, "pull.drag" {p}, "pull.end" {open},
  "pull.hide"; page calls powos.pull.closed()/launched(); Back -> "system.back". Blur: WindowBlur({root}).set(p).
  CornerPull: outer 22% of the bottom strip, over an app only, claimed once up > slop and > 1.2x sideways (nav gets a
  cancel); switch files/shell-data/pullOverApps.json ("off").
- ShadeHost (mode=shade, ui/shade.tsx + notifications.tsx/control.tsx): the ONLY notification panel/control center.
  From the status bar (right half = control) or, while `homePull`, anywhere on home's body (notifications), claimed
  only if dragged down within 250 ms of the down (a long press's drag stays home's). Home's page sends
  shade.homePull(on) from home.tsx (nothing open, page >= 0); it resolves true when the host's monitor takes it, false
  -> gesture.ts asks shade.open on a swipe down. openPanel(control) opens it without a pull (edge actions).

## Pitfalls already paid for
- A kept-warm overlay page reloaded while hidden (an install, a shell push) only boots once its window shows: armOpen
  uses PageWatchdog.probeShown (3 s grace for "not rendered"), or the first pull after an install closed at once.
- Kotlin pushes: `tools/phone/compile-check.sh && git push` - its exit code, never a grep of its output (0b3a702
  broke origin's build that way).
- A shell file pushed/overridden without what it imports breaks every page (17:09, 2026-10-21: home.tsx imported a
  gesture.ts export only a later commit added; every page failed after the install). Commit related shell files
  together; ship-apk now gates HEAD's own shell before building. gesture.ts is shared with the drawer and widgets.
- Kotlin: `return Log.w(...)` in a Unit function is a type error; ShellActivity's companion is private (top-level
  EXTRA_HOME_PANEL). OxygenOS framework shapes: check with dexdump first (handbook).
- The gate's assist page can time out once (flaky); rerun before blaming your change.

## Test
- Unit: gradle `:app:testDebugUnitTest --tests "*EdgeGestureClassifierTest*"` (in the android builder image).
- Shell: `shell/dev/gate.sh --tree`; renders: `SHOTS_ONLY='quicktools|gestures' shell/dev/gate.sh --tree --shots DIR`,
  review images via tools/phone/review-image.sh before shipping.
- Device checks take the verify lock only AFTER the free window (handbook 5a): `. tools/phone/verify/window-lock.sh;
  window_lock <name>` - never hold it through a wait (it blocks every ship-apk install). `verify/fold.sh` forces the
  other screen (cmd device_state, always reset); `verify/overlay-reload.sh` the push-then-pull reload check.
- Device: `tools/phone/verify/edge.sh [home|edge|corner|all]` (one AWAKE_ONLY idle wait, WAIT_S; goes home and checks
  it's in front; window states snapshotted mid-gesture via motionevents; recordings as root into $OUT), logcat tags PowosEdge,
  PowosCornerPull, PowosOverlay, PowosShade, PowosGestures; `dumpsys window windows | grep 'PowOS '` for the windows.

## Lock, overlays and reloads (facts)
- Never over a locked phone: `DeviceLock.locked(ctx)` (lock face up or KeyguardManager.isKeyguardLocked) gates the edge
  handles, Quick Tools, the shade pull and the pull-up panels. SystemUI's state bits are NOT enough: the PowOS lock face
  makes the keyguard OCCLUDED, not SHOWING. Handles re-check on SCREEN_OFF/ON/USER_PRESENT.
- Shell push reloads of hidden overlay pages are the host's (`OverlayReload`, `ShellHost.filesGate`): reload at alpha 0
  while hidden, defer while shown, poll with a hard 8 s deadline (an evaluateJavascript during navigation never answers).
- The shade pull maps the finger as the page does (`PanelPull`: q = dy*1.5/--drop, open > 0.15 or a flick); ShadeHost
  reads the page's `--drop` once per height.
- Home has NO notification panel of its own: home.tsx sends `shade.homePull(on)`; the host's monitor takes a down-drag
  on home within 250 ms of the finger-down.

## Keyboard for PowOS (Linux) text fields - task keyboard-follows-powos-text-fields
- Wayland: KWin patches 0010/0012 (targets/android/pkgs/kwin) send OUTPUT_TYPE_KEYBOARD on text-input v2/v3 focus ->
  engine SystemIME.setSystemKeyboardVisible; typed text returns as INPUT_TYPE_TEXT_INPUT. KWin logs
  "Android keyboard shown/hidden - <why>" on its stderr.
- X11 (Xwayland: no text-input; KWin 6.7 has no IM path for X11 clients): unit x11-ime-bridge. ibus-daemon --xim
  --panel=disable; GTK on X11 picks IBus's module by itself (GTK4: wayland prio 100 > ibus 50 > simple, so Wayland
  GTK stays on text-input); session/powos-ime-bridge is IBus's panel: FocusIn(ctx) -> KWin patch 0016 D-Bus
  `org.kde.KWin /org/powos/Keyboard org.powos.Keyboard.SetX11TextFocus(b)` (shown only while the keyboard focus is
  Xwayland's; logged "x11 focus/blur"). InputContext_1 = IBus's fake context (= nothing focused); blur debounced 150 ms.
  Typed text returns as key events (InputMethod::commitString without text-input). Log $XDG_RUNTIME_DIR/powos-ime-bridge.log.
- Env (session/plasma/powos-ime.sh -> plasma-workspace/env/ibus.sh + profile.d/60-powos-ime.sh): XMODIFIERS,
  IBUS_ADDRESS_FILE (IBus otherwise names its address file after WAYLAND_DISPLAY/DISPLAY, which differ per launcher).
  Never GTK_IM_MODULE/QT_IM_MODULE (takes Wayland apps off text-input). The image's env/ibus.sh was a shell error.
- Rootfs: phone-rules.conf keeps ibus (engines provided-away); KWin ships via rooted.sh deploy (newest out/pkgs kwin).
- Open: Steam's CEF only reaches IBus if its webhelper loads GTK's IM (unverified on the phone); a keyboard dismissed by
  Back doesn't return on a re-tap of the same X11 field (no new FocusIn).
- Open Linux apps for a check as the launcher does: `am start -n com.powos.app/dev.omalauncher.shell.ShellActivity --es
  exec '<cmd>'` (debug builds); never type into the user's tmux sessions.

## Device checks (all queued, never waited on)
- `tools/phone/verify/queue.sh add <board-task> <script> [args]` then end the turn; result lands on the board.
- Scripts: edge.sh [home|home-short|edge|shade|corner|locked|all], edge-more.sh (Back both edges, landscape, left edge;
  restores rotation + edge config), overlay-reload.sh (push then pull), fold.sh (forces the other screen via
  `cmd device_state state 0|3`, always reset), keyboard.sh. All take the verify lock only after a free window
  (window-lock.sh), honour LOCK_HELD=1.
- Test swipes: keep Quick Tools' in-and-up near 40 degrees on every screen shape (a flatter one is straight in = Back).
  The lock face is a swipe up (no PIN); screenrecord only as root into /data/local/tmp; pull into an existing dir.
