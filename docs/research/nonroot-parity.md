# PowOS without root: feature parity (2026-11-03)

The user (11-03): "PowOS nonroot should be a high prio, it should work exactly the same with all the features minus the
ones requiring root. We can sell the non-rooted launcher if it works." This is the map: every feature on a rooted phone
vs a phone without root, why it differs, and the fix. Read from the code on the tip of `worktree-powos-multiplatform`
(no unrooted phone was attached to check on a device), so "works" means "no root dependency in its code path".

## The two ways PowOS runs on Android

| | rooted | no root |
|---|---|---|
| Linux | PowOS rootfs in `/data/powos/root`, the session started by `su` (`powos-session.sh`): KWin, D-Bus, PipeWire, SpacetimeDB `127.0.0.1:3410`, the App API runtime `:3411`, `powos` tools | the PowOS image downloaded by the engine (`InstallActivity`, `http://android.pow/apk/powos-rootfs.tar.gz`) into the app's files, entered with `liblotfixrun.so` (patched glibc loader + fakechroot, **no proot**) by `andro.marchy.SessionService` |
| the launcher's Linux calls | `RootedGuest` (`su -c sh /data/powos/powos-run.sh`) | before 11-03: **nothing** - Omalauncher's proot Arch (`Proot`, files/arch) is never installed under `POWOS = true`; since 11-03 `EngineGuest` (lotfix into the image) for widget commands/streams |
| session start | `ShellActivity.onCreate` starts `SessionService` | only the engine's own `MainActivity` (the "PowOS desktop") starts it; the launcher never does |

The original Omalauncher worked unrooted because it installed its own proot Arch and `Runtime.onLinuxReady` brought up
its Wayland server, proc shim, open bridge, provisioner and `widgets.linuxChanged(true)`. PowOS switched that path off
(`bootstrap.isInstalled && !POWOS -> onLinuxReady()`, "until phase 2") and only built the rooted replacement
(`onRootedReady`). So on a phone without root nothing told the widget engine Linux exists, and every Linux-backed
feature calls `RootedGuest` - `su`, which isn't there.

## Feature table (ordered by user impact)

| # | feature | rooted | no root | why | fix |
|---|---|---|---|---|---|
| 1 | Home widgets with commands (fetch, games, performance, any store widget with `cmd`/`stream`) | works | **was broken (empty tile)** - fixed 11-03 | nothing called `widgets.linuxChanged(true)`; GuestShell/Streams ran proot on a rootfs that isn't there; the web home got no "waits for Linux" state and drew an empty tile | DONE (this change): `EngineGuest` runs them in the image via lotfix; `Runtime.onEngineReady`; tile says "needs the PowOS Linux image - Download (N MB)" (tap opens the download) or "starting PowOS Linux..." |
| 2 | PowOS app islands on home: Agents, What needs me, Lights, Pet, Sketch, Health, Counter | works | **broken** | bundles live in `files/apps/<id>/current`, put there only by `powos app install` inside the rooted session (bind mount in `powos-session.sh`); their databases are SpacetimeDB at `127.0.0.1:3410`, started only by the rooted session (`powos-start.sh`) | a) module-less apps (needs-me, its notifications are Android's): ship their built UI in the APK (or fetch from PowApps) into `files/apps` - no Linux needed; b) STDB apps: start SpacetimeDB + the App API runtime in the engine session (lotfix), same ports, or on the phone side |
| 3 | PowOS Linux image download | n/a | heavy (one big tarball) | `powos-rootfs.tar.gz` is the whole desktop + gaming | task `powos-image-for-non-rooted-devices-is-too-heavy` (image-slim: base/gaming split) |
| 4 | Linux apps in drawer/search, Linux app windows (web windows), Steam/games | works | **broken from the launcher** | the PowOS app list is exported by the rooted session (`run/powos-apps`, `powos-apps-export`); `ShellActivity` starts `SessionService` only when rooted; launches go through `RootedGuest.openAsTask` | start `SessionService` from the launcher when the image is installed; app export + launch through `EngineGuest` (powos-apps-export in the image session); windows through the engine's display daemon |
| 5 | Terminals (terminal tiles, Terminal app, `terms`/tmux list) | works | **broken** | `ShellTerminals`/`TerminalTiles` run `su -c powos-run.sh`; Omalauncher's foot-on-Wayland path is off with `onLinuxReady` | PtyTerminal on `liblotfixrun.so -c powos-tmux-shell` (EngineGuest) |
| 6 | PowOS AI page chat / manager, agent mail, comms, "send to coordinator" | works | **broken** ("PowOS isn't running") | `PowosAiChat`, `AgentMail`, `AgentsSpool`, `ShellBridge` call `RootedGuest` only | the same calls through EngineGuest once the image is installed; a clear "needs the PowOS Linux image" state before |
| 7 | Android app web windows (floating/tiled Android apps on virtual displays) | works | degraded | `WebWindows` uses `RootShell` for `am start --display`, `move-stack`, input injection, SurfaceFlinger dumps | partly needs-root-by-nature (launching other apps on our virtual display); fallback: open as a normal Android task / Android's own freeform, say so |
| 8 | Performance widget numbers (GPU busy, thermal, /proc/stat) | works | degraded (zeros) | untrusted apps can't read `/proc/stat`, kgsl or thermal zones (SELinux), root or not inside fakechroot | Android APIs where they exist (`HardwarePropertiesManager` is system-only; `PowerManager.getThermalHeadroom`, `BatteryManager`); mark the rest "needs root" in the tile |
| 9 | Game boost (big-core clocks, uclamp), system float overlay, force-stop background apps, Android settings writes (web window tiles), Android system colours from the theme, wallpaper root shot, native settings index | works | needs root by nature | `RootShell` for sysfs/cgroups/`cmd overlay`/`am force-stop`/`settings put` | keep off without root; where a `pm grant WRITE_SECURE_SETTINGS` (one adb line) would do, offer it |
| 10 | Home grid, dock, search, drawer (Android apps), folders, Android app widgets, weather widget (http), quick launchers | works | works | Android APIs + the web shell only | - |
| 11 | Notifications, shade, control center toggles, lock face, keyboard, assist, dictation | works | expected to work (no root in the path; listener/accessibility grants) | Android permissions | verify on an unrooted device (no emulator path checked here) |

## What changed 11-03 (nonroot-widgets)

- `targets/android/app/engine/.../SessionService.java`: `guestProcess(ctx, command)` - `liblotfixrun.so -c` with the
  session's environment (`archEnv` made static).
- `targets/android/app/app/.../linux/EngineGuest.kt`: the no-root guest + `guestProcess()`, the one choice of
  RootedGuest / EngineGuest / proot used by `GuestShell` and `widgets/runtime/Streams`.
- `Runtime.kt`: `onEngineReady()` (widgets' Linux on when the image is installed: at start, after the engine's install
  on resume).
- `shell/ShellHome.kt` + `ShellWidgets.kt`: widget items carry `linux: {state, mb}`; a tap on an "image" tile opens the
  download. `shell/ui/grid.tsx` `LinuxWait` draws it. Gate scene `nonroot-widgets` (NR1).
