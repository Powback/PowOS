---
name: powos-games
description: Use for games on the PowOS phone (OnePlus Open) - Steam/Proton under FEX, Broforce runs and checks, Xwayland's KGSL patches (xwayland-kgsl), the phone kernel build + fastboot test boot + flash/rollback, and the dma-buf sync_file backport. Learned 2026-10-20..22.
---

Access, idle windows and on-device rules: the powos-phone and powos-verify skills. This is the games/kernel part.

## The stack a Proton game runs on
- Steam = native ARM64 (`~/.local/share/Steam`). Game: steam-launch-wrapper -> reaper -> FEX `fex-compat-tool` -> SLR_4
  `_v2-entry-point` -> Proton Experimental (CompatToolMapping in config.vdf: 274190 Broforce, 294100, 346010).
- Vulkan: DXVK on Fedora's x86 Turnip 26.2 inside FEX's RootFS (`/usr/share/guestos/fex-mesa` -> Fedora_44);
  Steam's FEX has the Vulkan thunk OFF for games (compatdata/<id>/fex-emu/Config.json, empty ThunksDB).
- X11: Xwayland `/usr/local/bin/Xwayland` = package `xwayland-kgsl` (targets/android/pkgs/xwayland-kgsl), glamor on
  KGSL surfaceless, no DRI3 syncobj. KWin output `anland-1` follows the Android surface (one mode, resized on fold/rotate).
- Logs: Steam `logs/{console_log,gameprocess_log,compat_log}.txt`; `/tmp/fex-compat-tool-<pid>.log`; session
  `/run/powos-app/hyprland.log` (`Xwayland KGSL:` stats); Proton: `PROTON_LOG=1` in user_settings.py -> `~/steam-<id>.log`.

## Run and check Broforce (tools/phone/verify, header of each says where it runs)
- `bf-start.sh` / `bf-stop.sh` (session user via powos-run.sh): `powos sleep never steam` + `steam steam://rungameid/274190`;
  stop closes game + Steam and removes the never entry. `pgrep -f Broforce_beta.exe` also matches the launch chain:
  wait for the X window `"Broforce"` (xwininfo, DISPLAY=:0, XAUTHORITY from Xwayland's `-auth` arg) - ~1-2 min.
- Frame numbers: `bf-pacing.sh [base|cap60|fifo|nolatency]...` (~4 min/mode; queue it): 30 s SurfaceFlinger presents
  (bf-present.sh) + 20 s screenrecord -> bf-frames.py: fps, frame-time percentiles, % at 16.7 ms, dup/stale frames,
  window vs screen, activity in front. Artefacts ~/.cache/powos-verify/bfp-<date>/<mode>/.
- KWin opens every X/Wayland toplevel (the game too) as its own Android task, `PowosWindowActivity` (WindowTasks);
  never `am start andro.marchy.MainActivity` to "show the game": that's the PowOS home/AI page.
- Output anland-1 runs at 119.97 Hz unfolded (2268x2440): a 60 fps game = every 2nd vsync. CPU governor: `uag`.
- Launch-option prefixes run INSIDE SLR_4 under FEX: no xrandr/python3, only `python3.13` (ctypes libX11); /home shared.
- `bf-run.sh` (~10 min, memory + SF pacing + KGSL stats): `queue.sh add <board-task> bf-run.sh`, don't wait.
- Xwayland's copy of a window: `ffmpeg -f x11grab -window_id <id> -i :0 -frames:v 1`. Half-drawn metric: dark pixels `c<30 && min4neighbours > c+50`.
- Render bisect: `bf-checker.sh [variant]...` (~4 min each; TU_DEBUG via Proton user_settings.py, or dxvk.conf): 75 s of
  loading+menu, X copy + screencaps -> black-checker score (bf-checker.py), menu fps, DXVK log (DXVK_LOG_PATH).
- Unity prefs: pfx `user.reg` `[Software\\Free Lives\\Broforce]` `Screenmanager Resolution Width/Height`, `Is Fullscreen mode`.
- Steam login: a session crash can set `loginusers.vdf` AutoLogin 0 ("Service Unavailable") -> 1 with Steam off.

## Freeze + instant resume (Steam and its game; docs/UNIFIED-SLEEP.md, lib/apps/powos-sleep-gui)
- cgroup v2 freezer works on the phone's 5.15 (/sys/fs/cgroup/powos/sleep/<key>, powos-sleepd as root); SIGSTOP not used.
- units/phone/steam.json `sleepBusy.games: "pause"`: a game's windows map to Steam's root pid (app_pid: an ancestor's
  cmdline has `SteamLaunch`), so the game out of sight 15 s = Steam's whole tree frozen (game inside it). Start grace
  2m also from the game's reaper; the game's audio stream is ignored. Xwayland/KWin are CORE (never frozen).
- Launch path: /usr/bin/steam (pkg `steam` pkgrel 20) on `steam://rungameid/<id>` with a running `reaper SteamLaunch
  AppId=<id>` -> dbus-send `dev.powos.Sleep.Gui.Resume <id>` (thaw + raise via one-shot KWin script) and exit 0; Steam
  never sees the launch. So a Broforce left running makes the next `bf-start.sh` a resume, not a cold start:
  bf-stop.sh first for cold-start/Proton checks.
- Android launch paths (all resume, none cold-starts a running game): drawer/home/shortcuts = Runtime.openRooted ->
  `powos-open-task --app-id <.desktop id> -- steam steam://rungameid/<id>`; games widget = Runtime.launch(command)
  routes a rungameid command (rooted) to openAsTask with `--app-id steam_app_<id>` (no desktop pop). powos-open-task
  parses the appid (command or steam_app_<id> id), calls Resume first and shows the window it names as a task; else
  matches class steam_app_<id> (Proton's WM_CLASS) and waits 150 s for a cold start's window. Recents = the task's
  focus -> KWin activates -> sleep-gui thaws on focus (no code). Check: `bf-launchpaths.sh` (installs powos-open-task).
- CLI: `powos game <name|appid> freeze|thaw|status` (lib/game.sh, any installed Steam game; not the mods registry);
  `powos-sleep-gui resume|sleep <x>`. Watcher log `/run/powos-app/powos-sleep-gui.log` ("resumed", "frozen in").
- Ship: build-pkgs.sh steam needs out/pkgs/{fex-emu,gtk2}*.pkg (copy from a worktree that has them) and
  pkgs/steam/sysvipc-emu.tar.gz (sha 205ee32a, gitignored). sleep-gui: install to /usr/lib/powos/apps, restart it as
  powos (`setsid -f powos-sleep-gui >> /run/powos-app/powos-sleep-gui.log`; TERM thaws everything it froze).
  /usr/lib/powos/game.sh is the facade on the phone.
- Measure: `queue.sh add <task> bf-resume.sh` (cold vs thawed start to first new frame via x11grab framemd5, Steam
  tree CPU awake-hidden vs frozen, X/KWin latency while frozen, Steam connection_log after a 90 s freeze).

## Causes found (don't re-investigate)
- Session killed while gaming: Xwayland dma-buf leak via KGSL forced commits (fixed c8ab446, xwayland-kgsl 0007).
- Controller dead in games: Steam's virtual pad /dev/input/eventN is root:1004; PowOS `input` group = Android gid 1004
  (powos-deploy.sh). Android also reads Valve pads: MainActivity drops their key events.
- Stale/half-drawn frames: KGSL has no implicit sync; Mesa's X11 WSI never waits for Xwayland (x11_needs_wait_for_fences).
  Fix = kernel dma-buf sync_file ioctls (Mesa then imports its render fence into the dma-buf) + xwayland-kgsl 0008 (Present
  copy waits on the exported read fence; glFinish before idle). 0008 logs ENOTTY once on a kernel without the ioctls.
- Resolution: Unity 2017.4 starts at its saved size (user.reg 1116x2440, the folded cover) and doesn't follow the output.
  Fix: `targets/android/steam/unity-screen` as the game's Steam LaunchOptions (`~/.local/share/powos/unity-screen
  %command%`) appends `-screen-fullscreen 1 -screen-width W -screen-height H` = the X root size at launch. Set with
  `unity-screen --install <appid>` / `--remove` in the session with Steam OFF (it rewrites localconfig.vdf on exit;
  backup localconfig.vdf.powos-bak). Installed for 274190. Fold/rotate mid-game: see Fold below.

## Fold mid-game (kwin 3.21 = pkgs/kwin 0017; check: `queue.sh add --close <task> bf-fold.sh`)
- Before: a fold resized the game's full-screen X window to anland-1's new size (Unity kept its own) and the window
  task (patch 0013) cropped it. 0017: exported full-screen windows keep their geometry (QObject property
  `powosKeepFullScreenGeometry` -> checkWorkspacePosition returns; ABI unchanged) and AnlandWindowTask::scale/viewport
  fit them, centred, letterboxed (touch too); scale 1 when buffer == window. Every full-screen task letterboxes now.
- bf-fold.sh: pacman -U (rollback tar /var/cache/powos/kwin-<ver>-files.tar), `android-request power logout` (never
  with Broforce up), state 3->0->+25s->3. kwin_wayland: pgrep as root; "libkwin (deleted)" in maps = old one running.
- Logcat and powos-sleep-gui.log don't survive a reboot; hyprland.log is appended across sessions (no timestamps).

## Kernel (targets/android/kernel, docs/PHONE-KERNEL-CONTAINERS.md)
- Build: `STOCK_BOOT=targets/native/backup/8e5d600d/boot_b.img JOBS=12 ./build-containers-kernel.sh` (~2 h, LTO link
  single-threaded; gitignored inputs: copy from a checkout that has them) + `out/vendor-modules`. Volume `powos-gki-cache`
  = clang + tree + build dirs; patches = targets/native/patches/gki + kernel/patches.
- Quick compile check of one file: worktree of the cache tree, apply all patches, `make O=<dir> drivers/dma-buf/dma-buf.o`.
- Checks the script runs: config diff vs running, pahole layout diff (`OK - every shared type has the same layout`),
  kmi-check.py vs vendor modules (`OK - the modules accept this kernel`). Module.symvers identical = old modules load.
- patches/0004 = DMA_BUF_IOCTL_EXPORT/IMPORT_SYNC_FILE backport (5.15 dma_resv excl/shared). Flashed to boot_b
  2026-10-22 (boot-powos-dmabuf.img d969681e, 5.15.180 #5). Test: a dma-heap buffer + both ioctls from Python as root.
- Test boot (writes nothing, USB): `adb reboot bootloader`; `~/Library/Android/sdk/platform-tools/fastboot -s 8e5d600d boot
  out/<img>` (not Homebrew's). Verify uname -v, root, kwin/Xwayland/plasmashell, 549 modules, 17 inputs, adb over VPN.
- Flash: `fastboot -s 8e5d600d flash boot_b out/<img>` + reboot (USB). Only boot_b; never set-active slot a (older firmware,
  no _a dynamic partitions - no safe A/B fallback). Needs the user's explicit yes.
- Rollback: flash `~/Projects/PowOS/backups/oneplus-open/2026-10-22-before-dmabuf-kernel/boot_b.img` (hang: power+vol-down).

## Xwayland package
- `targets/android/build-pkgs.sh xwayland-kgsl` (BUILD_ON_ROOTFS: needs targets/android/out/powos-rootfs.tar.gz).
  Install: .pkg.tar.xz into PowOS, `pacman -U` (root.sh); next session start. Smoke test: the binary as `:7 -rootless`.
- Patches 0001-0004 lfdevs (Andromarchy pin), 0005/0006 Present hangs, 0007 leak, 0008 fence wait. HACK in 0007 (registry).
