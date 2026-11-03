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
| 2 | PowOS app islands on home: Agents, What needs me, Lights, Pet, Sketch, Health, Counter | works | **broken** | bundles live in `files/apps/<id>/current`, put there only by `powos app install` inside the rooted session (bind mount in `powos-session.sh`); their databases are SpacetimeDB at `127.0.0.1:3410`, started only by the rooted session (`powos-start.sh`) | PARTLY DONE 11-04 (nonroot-islands): the repo's apps (`apps/bundled.list`: What needs me, Pet, Health, Counter, Sketch, App API) ship built in the APK and show without the registry; What needs me needs no Linux; STDB apps' islands say "starting PowOS Linux…" / "needs the PowOS Linux image - Download" while `EngineServices` starts SpacetimeDB + the App API in the image and publishes the APK's modules. Left: Lights (own repo `~/Projects/lights`, DB `local-lights` for its pairing/prefs - bundle it + keep that state Android-side), Agents (needs powos-agentsd), check on an unrooted device |
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

## What changed 11-04 (nonroot-islands)

- `apps/bundled.list`: the apps the APK ships. `targets/android/build-app.sh` builds each (`apps/build.sh`) before the
  APK, refusing when one fails; `app/build.gradle.kts` `copyApps` puts `powos-app.json`, `out/ui/` and
  `out/module.wasm` in `assets/apps/<app id>/`, plus `lib/apps/powos-noroot-services`.
- `shell/LocalApps.kt`: the APK's + installed apps as registry rows (`apps.local`, with `rooted` and where SpacetimeDB
  stands); `ShellHost.appFile` serves the installed UI, else the APK's. `apps.getLinux` opens the image download.
- `linux/EngineServices.kt` + `lib/apps/powos-noroot-services`: no root, the image installed - SpacetimeDB (3410) and
  the App API (3411) started from the image's service manifests through EngineGuest (no supervisor: HACK, REMOTE-POWOS
  §4), the APK's modules published when their wasm changed. Kicked by `Runtime.onEngineReady` and by each
  `apps.local` while SpacetimeDB is down (every 30 s at most).
- `shell/apps/localapps.ts`: the page polls `apps.local` (every 3 s until SpacetimeDB is up); `useRegistry` /
  `watchRegistry` add the local apps when not rooted (a registry row wins); `ui/island.tsx` `IslandWait`. Rooted:
  `apps.local` says `rooted: true` and nothing changes. Gate scene `nonroot-islands` (NI1), JVM `LocalAppsTest`.
- Was open, fixed 11-04 (nonroot-auth): who can reach 3410/3411 without root - next section.

## Who can reach SpacetimeDB and the App API (no root; 11-04, nonroot-auth)

**Threat.** Android's loopback is one network for every app. A TCP port PowOS listens on (SpacetimeDB 3410: every
PowOS app's database and the agents' board; the App API 3411: app actions with injected credentials) answers any
installed app, which could then read and write PowOS's databases and call the App API as PowOS. Rooted phones lock
the ports to the PowOS uid (`rooted/powos-start.sh`, an iptables owner match); without root nothing can filter by uid,
and SpacetimeDB has no "require a token" mode (anonymous connections get a fresh identity; modules don't check
`ctx.sender`).

**Fix: no TCP port at all.** In the no-root image the services' binds become Unix sockets in the app's private files:
- `targets/android/app/engine/native-src/launcher/loopback-unix.c` (`libpowosloopback.so`, freestanding so the NDK
  builds a library glibc programs can load): `bind()` of a TCP socket to a port in `POWOS_LOOPBACK_PORTS` (3410,3411,
  any address) binds `$POWOS_LOOPBACK_DIR/<port>.sock` (mode 0600) instead; `connect()` to 127/8 or ::1 on those
  ports connects there (no socket file = `ECONNREFUSED`); `accept()` drops a peer of another uid (`SO_PEERCRED`,
  defence in depth); addresses and TCP-only socket options are faked so SpacetimeDB, Python's http.server/urllib, curl
  and the spacetime CLI run unchanged. Everything else passes to the next definition (android-compat, fakechroot).
- `lotfix-run.c` preloads it first when `POWOS_LOOPBACK_PRELOAD`/`_DIR` are set; `SessionService.archEnv` sets them
  only when not rooted (dir `files/run/loopback`, 0700). So every program of the image - the services, the starter
  (`powos-noroot-services`), the agents' tools (`powos agents`, `powos-agentsd`), `powos app`, `appcap_add` - reaches
  `127.0.0.1:3410/3411` exactly as before, over the private socket. App data dirs are per-app (0700 + SELinux
  categories), so no other app can open the sockets.
- The WebView can't open a Unix socket: `linux/LoopbackGate.kt` listens on a random 127.0.0.1 port per service and
  forwards to the socket only requests whose path starts with `/_powos/<token>/` (each request on a connection is
  checked; constant-time compare; stripped before the service sees it); anything else gets 403 and never opens the
  socket. The token is per install, random (32 bytes), in `files/powos-loopback.token`. The page gets its SpacetimeDB
  URL from `apps.local` (`stdbUrl`, `shell/apps/stdb.ts stdbUri()` - the SDK resolves `v1/...` against it, so the
  prefix survives, CORS preflights included); `ShellNet` routes `http://127.0.0.1:3410|3411` (`net.fetch` from the
  App API app, search, composed widgets) through the gate itself, so apps never see the token. A random port can't be
  squatted by another app to phish the token, and the token alone opens nothing but the gate.
- `EngineServices.state` checks the socket (`LoopbackGate.up`), not a TCP connect.
- Rooted: unchanged (no env, no preload, no gate; `apps.local` says rooted and the page keeps `ws://127.0.0.1:3410`).

Left: a statically linked guest program (Go) bypasses the preload and simply can't connect (fails closed). The page's
JS holds the token; PowOS apps' islands run in that page and already have full access through the host.

Tests: `test/tier1/test-loopback-unix.sh` (real programs under the preload in gcc:14: no TCP listener, same uid
works, another uid refused by the file and by `SO_PEERCRED`, other ports untouched; the NDK-built library loads under
glibc too); JVM `LoopbackGateTest` (no token / wrong token / a later token-less request on the same connection:
403 and nothing reaches the service; PowOS's own requests forwarded with the token stripped).
