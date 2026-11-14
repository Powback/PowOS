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
| 2 | PowOS app islands on home: Agents, What needs me, Lights, Pet, Sketch, Health, Counter | works | **broken** | bundles live in `files/apps/<id>/current`, put there only by `powos app install` inside the rooted session (bind mount in `powos-session.sh`); their databases are SpacetimeDB at `127.0.0.1:3410`, started only by the rooted session (`powos-start.sh`) | PARTLY DONE 11-04 (nonroot-islands): the repo's apps (`apps/bundled.list`: What needs me, Pet, Health, Counter, Sketch, App API) ship built in the APK and show without the registry; What needs me needs no Linux; STDB apps' islands say "starting PowOS Linux…" / "needs the PowOS Linux image - Download" while `EngineServices` starts SpacetimeDB + the App API in the image and publishes the APK's modules. 11-10 (nonroot-islands): the razr's APK carried none of it (warm builder, below) - fixed; Lights bundled from its repo; Agents' reporter set up by the starter. Left: a razr check after the next APK + a base image with SpacetimeDB (Pet, Lights' DB) |
| 3 | PowOS Linux image download | n/a | heavy (one big tarball) | `powos-rootfs.tar.gz` is the whole desktop + gaming | task `powos-image-for-non-rooted-devices-is-too-heavy` (image-slim: base/gaming split) |
| 4 | Linux apps in drawer/search, Linux app windows (web windows), Steam/games | works | via Guest (11-03 nonroot-session) | the PowOS app list is exported by the rooted session (`run/powos-apps`, `powos-apps-export`); `ShellActivity` starts `SessionService` only when rooted; launches go through `RootedGuest.openAsTask` | start `SessionService` from the launcher when the image is installed; app export + launch through `EngineGuest` (powos-apps-export in the image session); windows through the engine's display daemon |
| 5 | Terminals (terminal tiles, Terminal app, `terms`/tmux list) | works | via Guest (11-03 nonroot-session) | `ShellTerminals`/`TerminalTiles` run `su -c powos-run.sh`; Omalauncher's foot-on-Wayland path is off with `onLinuxReady` | PtyTerminal on `liblotfixrun.so -c powos-tmux-shell` (EngineGuest) |
| 6 | PowOS AI page chat / manager, agent mail, comms, "send to coordinator" | works | via Guest (11-03 nonroot-session) | `PowosAiChat`, `AgentMail`, `AgentsSpool`, `ShellBridge` call `RootedGuest` only | the same calls through EngineGuest once the image is installed; a clear "needs the PowOS Linux image" state before |
| 7 | Android app web windows (floating/tiled Android apps on virtual displays) | works | degraded | `WebWindows` uses `RootShell` for `am start --display`, `move-stack`, input injection, SurfaceFlinger dumps | partly needs-root-by-nature (launching other apps on our virtual display); fallback: open as a normal Android task / Android's own freeform, say so |
| 8 | Performance widget numbers (GPU busy, thermal, /proc/stat) | works | degraded (zeros) | untrusted apps can't read `/proc/stat`, kgsl or thermal zones (SELinux), root or not inside fakechroot | DONE 11-09 (board-nonroot): `android.perf` - CPU load from the cores' cpuidle times and every thermal zone, both readable by any app (razr, unrooted); the GPU's busy % says "root" (kgsl denied) |
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
  Steam (razr 11-14, "steam doesnt launch"): two no-root gaps. (1) `/usr/bin/steam` (steam pkgrel 48): the engine's
  LD_LIBRARY_PATH outranked steamui.so's RUNPATH $ORIGIN -> rootfs SDL3 -> "undefined symbol: SDL_TryLockJoysticks",
  "Failed to load steamui.so"; now the client's dir by host path first (`steam_fakechroot_libs`). (2) the guest env had
  WAYLAND_DISPLAY only: X11 programs got no DISPLAY/XAUTHORITY ("XOpenDisplay failed"); `XwaylandDisplay` reads them from
  KWin's command line as rooted powos-run.sh does (APK). Tests: test-steam-fakechroot.sh, XwaylandDisplayTest.
  Still open for games: pressure-vessel/bwrap (bwrap-shim drops the sandbox), FEX under fakechroot, the window as a
  task (`PowosWebWindows: display helper not started: su` in the razr window log).
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
  Fixed 11-04 (agent/nas-data): build-rootfs.sh writes its images to the NAS (`$POWOS_IMAGES`, tools/data-root.sh)
  and never touches out/powos-rootfs.tar.gz, so the build base stays put.
- **11-04 kwin-363-rollout**: kwin 6.7.5-3.63 published to the [powos] repo (publish-repo.sh: android.pow/apk/repo, every
  package at or above what the repo had - the repo still served kwin 3.3 from 10-13); the rooted phone's install queued
  (verify queue, kwin-install.sh 6.7.5-3.63, idle window). Base + packs rebuilt with kwin 3.63 (build-rootfs.sh,
  POWOS_PUBLISH_PACKS=1, Plasma pinned 6.7.5, KWin/Plasma check passed), published and re-pinned. The new full rootfs is
  kept as out/powos-rootfs-1104-363-full.tar.gz and the Oct-13 rootfs linked back as out/powos-rootfs.tar.gz (the
  sudo-in-the-build-container friction above).
- **Emulator proof, kwin 3.63 base** (pm clear com.powos.app, persist.powos.root=0, APK cea8dfde via emu.sh install; the
  published base downloaded 995 MB, its pacman db has kwin-6.7.5-3.63, KWin caps include `keyboard-live`): System
  Settings from the home dock opens in a PowOS window with no keyboard ("held for the user's tap", mInputShown=false);
  `input swipe 307 398 307 398 150` on its search raises it ("raised by the user's tap", mInputShown=true) and `wifi`
  lands in the field (~/pw/kwin-363-shots/10-12). Seen on the way: right after the first install the app shows the
  Plasma desktop; System Settings launched while the desktop is in front opens maximized inside the desktop (desktop
  consumer, "v2 show on the desktop 0"), and a tap on its search raised no keyboard there (shots 07-08) - a separate
  desktop-consumer keyboard case.
- **Fixed: a launch while the Plasma desktop covers home** (a4a99353, emulator, persist.powos.root=0, APK a4a99353): the
  cause was home's stopped window - no surface, so the web window had nowhere to hang ("home's surface refused a
  child") and KWin's window fell back to a bare PowosWindowActivity task over the desktop (maximized, no PowOS frame,
  no TapKeyboard). Runtime.openRooted now brings home to the front first when web windows take the window and the desktop
  covers home outside desktop mode (WindowTasks.desktopCoversHome; same path rooted). MainActivity in front ->
  apps.launch l:systemsettings: "home to the front", "desktop 0", web window 1 shown 89 ms after open, keyboard "held for
  the user's tap", the tap on its search "raised by the user's tap", `wifi` lands (~/pw/nonroot-desktop-front-shots/03-05).
- **11-04 nonroot-base-signin**: base + packs rebuilt with the AI sign-in in the image (`lib/ai/manager/manager.sh`
  --auth/--signin, exit 4 without a login; kwin 6.7.5-3.63, Plasma 6.7.5, KWin/Plasma check passed), published and
  re-pinned (6ed9d044); Oct-13 rootfs linked back as out/powos-rootfs.tar.gz again (new full rootfs kept as
  out/powos-rootfs-1104-signin-full.tar.gz). Emulator (pm clear, persist.powos.root=0): base 995 MB downloads, AI page
  shows Sign in to Claude; its terminal ran `claude auth login` ("Opening browser...") but no browser came up: OpenSpool
  (files/run/open, powos-android-open's spool) was started only when rooted. Fixed (07df518a, App.kt): started in every
  main process. Then Chrome opens claude.ai/login ("Sign in - Claude"), shots ~/pw/nonroot-base-signin-shots/08-11.
  Account entry is the user's (not done by agents).

## What changed 11-09 (gh#13: making an app on a phone without root)

- `powos app` (`lib/apps/powos-app`): `build --ui` builds the module first when `ui/bindings` is missing (else says why,
  not bun's `Could not resolve "../bindings"`); `check` / `runtime` / `services` print a capability table (the baked
  tree's sibling `powos-runtime` is found off PATH, no execvp traceback); a UI-only app (`"module": null`) installs
  without SpacetimeDB, the registry row optional without root (the launcher lists files/apps itself). Tier1
  `test-app-noroot-cli.sh`.
- Base image: `roots spacetimedb` (out of the apps pack); `apps/registry` in `apps/bundled.list`, so
  `powos-noroot-services` publishes `powos-registry` on first start. Tier1 `test-noroot-app-base.py`. Needs a re-split
  + publish of the base image to reach phones.
- `linux/EngineHome.kt` (run by `EngineServices`): the image's `~/.config/omalauncher/widgets` and
  `~/.local/share/powos/apps` are symlinks to the app's files/widgets and files/apps (passed through fakechroot by
  SessionService's `ARCH_EXCLUDE_EXTRA`), and owl-check/owl-send/owl-recon are in `/usr/local/bin`. JVM `EngineHomeTest`.
- Still open: no public module builder (a module app still needs `powos app builder` or cargo + wasm32 on the phone),
  example App API specs for `powos compose blocks`, and `.preview/` PNGs on no-root.

## 11-09 (board-nonroot): what an unrooted app can read, and the base image's gaps

Read on the razr fold (unrooted, `run-as com.powos.app` = the app's own SELinux domain), base image only:

| read | result |
|---|---|
| `/proc/stat`, `/proc/loadavg`, kgsl `gpu_busy_percentage` / `temp` | denied |
| every `/sys/class/thermal/thermal_zone*/{type,temp}` (cpu-*, gpuss-*, back_temp, battery, ...) | readable |
| `/sys/devices/system/cpu/cpu*/cpuidle/state*/time`, `cpufreq/scaling_cur_freq` | readable |
| `/usr/lib/spacetimedb/2.12.0/` in the base | **empty** (the package went to the apps pack): no SpacetimeDB, so no island DBs, no agents board |
| `/usr/bin/tmux` in the base | **missing** (pack): powos-tmux-shell falls back to a bare shell, no `terms` list |
| `/usr/bin/gh` | **not in the image at all**: `powos login github` / `powos self push` can't sign in |

Changes:
- `widgets/runtime/Perf.kt` + `WidgetServices.android("perf")`: `source p = android.perf every 5s` (`{cpu, gpu,
  gpuNeedsRoot, cpuTemp, gpuTemp, skinTemp, battTemp}`); `55-performance.owl` 1.2: its Linux read is `optional` and
  writes -1 for what it can't read (a missing word shifted every later number), each number falls back to
  android.perf, the GPU says "root" where nothing can read it. JVM `PerfTest`, `ExamplesTest.performanceWorksWithoutLinux`.
- `rootfs-packs.conf`: `roots spacetimedb github-cli tmux` (spacetimedb left the apps pack line);
  `install-powos-android.sh` installs github-cli. Takes effect with the next base build + publish; a device on the
  old base gets SpacetimeDB/tmux by adding the apps pack (Settings > Storage).
- `FreeformTasks.applyHomeFocus`: a refused home-focus WindowContainerTransaction (no MANAGE_ACTIVITY_TASKS without
  root) is asked once, not on every windows/typing change (136 lines in the razr's window-log.txt).
- Lock face on the razr: 3 of 3 starts in the 11-09 logcat allowed (`BAL_ALLOW_NON_APP_VISIBLE_WINDOW`: the overlay
  grant + a visible PowOS overlay window). A screen-off with no PowOS overlay showing can still be refused (the 11-08
  `BAL_BLOCK`, result 102): `LockFace.show` (no root) posts the same face as a silent full-screen-intent notification
  when it isn't up 400 ms later - only where Android lets PowOS use full-screen intents (Android 14+ special access;
  else a heads-up per screen-off, so nothing is posted and the log says so); cancelled as the face shows / on unlock.
- **adb server on 5037 (found by board-close-waiting)**: any `adb` call in the image (powos android, powos-deviced,
  scrcpy) auto-starts `adb -L tcp:5037 fork-server` - on Android's shared loopback every app could drive it.
  `SessionService.LOOPBACK_PORTS` is now `3410,3411,5037`: libpowosloopback binds it as `files/run/loopback/5037.sock`
  (0600) and the image's adb clients reach it unchanged. An adb server already running keeps its TCP port until the
  session restarts (the APK update does that). Check: `tools/phone/verify/nonroot-ports.sh` (from the Mac, razr) now
  FAILs on any TCP 3410/3411/5037 listener, on an adb server (`host:version` -> OKAY) on ANY port of PowOS's uid, and
  on a token-less 2xx from any other listener. 11-09 02:55 before the fix: FAIL (5037 listens, answers OKAY); also
  listening: 3416 (device agent, paired token), 40777 (Claude Code's local server, 404 without its state).
- **Every fixed loopback port private (11-09, nonroot-ports)**: instead of growing the list one hole at a time,
  `LOOPBACK_PORTS` is `3410,3411,5037,loopback`: with `loopback`, libpowosloopback turns ANY bind of a fixed port on
  127/8 or ::1 in the image into `files/run/loopback/<port>.sock` (0600; a live socket isn't taken over - EADDRINUSE;
  dual-stack 127.0.0.1+::1 on one port is a HACK left at that), and a loopback connect uses the socket when one
  exists, else plain TCP (Android's own ports, programs without the preload, a stale file). Left on TCP by design:
  port 0 (the kernel's pick, handed to someone outside - Claude Code's OAuth callback for the phone's browser) and
  wildcard/LAN binds (meant for the network, with their own auth). In-app listeners: LoopbackGate (token, 403
  without), the device agent 3416 (TLS + pairing token). `nonroot-ports.sh` now FAILs on any PowOS-uid listener that
  doesn't answer a token-less GET with a 4xx (2xx/3xx/5xx, a raw-protocol banner or silence), and on 3416 answering
  plain HTTP. razr 11-09 (old APK, old base without SpacetimeDB): ports half passes (only 3416 listens; 3410/3411/5037
  refused); services-up half SKIPs until the new base + APK. Known gap: a static/Go server (no libc, no preload)
  binding loopback stays TCP - the script catches it.
- **No services on a base without SpacetimeDB**: `EngineServices.state` said "missing" and kicked nothing, so the App
  API (python3 only) never started either; now the starter runs in "missing" too (every 10 min at most) and starts
  what the image has. SpacetimeDB itself comes with the next base (roots above) or the apps pack.

## What changed 11-10 (nonroot-islands)

Razr check (read-only adb, APK 2026.11.09-2257, base image from before 11-09): no island had anything because the APK
had **no** `assets/apps/` and no `assets/powos-noroot-services` - `files/apps` and `run/powos-bundled` empty, no
`/var/log/powos`. Cause: `tools/warm-builder.sh` mirrors only `targets/android/app` and `shell/` into `/work`, and
`copyApps` read `../../../apps` and `../../../lib` from there (absent: Gradle's `from()` skips it silently). Every
warm-built APK since 11-04 shipped without them.

- `build-app.sh` stages each `apps/bundled.list` app (manifest, `out/ui`, `module.wasm`, by its id) and the starter in
  `targets/android/app/app/bundled-apps/` (gitignored, inside the Gradle project: every builder sees it); `copyApps`
  packs that; the build fails (exit 7) when the APK lacks any of them.
- `bundled.list` takes another repo's app folder by path: `~/Projects/lights` (local.lights). Its `local-lights` DB is
  published with the others by the starter; its bridge calls go through the page's net (no Linux).
- Agents: the widget (`shell/ui/agents.tsx`) reads `AgentsSpool`, which already runs without root
  (`App.startEngineWatchers`) on `files/run/agents`. Missing was the reporter: the image has `/usr/lib/powos/ai/agents`
  but no claude hooks in `/root/.claude/settings.json`, so nothing ever started `powos-agentsd`. `powos-noroot-services`
  now installs the hooks once (`install-hooks.py`, as `powos-deploy.sh` for ~powos) and starts `powos-agentsd`
  (`XDG_RUNTIME_DIR/agents` = `files/run/agents`). Test: `test/tier1/test-noroot-agents.py`.

| island | needs | status 11-10 |
|---|---|---|
| What needs me | APK assets only (no Linux) | works once an APK from this branch is installed |
| Agents | APK starter + the image's `/usr/lib/powos/ai/agents` (razr has it) | hooks + agentsd from the starter; rows appear with the first claude run in the image |
| Pet | APK module + SpacetimeDB in the image | razr's base has no SpacetimeDB (from before 11-09): "needs a newer image" until it's updated |
| Lights | APK UI + module (bundled now); SpacetimeDB for its key/prefs | as Pet for its saved key; UI ships |


## 11-10 (board-nonroot): landing and verification follow-up

- Islands `e47c8e59` / `bc29fe33` are already ancestors of integration; no duplicate cherry-pick. APK staging and
  the Agents reporter remain intact. Needs APK plus the newer no-root base (SpacetimeDB for Pet/Lights).
- Claude's installer was already in the image recipe (`bc051d1f`) but silently tolerated failure. It now requires
  successful download/install and an executable; `units/phone/claude-code.json` is installed into the image's registry.
  Base splitting keeps the native install. Login shells parse the existing endpoint.conf too (not just the manager),
  so enrolled fleet devices use claude-auth.pow and their existing enrollment token, never a second login. No token
  is baked into the image or replaced. Endpoint writes skip sudo when already root. Existing standalone behavior is
  unchanged; the Razr must retain/adopt its fleet enrollment when the new base is synced.
- The 105000% / 0 MHz bug already has the 11-09 sentinel/android.perf fix (`5dfc6115`, `81c31afc`, `723ec6d3`).
  The remaining check was also looking only for .203 and forwarding through a different adb server: fixed with the
  Mac-paired TLS serial and a local CDP transport. Last read-only observation: APK 2026.11.10-0353, Razr at .18,
  Motorola CustomizationPanelLauncher foreground, no PowOS WebView endpoint: SKIP, not a pass. No input injected.
- Validation: seven tier1 suites on pow58 (ai-endpoint, cdp-home, cdp-warm, check-shell-pitfalls, noroot-agents,
  noroot-app-base, units-registry); JVM PerfTest and ExamplesTest via jvm-offload on pow58 passed. Live islands,
  Claude version/proxy auth, and widget readings still need post-build verification; do not close from these tests.
- Read-only widget queue after deployment: `tools/phone/verify/queue.sh add widgets-etc-don-t-work-in-powos-on-a-non-rooted tools/phone/verify/widgets-nonroot.sh`.

## 11-11 (nonroot-close): Claude image proof on the razr, widget check, VPN pairing

- **Razr, read-only (adb TLS `adb-ZY22MQL54Q-XpSn2g`, now at 192.168.50.18; `run-as com.powos.app`)**: APK
  2026.11.11-0354; Linux installed 11-09 from the base published 11-07 (predates `317536f0`); powos-core
  4103.gba93f67eb (repo has 4182.g317536f0a). `/root/.local/bin/claude` -> 2.1.319 is there (the manager's first-use
  install, 11-09 00:45), but no `/etc/profile.d/45-powos-claude-endpoint.sh`, no `/etc/powos/ai/endpoint.conf`, no
  `/etc/powos/units.d/claude-code.json`.
- **Gap found**: a new base is for fresh installs only (lib/phone-update.sh), and powos-core did not carry the profile.d
  file or the unit (phone-files.sh mapped only session/shims/play; `config/`, `units/` weren't archived). So the 11-10
  fix could never reach the razr. Fixed: phone-files.sh also maps `"$P/current/src/<config|units>/..."` install lines
  (as `../../<path>`), build-powos-core.sh archives `config/etc/profile.d units/phone`; test-phone-update.sh checks both.
- **Proof still missing**: on the razr after powos-core > 4182 lands (session start or Settings > check): the two files
  present; `endpoint.conf` written by enrollment (`powos devices ai-apply`, the razr's fleet enrollment - not
  re-enrolled here); a login shell's `claude --version` and one proxied reply via claude-auth.pow (no own login). The
  base rebuild (build-rootfs.sh) is only for fresh installs (S25 etc.).
- **VPN pairing** (board devices-pairing-doesn-t-discover-over-vpn): Add a device merges the realm registry (agent
  addresses) with mDNS; `shell/test/devices-discover.test.ts`. Phone agents have no realm endpoint yet, so the phone's
  own Devices app falls back to the address field over the VPN.

## What changed 11-10 (nonroot-appmaking: making apps and SpacetimeDB web apps without root)

Razr probe (read-only, `PROBE=1 tools/phone/verify/nonroot-appmaking.sh`, APK 2026.11.09-2349, base from before 11-09):
`new` yes, `build --ui` yes (bun), **module build no** (no toolchain, no builder), **install no** (no `spacetime`:
pacman lists `spacetimedb-2.12.0-1` as installed but its files were split into the apps pack the razr never added, so
no package update ever brought it back), services yes.

- **An old base catches up by package, not by re-download.** `lib/phone-base-sync.py` (in powos-core with
  `rootfs-packs.conf` + `split-rootfs.py`) applies today's split rules to the phone's own pacman db and names the base
  packages whose files are mostly missing (a whole package left in a pack, never one file a script removed) and roots
  the image never had. `phone-update.sh`'s new `base` step (after powos-core, so new rules arrive first) reinstalls
  them: [powos]'s own (spacetimedb) from [powos], Arch's only at the installed version (no `-Sy`, no partial upgrade),
  the rest is left for its pack. Runs automatically at every session start and with the app's update check; progress
  through `powos-progress base-sync` (a notification even from the session-start run) and "Completing the Linux
  image" / "Adding to the Linux image: ..." in the PowOS updates notification. Cached on the pacman db + rules + packs.
  On the razr's real db it names spacetimedb, tmux, gnome-keyring (+ deps), btop/fzf/gum/fastfetch, github-cli.
  Tests: tier1 `test-phone-base-sync.py`, `test-phone-update.sh` (base cases), JVM `PowosUpdatesTest`.
- **Module builder: the `dev` pack carries the Rust -> wasm toolchain** (`targets/android/tools/app-toolchain.sh`,
  run by install-powos-android.sh into `/opt/powos-rust`, `pack dev path opt/powos-rust/*`): rustup's stable + wasm32
  (Arch Linux ARM's rust has no wasm32 std) and the template's crates (spacetimedb 2.12 + deps) fetched and compiled
  once. Measured in an arm64 container: 805 MB unpacked / 288 MB gz; a new app's first module build **offline in
  7 s** (only its own crate compiles). `powos app build` uses it (`--offline` first, then the network only for crates
  the app added) and seeds `~/.cache/powos/app-target` from it. Why the pack over an offloaded build: it works offline
  and on a phone that isn't enrolled, needs no new PowStation service or credentials, and the ssh builder
  (`powos app builder user@host`) stays as the second choice. No silent download: without the pack and a builder,
  `powos app build` shows both choices; a terminal asks y/N, the AI (manager) passes `--add-toolchain` /
  `POWOS_APP_ADD_TOOLCHAIN=1` only on the user's yes; `powos-pack need dev` shows the download's progress.
- `powos app remove` of a UI-only app works with no SpacetimeDB on a phone without root (it died "no spacetime CLI").
- Check: `tools/phone/verify/nonroot-appmaking.sh` (from the Mac, razr): base, widget (UI-only island), preview, new,
  module, install (DB + files/apps + powos-registry), stdb (reducer -> table, live subscription, anonymous SQL writes
  refused on the app DB and the registry), persist (RESTART=1), App API, edit (page -> `app ui`, module -> `publish`,
  data kept), cleanup. Runs each step in the image through run-as + liblotfixrun with the script on stdin.
- Left: the razr needs powos-core from this branch (base step) + an APK/base built with the dev pack's toolchain;
  `.preview/` sheets still need docker (W3); `compose blocks` example specs (C1).
- **11-14 (razr, no root): the toolchain moved to its own `rust` pack**; the dev pack published 11-07 predated it, and a
  phone that had added dev keeps its install marker, so `powos-pack need dev` never brought /opt/powos-rust ("module: no
  Rust toolchain here"). `pack rust path opt/powos-rust/*`; `powos app build` offers/adds whichever of dev + rust is
  missing (only rust on the razr). Re-measured (rustc 1.100.0): 815 MiB / 284 MB gz; build-rootfs.sh refuses to publish
  packs with an empty rust pack. **Composing needs no Rust at all now**: powos-core carries the shared composed module
  prebuilt (apps/build.sh composed -> /usr/lib/powos/apps/composed: source, module.wasm, its stamp, bindings), which
  `powos compose` copies into every widget. `powos app new --template ui`: page + widget, `"module": null`, no bindings.


## 11-14 (noroot-home-adb): `powos android` without root - the app hands over Wireless debugging

- **Seen (razr no-root log, 11-14):** the Linux side had no adb at all - lib/android.sh only knew rooted mode's
  127.0.0.1:5555, the app handed over no port or key, and the image's adb has no mDNS under fakechroot; a port scan
  found adbd's TLS port but the image's key was never paired (`offline`). So no screenshot/input/dumpsys/logcat/am/
  settings for the manager or agents without root.
- **Now:** the app's `AdbLink` (engine, SessionService, no-root only) finds this phone's own `_adb-tls-connect._tcp`
  with Android's NsdManager (services on its own addresses only - the LAN's other adbds are skipped) and writes
  run/adb-link (`package`, `wireless on|off`, `keep on|off`, `connect 127.0.0.1:<port>`); refreshed at start, on a
  new network (3 s later) and on request (`android-request adb-link`). `powos android link` pairs the image's key
  once: the app looks for the pairing dialog's port and asks for the code in a notification (RemoteInput), hands both
  over in run/adb-pair (read once, deleted), the Linux side runs `adb pair`, connects, `pm grant`s
  WRITE_SECURE_SETTINGS and asks `adb-link keep on`: from then on the app turns Wireless debugging back on after a
  reboot or a Wi-Fi change (as Shizuku) and lib/android.sh asks for the new port when the old one doesn't answer.
- lib/android.sh `_android_pick`: 5555 (rooted) first, then the link; new verbs input/logcat/dumpsys/am/pm/settings/
  cmd/getprop/shell/link. `powos status` shows the no-root link. Tests: AdbLinkTest (JVM), test-android-link.sh.
- Left: a device check on the razr after the APK ships (pair once by hand: `powos android link`).
