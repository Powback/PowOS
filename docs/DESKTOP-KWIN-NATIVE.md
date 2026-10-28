# Desktop mode is KWin + the PowOS shell (a native Plasma replacement)

Status: **decided 2026-10-28** by the coordinator, on the user's words. Plan only; no code changed with this doc.

The user, 2026-10-28 19:50, after a day of bugs in Linux windows shown as Android tasks (Steam's header drag doesn't
move the window, title bars drift, overlays): **"its super buggy we need a proper plasma replacement dude natively"**.
Earlier: **"it's supposed to be a full plasma replacement not a hack on top of plasma"**.

**Decision.** In **desktop mode** (unfolded inner screen, later an external display) KWin composites and manages
every Linux window, and PowOS's shell (the same `shell/` web UI, hosted by `sources/powos-shell`) replaces
plasmashell: option B/C of `docs/DESKTOP-NATIVE.md` section 3. **Folded phone mode stays Android-native** (option
A). This reverses the 2026-10-24 recommendation ("keep A, do not start B") for desktop mode only.

Why now: the seam (Linux windows as `PowosWindowActivity` tasks, kwin 0013-0038, 26 patches) keeps producing bugs
that do not exist in KWin itself: moves, decorations, popups, X11 self-moving windows (Steam), full screen. In the
Plasma app the same windows are plain KWin windows and those bugs are gone by construction.

## 1. What exists today

### powos-shell (the Qt host), `sources/powos-shell/`

Further than "phase 0" (9fcf6d8f). Already built and run on the phone (`dev/phone.sh build|start|status`, units
`units/phone/powos-desktop-shell.json`, autostart via `powos-desktop-shell enable`, off by `desktop-shell.off`):

| piece | state | where |
|---|---|---|
| `powos:` scheme, overrides + hot reload, QWebChannel bridge with the phone's `PowosHost.call` contract | works | `src/server.cpp`, `src/bridge.cpp`, `shell/hosts/desktop.ts` |
| **home** role: `index.html?mode=desktop`, bottom layer, all edges, scope `dock`, KWin blur regions from the page's glass | works on the phone (renders, widgets, PowOS AI pill, pet, dock under the pill, launcher over it) | `src/home.cpp`, `shell/ui/desktop.tsx` |
| **panel** role: bottom layer-shell bar, exclusive zone 48, taskbar over libtaskmanager (`TasksModel`: activate, minimize, close; Android windows marked), launcher over KSycoca + `KIO::ApplicationLauncherJob` | works in nested KWin and on the phone via `powos-desktop-shell taskbar on`; not the default | `src/panel.cpp`, `src/services.cpp`, `shell/ui/panel.tsx` |
| store, theme (Omarchy colors.toml), ai (`powos manager`), net secrets | works | `src/services.cpp`, `src/net.cpp` |
| unified sleep: frozen with its Chromium tree 15 s after PowOS leaves the screen | works | b4d266fb |
| notifications server, OSD (`org.kde.osdService`), system tray (SNI host), quick settings (audio/network/BT/power), `org.kde.plasmashell` name, KSplash stage, clipboard history, lock-screen face | **missing** (plasmashell provides them) | DESKTOP-WEB-SHELL.md section 2 rows |
| title bars / window chrome on the desktop host | missing (KWin's Breeze decoration draws them; fine for phase 1) | DESKTOP-SHELL.md "Shared system chrome" |
| one renderer for all surfaces | missing: one `QWebEngineView` per role per screen | `src/main.cpp` `add()` |

### The Plasma app (`MainActivity`, alias `HomeDesktop`)

One translucent `SurfaceView` showing KWin's whole output ("anland-1"), kwin anland patches 0001-0038. `onStart`/
`onStop` send `desktop 1|0` (`WindowTasks.desktopShown`; kwin 0025: windows started while the desktop is shown stay
KDE windows). Folded it steps aside instead of re-laying out (`MainActivity.onCoverScreen`, keeps its inner size);
`FoldWatcher.unfolded` brings `HomeDesktop` back with `su am start` only when `HomeScreen.desktopIsHome()` (setting
`unfold_opens_desktop`, home_screen "desktop"). The session survives APK updates (05b81555: kwin 0035 redials the
new display daemon; `powos-session.sh` reattaches). While the app is away the session is frozen (no frame callbacks).

### Measured cost

- powos-shell, 2026-10-21 (DESKTOP-SHELL.md): ~250 MB host + 230 MB renderer + ~145 MB zygotes = **~625 MB RSS**,
  GPU in-process, home role only.
- Phone now (2026-10-28, folded, read-only): `plasmashell` 292 MB RSS, `kwin_wayland` 172 MB, `Xwayland` 36 MB;
  powos-shell not running.

Why 625 MB is less bad than it reads, and how to cut it:

1. **RSS double-counts the shared Chromium library.** `libQt6WebEngineCore.so` (~150-200 MB of text) is mapped into
   the host, both zygotes and the renderer, and RSS counts it in each. The real number is **PSS**
   (`/proc/<pid>/smaps_rollup`); `powos-desktop-shell status` should print PSS too. Expect well under 625.
2. **One renderer for all surfaces.** Each role is its own `QWebEngineView`; a second role (panel) is likely a
   second renderer (+~150-230 MB). Use the `window.open` child pages planned in DESKTOP-WEB-SHELL.md 3.4 (one
   renderer, one Preact runtime, one signal store driving every surface), or at least
   `QTWEBENGINE_CHROMIUM_FLAGS="--renderer-process-limit=1 --process-per-site"`.
3. **Drop plasmashell** once powos-shell owns its services (phase 3): -292 MB RSS.
4. Chromium trims: `--in-process-gpu` (already), `--js-flags=--max-old-space-size=...`, no spare renderer, and
   freeze while away (already).
   Target: powos-shell PSS (all processes) <= plasmashell's today, so desktop mode costs no more than Plasma.

## 2. The desktop-mode switch: fold and unfold

```
unfolded (inner screen)                              folded (cover screen)
 HomeDesktop = MainActivity, full screen              HomeShell (Android WebView shell) = home
  KWin composites: Linux windows, decorations          Android composites: Android apps, PowOS shell
  powos-shell: home (bottom) + panel/dock + launcher   Linux windows: reached on demand as full-screen tasks
  plasmashell: headless (phase 1) -> gone (phase 3)   KWin session frozen, alive, keeps inner-screen size
```

- **Enter (unfold):** `FoldWatcher.unfolded` already starts `HomeDesktop` when desktop is home. Desktop mode makes
  that the default unfolded (setting `desktop_mode`, default on in rooted mode). The surface keeps its inner size
  across the fold (`onCoverScreen` returns early in `surfaceChanged`), so unfold is a thaw + one frame, not a
  re-layout. Measure unfold -> first KWin frame (FoldScreenSwitching_* events vs the first `surfaceChanged`/frame);
  target < 700 ms. If `su am start` dominates (a root shell spawn), start it from the app's own process instead
  (FoldWatcher runs in SessionService; with `START_ACTIVITIES_FROM_BACKGROUND` held as a privileged app, or through
  the existing shell bridge).
- **Leave (fold):** the existing step-aside (`moveTaskToBack`), the session freezes (unified sleep), powos-shell
  freezes with it. Linux windows are desktop-owned (kwin 0025) and stay on KWin's desktop; they are **not** exported
  as tasks on fold.
- **Session alive:** keep 05b81555's reattach path; no KWin restart on fold, unfold, or APK update. A crash of
  powos-shell is a reload (renderer) or a restart by `powos-desktop-shell` with plasmashell's panel as the fallback.

## 3. Android apps in desktop mode

| option | what exists | latency / cost | input + IME | verdict |
|---|---|---|---|---|
| (a) virtual display mirrored into a KWin window, **scrcpy** | **works today**: `targets/android/session/powos-android-app` (`--new-display`, `--no-vd-destroy-content`, VA-API hardware decode through termux-va, app_id `android-<pkg>` = taskbar icon, `--task` moves a running task onto the display, `powos-android-tasks` lists the phone's apps in the taskbar) | H.264 encode + decode per frame: unmeasured here (scrcpy is typically ~30-70 ms) plus encoder power; fixed-size display (HACK: `--flex-display` broke Chrome) | touch/keys/mouse injected by scrcpy; text through key events/clipboard, no Android soft keyboard | a working stopgap; real KWin windows |
| (b) Android freeform tasks over the KWin surface | **today's seam** (`android-request float`, WindowFrames, in-task frame plan in DESKTOP-NATIVE.md 2026-10-28) | native, zero copy | native IME, Recents | z-order is two worlds again: an Android window is always above every KWin window and above PowOS's dock/launcher; separate taskbar, separate frames. The bug class the user is tired of |
| (c) **zero-copy virtual-display windows** (`targets/android/docs/android-windows.md`, design 2026-10-13, not built) | design only | VirtualDisplay -> ImageReader `AHardwareBuffer` -> dma-buf fd over a socket -> `zwp_linux_dmabuf_v1` buffer in an `android-window` Wayland client; no encode; frame callbacks pace it | input injected into the display id (root, no Shizuku needed); resizable (`VirtualDisplay.resize`); IME: set the virtual display's IME policy to the default display (`setDisplayImePolicy(..FALLBACK_DISPLAY)`, what DeX does) so the real Android keyboard types into the app; check on device | **the target** |

**Recommendation: (c), reached through (a).** One window manager (KWin) for every window in desktop mode is the
whole point; (b) keeps two. (a) already gives that today and is the phase-2 default; (c) replaces its transport
(phase 4) with the same window, taskbar entry and app_id, removing the encode latency and power and fixing resize.
Keep (b) only as the fallback for apps that refuse non-default displays (some DRM/banking apps; FLAG_SECURE needs a
secure virtual display, which root can create) and when adb/root is unavailable. Trade-offs accepted: Android apps in
desktop mode lose Android Recents/split/PiP (KWin's tiling, overview and the taskbar replace them); folded, they are
fully native again.

## 4. Today's window-task code

`WindowTasks.java`, `PowosWindowActivity.java`, `WindowFrames.kt`/`WindowFrame.kt`, `TaskFrame.kt`, kwin 0013-0038.

- **Desktop mode:** not used. KWin never exports a window while desktop mode is on (`desktop 1` for the whole mode,
  not only while `MainActivity` is started; `export-new 0`).
- **Folded:** keep, frozen in scope: a Linux window opened from the folded web shell is a full-screen task
  (`FoldedWindows` already makes tasks full screen folded). No floating Linux tasks, no new features.
- **Retire (phase 5)**, once desktop mode carries the unfolded Linux use: the floating-Linux-window parts (overlay
  title bars/grips for Linux tasks, KWin-side move/drag/decor handoffs 0018, 0026, 0033, 0036, 0038, popup-in-task 0027
  if full-screen folded tasks don't need it), each removed with a check that folded tasks still open, type and close.
- **Pause** steps 2-13 of DESKTOP-NATIVE.md "Desktop windows inside the web shell (2026-10-28)" (in-task frames,
  DesktopChromeHost): they solve unfolded floating windows in the Android shell, which desktop mode no longer has.
  Steps 0-1 (clamp, persist bounds) stay useful for Android freeform fallbacks.

## 5. Phases (each shippable alone, each checked on the phone)

### Phase 1: KWin desktop with PowOS's dock and launcher (smallest real step)

Goal: unfolded, Linux windows are plain KWin windows (Steam's header drag moves Steam, KDE decorations, popups,
maximize, X11 all native) and the visible shell is PowOS's (dock/taskbar + launcher + home), not Plasma's.
Android apps stay as they are today in the Plasma app (freeform over it, or `powos-android-app` from the taskbar).

1. **Desktop mode setting** (`desktop_mode`, default on rooted): unfolded home = `HomeDesktop` full screen
   (`HomeScreen.desktopIsHome()` true when on), via the existing FoldWatcher/onCoverScreen path. Folded unchanged.
2. **No exports in desktop mode:** `WindowTasks` sends `desktop 1` + `export-new 0` for the whole mode (not only
   `onStart`), so a window started from anywhere (the AI, a terminal, Android's launcher) stays a KWin window.
3. **powos-shell on by default in desktop mode:** roles `home panel` (`powos-desktop-shell enable` + `taskbar on`
   from the app when desktop mode is turned on; `desktop-shell.off` removed). The panel is the PowOS dock/taskbar
   look (`shell/ui/panel.tsx` styled as the phone dock, pinned apps from the `desktop-home` dock pins) with the
   launcher (`shell/ui/drawer.tsx` content in the panel's grown surface).
4. **plasmashell headless:** a Plasma update script (like `session/plasma/powos-transparent-desktop.js`) removes
   plasmashell's panels in desktop mode and keeps its transparent desktop; plasmashell keeps notifications, OSD,
   tray and Klipper until phase 3. Undo = re-add the default panel (the fallback when powos-shell fails to start).
5. **Launcher keys:** Meta and the swipe-up (kwin 0009) open powos-shell's launcher (a D-Bus method on powos-shell,
   e.g. `org.powos.Shell /Launcher toggle`), not Kickoff.
   Built 2026-10-28: `org.powos.Shell /Launcher toggle` (src/launcher.h, registered with `POWOS_DESKTOP_MODE=1`);
   Meta = kwinrc `[ModifierOnlyShortcuts]` set by `powos-desktop-shell desktop on`; swipe-up = kwin 0009 now calls
   it as well as plasmashell's `activateLauncherMenu` (no Kickoff without a panel), kwin 3.45. Items 3-4:
   `powos-desktop-shell desktop on|off` (the app calls it on a setting change; the session passes
   `POWOS_DESKTOP_MODE` from `settings get global powos_desktop_mode` to `start --auto`).
6. **One renderer:** home + panel in one renderer (window.open children, or `--renderer-process-limit=1` first);
   `powos-desktop-shell status` prints PSS per process.

Check (`tools/phone/verify/desktop-kwin.sh`, new; runs only in a free window, no touch while the user is active):
unfold -> HomeDesktop in front and the time to first frame; KWin `stackingOrder` has powos-shell's panel (exclusive
zone: a maximized Kate stops above it) and no plasmashell panel; launching Konsole from the launcher gives a KWin
window and no `PowosWindowActivity` task (`dumpsys activity containers`); a KWin-script move of Steam's window
(or Kate's title-bar drag) changes its `frameGeometry`; fold -> desktop steps aside, session frozen, no new tasks;
unfold -> the same windows at the same geometry; PSS of kwin, plasmashell, powos-shell recorded.

### Phase 2: Android apps as KWin windows (scrcpy path by default)

In desktop mode, the launcher and taskbar open Android apps with `powos-android-app` (KWin windows, taskbar entries);
freeform over the surface only as fallback. Fix the fixed-size display HACK (`--flex-display`). Check: an Android
app opens as a KWin window, takes touch + keys, closes back to the phone; measure input-to-frame latency and CPU.

### Phase 3: the shell owns plasmashell's services; plasmashell no longer starts in desktop mode

Notifications (`org.freedesktop.Notifications` via libnotificationmanager, toasts + history), OSD
(`org.kde.osdService`), SNI tray + quick settings (PulseAudioQt, NetworkManagerQt, BluezQt, UPower, brightness),
`org.kde.plasmashell` (`activateLauncherMenu`, `evaluateScript` no-op), Klipper's history, KSplash stage. Then
`powos-start.sh` skips plasmashell when desktop mode is on (no systemd on the phone), with the plasmashell fallback
on repeated powos-shell crashes. Check: `busctl --user` names diff against a Plasma session; volume key shows our OSD;
a `notify-send` toast; plasmashell absent; PSS saved.

### Phase 4: zero-copy Android windows (option c)

`android-window` per android-windows.md, root instead of Shizuku, IME policy to the default display. Same app_id and
taskbar entry as phase 2, so the shell doesn't change. Check: latency and CPU against phase 2's numbers, resize
follows the window, the soft keyboard types into the app.

### Phase 5: retire the seam

Remove floating Linux tasks and their KWin patches (section 4), keep folded full-screen tasks. Check: folded Kate
task opens, types, closes; unfolded nothing exports.

### Phase 6: polish

Lock-screen face (kscreenlocker stays the authority), live thumbnails/overview, the shell's own title bars if the
user still wants web chrome on KWin windows (DESKTOP-SHELL.md "UI direction"), an external display as a second
output, keyboard navigation and a11y.

## 6. Risks

- **Android system UI over KWin:** the shade, PowOS quick tools and the Android keyboard stay Android overlays above
  the Plasma app (they work there today). Notifications appear twice (Android's shade and, phase 3, the desktop's
  toasts) unless one mirrors the other; phase 3 decides.
- **Memory:** KWin + Xwayland + powos-shell + (phase 1-2) headless plasmashell all live in desktop mode. Phase 1's
  PSS numbers decide how urgent phase 3 is.
- **scrcpy latency** is unmeasured on this phone; if phase 2's numbers are bad, phase 4 moves ahead of phase 3.
- **Plasma library ABI** (libtaskmanager): powos-shell is built on the phone against its own Plasma (`phone.sh build`).
