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
| 4 | Linux apps in drawer/search, Linux app windows (web windows), Steam/games | works | via Guest (11-03 nonroot-session) | the PowOS app list is exported by the rooted session (`run/powos-apps`, `powos-apps-export`); `ShellActivity` starts `SessionService` only when rooted; launches go through `RootedGuest.openAsTask` | start `SessionService` from the launcher when the image is installed; app export + launch through `EngineGuest` (powos-apps-export in the image session); windows through the engine's display daemon |
| 5 | Terminals (terminal tiles, Terminal app, `terms`/tmux list) | works | via Guest (11-03 nonroot-session) | `ShellTerminals`/`TerminalTiles` run `su -c powos-run.sh`; Omalauncher's foot-on-Wayland path is off with `onLinuxReady` | PtyTerminal on `liblotfixrun.so -c powos-tmux-shell` (EngineGuest) |
| 6 | PowOS AI page chat / manager, agent mail, comms, "send to coordinator" | works | via Guest (11-03 nonroot-session) | `PowosAiChat`, `AgentMail`, `AgentsSpool`, `ShellBridge` call `RootedGuest` only | the same calls through EngineGuest once the image is installed; a clear "needs the PowOS Linux image" state before |
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

## What changed 11-03 (nonroot-session): one Guest for every PowOS Linux call

- `linux/Guest.kt`: the one pick - rooted (`RootedGuest`, every call delegated unchanged) / the PowOS image without
  root (`EngineGuest`, lotfix-run) / none (`Guest.NEEDS_IMAGE`, shown instead of failing). `run`, `runOwn`, `process`,
  `launch`, `openAsTask`, `terminal`, `terminalShell`. Widgets keep `guestProcess` (its third choice is proot).
- Gap 4 (apps, windows, Steam): `ShellActivity` starts the image's `SessionService` without root once the image is
  installed; `Runtime.onEngineReady` turns on the PowOS session paths (`powosSession`): `powos-apps-export` in the image
  fills the drawer (same `run/powos-apps`), drawer/game launches go through `Guest.openAsTask` / `Guest.launch`.
- Gap 5 (terminals): `PtyTerminal`, `ShellTerminals`, terminal tiles and `PowosTerminalActivity` run `Guest.terminal`
  - lotfix-run into the image, `powos-tmux-shell` where the image has it, else `bash -l`; tmux list via `Guest.run`.
- Gap 6 (AI page, mail, comms): `PowosAiChat`, `AgentMail`, `AgentsSpool`, `ShellErrors`, `ShellBridge` through
  `Guest`; `App` starts mail/wake/agents watchers for the image's run dir; without Linux the chat says what's needed.
- Still rooted-only by nature: the system theme, game boost, the desktop-shell hook, Plasma bridge, verify queue.
- Test: `GuestTest` (pick, rooted terminal line byte-for-byte, open-task line unchanged, a source scan that no PowOS
  Linux call skips Guest).

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

## 11-04 (nonroot-checks): emulator checks without root, and the plan for Linux windows on GPU-less devices

Checked on the emulator (`persist.powos.root=0`, APK of agent/nonroot-shell-up 02b6a1cc, the downloaded base image):

| check | result | fix |
|---|---|---|
| AI page: chat sends, a reply arrives | **failed**: "PowOS AI didn't answer: FileNotFoundError: 'claude'" - the image has no Claude Code (the rooted phone's was installed by hand into `~/.local/bin`) | `lib/ai/manager/manager.sh` `_manager_ensure_claude`: installs it on first use (vendor installer, ~20 s, runs fine under lotfix). Then a reply arrives (shot `02-ai-chat.png`). The endpoint (`/etc/powos/ai/endpoint.conf`, the fleet authority + its routing tag) is still per-device setup as on the rooted phone (`powos config claude-endpoint`/`claude-token`): without it, "401 Invalid bearer token" |
| Settings > Storage lists the packs with sizes | works (more apps 1.7 GB / 4.7 GB, developer tools, gaming 2.6 GB / 5.0 GB, languages) | - |
| "Add gaming": live progress + cancel | **failed**: the download ran (470 MB in 6 s) but the row stayed on "starting..." - `Packs.listener` was ONE static, the last `ShellScreens` built (every page host has one) - and there was no cancel at all | `Packs.listeners` (a set, removed on `ShellScreens.close`); `Packs.cancel` + "storage.cancel": the job stops at its next read, deletes what landed (the `.partial` list), the pack is as before; "cancel" on the Storage row and on the library's "add gaming" card; gate `addGamingCheck` taps it |

### Linux windows blank on GPU-less devices: a CPU-copy path in KWin's anland backend

**Cause.** KWin renders each consumer surface (the desktop, every window task) straight INTO the Android side's
buffers: `native_consumer.c collect_dmabufs` dequeues the `ANativeWindow`'s gralloc buffers (connected with
`ANW_API_CPU`, RGBA_8888) and sends their fds; `AnlandEglBackend::importConsumerBuffer` (patch 0013, used by
`AnlandEglLayer::importBuffers` and `AnlandWindowTask::importBuffers`) wraps each as `DmaBufAttributes` and calls
`EglBackend::importDmaBufAsTexture` -> an EGLImage -> GLTexture -> GLFramebuffer. With llvmpipe (no
`/dev/kgsl-3d0`, the emulator, any GPU-less phone) Mesa's swrast can't make an EGLImage of a gralloc buffer fd
("Error creating EGLImageKHR: EGL_BAD_ACCESS" -> "failed to import dmabuf 0 as texture"), so no buffer is imported and
nothing is ever drawn into the consumer: the window shows blank. Clients themselves are fine (llvmpipe clients
attach wl_shm buffers, which KWin uploads).

**Plan: render offscreen, copy the frame into the mapped buffer (no protocol change, no Android-side change).**

1. `anland_egl_backend.{h,cpp}` `AnlandEglBackend::importConsumerBuffer` (~35 lines): when `importDmaBufAsTexture`
   returns null, `mmap(fd, offset + stride*height, PROT_READ|PROT_WRITE, MAP_SHARED)`; on success allocate a plain
   `GLTexture::allocate(GL_RGBA8, size)` + `GLFramebuffer` as the render target and return them with the mapping
   (`ImportedBuffer` gains `uint8_t *cpu; size_t cpuLen; uint32_t stride, format;` + a `munmap` owner). Log once
   "consumer buffers: CPU copy (no EGL dma-buf import)". Same content transform (FlipY + rotation) as the GPU path:
   `glReadPixels` row 0 is the texture's row 0, which the consumer reads top-down, exactly as the imported buffer.
2. `AnlandEglBackend::copyToConsumer(const ImportedBuffer &, const Region &damage)` (~35 lines): bind the FBO,
   `glPixelStorei(GL_PACK_ROW_LENGTH, stride/4)`, `DMA_BUF_IOCTL_SYNC` START|WRITE, `glReadPixels(GL_RGBA,
   GL_UNSIGNED_BYTE)` of the damaged rows' bounding band straight into the mapping (ABGR8888 = RGBA bytes: no swizzle;
   XRGB8888 would need `GL_BGRA_EXT`, llvmpipe has `EXT_read_format_bgra`), SYNC END. Synchronous, so the render fence
   is -1 (llvmpipe has no `EGL_ANDROID_native_fence_sync`; `set_render_fence(-1)` = "ready now").
3. Call sites (~15 lines): `AnlandEglLayer::doEndFrame` (desktop: keep the `ImportedBuffer`'s mapping in the layer
   beside `m_textures/m_fbos`, copy the accumulated damage of `m_currentIndex`) and both renders in
   `AnlandWindowTask::render` (patch 0013/0052: after `endFrame()`, before `set_render_fence`; a task copies the whole
   buffer, it redraws it whole).
4. Order of fallbacks: GPU import (unchanged on every phone with a GPU) -> CPU mapping -> if the buffer can't be
   mapped either (a gralloc whose CPU access needs `AHardwareBuffer_lock`), a protocol extension: the consumer sends
   memfd buffers it copies with `ANativeWindow_lock` (`native_consumer.c render loop`, ~120 lines both sides) - only
   if step 1's mmap fails on a real device; ranchu's CPU-usage buffers and Qualcomm's ION/dmabuf heaps are mmap-able.

**Size**: ~90 lines in one new patch `0053-backends-anland-CPU-copy-when-EGL-can-t-import-the-consumer-s-buffers.patch`
(`targets/android/pkgs/kwin/src-tree.sh` for the tree, `targets/android/build-pkgs.sh kwin`). Cost: a 2268x2440
RGBA readback is ~22 MB/frame; damage-banded copies keep idle windows free, full-screen animation on llvmpipe will be
CPU-bound anyway. Not implemented in this change: the kwin build (~30+ min) and the emulator proof didn't fit its
hour; it is the task's next step.

### 11-04 (kwin-shm-copy): the CPU copy implemented - kwin 6.7.5-3.61 (patch 0053) + the consumer's CPU shadow

- **KWin (0053)**: `importConsumerBuffer` falls back to `importForCpuCopy` when `importDmaBufAsTexture` fails: mmap of the
  buffer's fd, an offscreen RGBA texture + FBO with the same content transform, `copyToConsumer` (glReadPixels of the
  damaged rows' band into the mapping, DMA_BUF_IOCTL_SYNC around it, render fence -1) from `AnlandEglLayer::doEndFrame`
  (the buffer's accumulated damage) and `AnlandWindowTask::render` (whole buffer). A memfd (F_GET_SEALS answers) goes
  straight to the CPU copy; a buffer with stride 0 is taken as tight rows. On a successful import nothing changes.
- **Consumer (native_consumer.c)**: without `/dev/kgsl-3d0` the window's buffers get CPU usage, and a buffer the app
  can't mmap either (the emulator: ranchu's host-memory gralloc, `/dev/goldfish_address_space` fds - KWin's mmap gave
  EPERM) is replaced for the producer by a memfd shadow, copied into the window's buffer with `AHardwareBuffer_lock`
  before it is queued. With `/dev/kgsl-3d0` (every Snapdragon phone) nothing changes.
- **Emulator result**: the path runs end to end up to KWin's first frame (log: "consumer buffers: CPU copy", "mapped
  buffer 0..2 ... for a CPU copy", "window task 1 live"), then KWin dies with SIGILL: llvmpipe's JIT emits SVE
  (`dupm`, insn 05c248c1 in an anonymous r-x page, caught with LP_NUM_THREADS=0) and this emulator (Apple M4 host)
  advertises `sve2` in /proc/cpuinfo but traps it. `GALLIVM_EXTRA_MATTRS=-sve,-sve2,...` did not change the code. Clients
  are unaffected (they draw with Qt's software path, no libgallium), so KWin had never drawn a frame on the emulator -
  before 0053 every import failed first. The window stays blank there (shot: ~/pw/kwin-shm-shots/). **Next**: make
  llvmpipe stop emitting SVE on a CPU that lies about it (find where Mesa 26.3 builds its LLVM features for aarch64 and
  why the extra mattrs don't apply; or run the emulator with a CPU model without SVE), then re-check systemsettings.


### 11-04 (emu-no-sve): llvmpipe without SVE on the emulator

- **Cause**: the emulator (37.2.12, Apple M4, hvf) passes the host's ID_AA64ZFR0 through (M4 is SME-only); the guest
  kernel 6.6.66 predates "arm64: Filter out SVE hwcaps when FEAT_SVE isn't implemented", so /proc/cpuinfo lists
  `sve2 svei8mm svebf16` but not `sve`. Arch's Mesa 26.3.0 pushes `+sve2` from that hwcap, then appends
  `GALLIVM_EXTRA_MATTRS` (comma-split, after the host features - read from the binary), so `-sve,-sve2` does apply;
  the earlier try most likely kept running SVE code from `~/.cache/mesa_shader_cache` (its key has no mattrs).
- **(a) emulator CPU model: not available.** The emulator's qemu (2.12-era fork, target/arm/hvf.c) has no CPU feature
  properties (`-cpu host,sve=off`/`sme=off` don't exist in the binary), and the kernel's `arm64.nosve/nosme`
  overrides don't touch ZFR0 in 6.6.
- **(b) done**: `session/Hyprland` - when the CPU lists sve2 without sve: `GALLIVM_EXTRA_MATTRS=-sve,-sve2` and
  `MESA_SHADER_CACHE_DIR=~/.cache/mesa-nosve`. On the emulator (persist.powos.root=0, the script patched in place with
  the env + cache off) KWin, Xwayland and plasmashell stayed up with no SIGILL (shot `03-nosve-home.png`); a
  systemsettings window was not proven yet: `powos-open-task` from an adb guest shell answered "desktop" (no task),
  so the next step is opening it from the launcher (drawer) and checking the window draws.

### 11-04 (nonroot-window-proof): a Linux window draws without root (emulator)

- **Branch** agent/nonroot-window-proof = kwin-shm-copy (kwin 6.7.5-3.61, patch 0053 CPU copy + memfd shadows) +
  emu-no-sve (session/Hyprland) + the tip; `lotfix-run.c` now gives every program the app starts in the guest the same
  `GALLIVM_EXTRA_MATTRS=-sve,-sve2` + `MESA_SHADER_CACHE_DIR=/root/.cache/mesa-nosve` (only without /dev/kgsl-3d0 and
  only when /proc/cpuinfo lists sve2 without sve; Hyprland no longer adds them twice).
- **Proof** (persist.powos.root=0, kwin 3.61 in the image, the branch's Hyprland + powos-apps-export copied into the
  image): the dock's System Settings tile -> KWin's window is the PowOS web window with its content drawn (Quick
  Settings, sidebar, theme previews), live 435 ms after KWin's open (shots ~/pw/nonroot-window-shots/03..05).
- **Found + fixed**: the window said app id `kdesystemsettings` (KDE's second .desktop for System Settings, NotShowIn=KDE,
  same `Exec=systemsettings`), the tile launched `l:systemsettings`: the placeholder stayed beside the window and later
  said "Couldn't open". Now `powos-apps-export` writes each app's hidden same-command entries (apps.tsv column 7,
  aliases), `LinuxApp.matches` takes them (and open-task's ids), and the adopt offer carries `alts` (the other shown
  entries with the same Exec) which a placeholder under any of them takes (gate LW3 `lw3Alts`, JVM LinuxAliasTest /
  LinuxSameCommandTest). powos-open-task itself answered "task" (no 30 s fallback to "desktop").
- **Left**: the base image must be rebuilt for the new Hyprland / powos-apps-export to reach installs (the emulator ran
  hand-copied ones); the window's search field takes focus and raises the Android keyboard on open.

### 11-04 (nonroot-base-refresh): the base carries kwin 3.61 + the new session scripts; keyboard on a window's first focus

- **Base rebuilt** (build-rootfs.sh, POWOS_PUBLISH_PACKS=1, Plasma pinned 6.7.5, the KWin/Plasma check passed): kwin
  6.7.5-3.61 and this tree's session/Hyprland + powos-apps-export are in powos-rootfs-base (byte-identical), published on
  android.pow/apk and pinned. split-rootfs.py now writes beside its hard-linked outputs and renames over.
- **Emulator** (fresh app data: `pm clear com.powos.app`, persist.powos.root=0, APK 7b8fcb48 via emu.sh install): the
  base downloads (995 MB) and installs (kwin 6.7.5-3.61 in its pacman db), KWin + plasmashell start, System Settings from
  the launcher draws in one PowOS window, no hand-copied files, and no Android keyboard comes up as it opens
  (~/pw/nonroot-base-refresh-shots/03..05).
- **Keyboard**: WebWindowSource now holds a window consumer's keyboard ask that no touch came before (TapKeyboard; a tap
  in that window raises it). But KWin's log shows the ask on open went to the DESKTOP consumer, before the window had its
  own keyboard: `Android keyboard shown - v2 show on the desktop 0`, then `window task 1 : its own Android keyboard true`.
  KWin then counts the keyboard as shown, so tapping the already-focused search field raises nothing (05).
  **Next (kwin 0043)**: when a window task takes its own keyboard, move the current shown state to that consumer (hide
  on the desktop, show on the window's, so TapKeyboard holds it for the tap) - kwin rebuild + base republish.
- Seen once after `pm clear`: LinuxService ForegroundServiceDidNotStartInTimeException (main thread busy at the
  first download tap; the app restarted and the second tap worked).
- **Fixed (kwin 6.7.5-3.62, patch 0054 + TapKeyboard; 3.63 adds cap "keyboard-live", and the app holds asks only when KWin advertises it, so an older KWin keeps the old keyboard)**: goLive() places the keyboard again, so the request made as the
  window opened moves to the window's own consumer ("Android keyboard shown - task live on window task 1"). The app
  holds it ("no touch behind it: held for the user's tap"), and a tap on the search field raises it ("raised by the
  user's tap"), and typed text lands in the field. Emulator, root=0, kwin 3.62's files put into the installed image by
  hand (the base on android.pow still has 3.61; republish it once 3.62 ships). Shots: nonroot-base-refresh-shots/06-08.
  The check uses `input swipe x y x y 150`: a 0 ms `input tap` lets the UP arrive before the page claims the gesture
  (the linuxClaim HACK in WebWindows.kt), so neither KWin nor TapKeyboard sees a tap.
- **Build friction**: build-rootfs.sh renames the new full rootfs over out/powos-rootfs.tar.gz, and that is the tree
  BUILD_ON_ROOTFS (kwin) and plasma-pin.sh build on. In the 11-04 rootfs, sudo fails in the build container
  (`pam_open_session: Permission denied`), so build-pkgs.sh kwin failed until the Oct-13 rootfs was linked back.
- **11-04 kwin-363-rollout**: kwin 6.7.5-3.63 published to the [powos] repo (publish-repo.sh: android.pow/apk/repo, every
  package at or above what the repo had - the repo still served kwin 3.3 from 10-13); the rooted phone's install queued
  (verify queue, kwin-install.sh 6.7.5-3.63, idle window). Base + packs rebuilt with kwin 3.63 (build-rootfs.sh,
  POWOS_PUBLISH_PACKS=1, Plasma pinned 6.7.5, KWin/Plasma check passed), published and re-pinned. The new full rootfs is
  kept as out/powos-rootfs-1104-363-full.tar.gz and the Oct-13 rootfs linked back as out/powos-rootfs.tar.gz (the
  sudo-in-the-build-container friction above).
