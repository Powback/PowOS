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
- `bf-start.sh` / `bf-stop.sh [--steam]` (session user): never-sleep + `steam steam://rungameid/274190` / close the game
  (Steam stays resident, frozen out of sight: the next launch skips Steam's ~22 s start); `--steam` only for cold checks.
- Close = `powos game <name|appid> stop [--steam]` (lib/game.sh `_game_steam_close`): game's chain (reaper trees +
  environ SteamAppId/STEAM_COMPAT_APP_ID/WINEPREFIX = also orphans, wineserver) TERM, KILL at 2 s; Steam: Wake, `timeout
  steam -shutdown`, KILL at 6 s, one sweep after. Worst case 6.6 s (stubborn client + hanging forwarder). The old
  per-process pgrep loop took 16.5 s and bf-stop's `timeout 15` left Steam running: keep the wait loop to /proc stats.
  /usr/bin/steam execs ./steam (no steam.sh restart loop). `pgrep -f
  Broforce_beta.exe` matches the launch chain too: wait for X window `"Broforce"` (XAUTHORITY = Xwayland's `-auth`).
- Frame numbers: `bf-pacing.sh [base|cap60|fifo|nolatency]...` (~4 min/mode; queue it): 30 s SurfaceFlinger presents
  (bf-present.sh) + 20 s screenrecord -> bf-frames.py: fps, frame-time percentiles, % at 16.7 ms, dup/stale frames,
  window vs screen, activity in front. Artefacts ~/.cache/powos-verify/bfp-<date>/<mode>/.
- KWin shows every X toplevel (the game too) as its own Android task (PowosWindowActivity); never `am start andro.marchy.MainActivity` (PowOS home).
- anland-1 119.97 Hz unfolded (2268x2440): 60 fps = every 2nd vsync; governor `uag`. `bf-run.sh` ~10 min (memory,
  SF pacing, KGSL stats). Launch-option prefixes run INSIDE SLR_4 under FEX: only `python3.13` (ctypes libX11).
- Xwayland's copy of a window: `ffmpeg -f x11grab -window_id <id> -i :0 -frames:v 1`; half-drawn = dark px `c<30 && min4nb>c+50`.
- Render bisect: `bf-checker.sh [variant]...` (~4 min each; TU_DEBUG via Proton user_settings.py / dxvk.conf): black-checker score, menu fps, DXVK log.
- Unity prefs: pfx `user.reg` `[Software\\Free Lives\\Broforce]`. Steam login: a session crash can set loginusers.vdf
  AutoLogin 0 ("Service Unavailable") -> 1 with Steam off.

## Freeze + instant resume (Steam and its game; docs/UNIFIED-SLEEP.md, lib/apps/powos-sleep-gui)
- cgroup v2 freezer works on the phone's 5.15 (/sys/fs/cgroup/powos/sleep/<key>, powos-sleepd as root); SIGSTOP not used.
- units/phone/steam.json `sleepBusy.games: "pause"`: a game's windows map to Steam's root pid (app_pid: an ancestor's
  cmdline has `SteamLaunch`), so the game out of sight 15 s = Steam's whole tree frozen (game inside it). Start grace
  2m also from the game's reaper; the game's audio stream is ignored. Xwayland/KWin are CORE (never frozen).
- Launch path: /usr/bin/steam (pkg `steam` pkgrel 21) on `steam://rungameid/<id>` with a running `reaper SteamLaunch
  AppId=<id>` -> dbus `dev.powos.Sleep.Gui.Resume <id>` (thaw + raise, one-shot KWin script), exit 0; Steam never sees
  it. A Broforce left running makes the next launch a resume: bf-stop.sh first for cold-start/Proton checks.
- Android paths (all resume a running game): drawer/home/shortcuts = Runtime.openRooted -> `powos-open-task --app-id
  <.desktop id> -- steam steam://rungameid/<id>`; games widget = Runtime.launch -> openAsTask `--app-id steam_app_<id>`.
  open-task: Resume first, shows the named window as a task; else class steam_app_<id>, waits 150 s for a cold start.
  Recents = task focus -> KWin activates -> sleep-gui thaws on focus.
- CLI: `powos game <name|appid> freeze|thaw|status` (lib/game.sh; /usr/lib/powos/game.sh on the phone),
  `powos-sleep-gui resume|sleep <x>`. Log `/run/powos-app/powos-sleep-gui.log` ("resumed", "frozen in", "not frozen").
- Ship: build-pkgs.sh steam needs out/pkgs/{fex-emu,gtk2}*.pkg + pkgs/steam/sysvipc-emu.tar.gz (sha 205ee32a,
  gitignored). sleep-gui: install to /usr/lib/powos/apps, restart as powos (`pkill -TERM -f bin/powos-sleep-gui$`,
  `setsid -f powos-sleep-gui >> /run/powos-app/powos-sleep-gui.log`; TERM thaws everything it froze).
- Checks (`queue.sh add --close <task> bf-launchpaths.sh` / `bf-resume.sh`): steps in bf-lib.sh, each on the status
  pill (rewrites verify-status.json's name) and asserted, else `FAIL <step>: <evidence>`: launch = open-task's path,
  X window IsViewable + "powos-open-task: task"; freeze = cgroup.freeze 1 + events "frozen 1" + every task of the
  reaper's tree in that cgroup + 0 CPU ticks in 2 s; resume = out of the cgroup, same reaper, window mapped, a new
  x11grab frame <= RESUME_MS (3000). A touch / stop closes what the check started (exit 3). Launch chains outside
  Steam's tree (ppid 1, a dead Steam's) are killed first: never frozen or resumed, they hold the prefix.
- Never auto-frozen before its first window (sleep-gui GAME_WINDOW_S 600): a cold start outlasts the 2 min grace.
- Launch time by stage: `bf-coldstart.sh [cold|steam|fexcache]...` -> "STAGES" lines (tap->reaper->pv->wineserver->exe->
  window->frame, ms). fexcache = FEX_ENABLECODECACHINGWIP=1 via Proton user_settings.py (removed after) + FEXOfflineCompiler.
- Baseline 2026-10-23 cold (2 runs, Steam off): Steam web UI 1-4 s, reaper 22-26 s, pv-adverb 26-29 s, wineserver 32 s;
  those runs then died (zeroed registry, see Causes). bf-coldstart FAILs at once when the chain ends without a window.
- Still to measure (bf-coldstart.sh cold steam fexcache fexcache under the verify lock): warm-Steam launch, FEX code
  cache, pressure-vessel locale-gen (game env has LC_ALL=C + LANG=en_CH.UTF-8: PRESSURE_VESSEL_GENERATE_LOCALES=0 in
  /usr/bin/steam would skip it; pv->wineserver was ~3 s total). Persistent wineserver: Proton's waitforexitandrun waits
  for the prefix's old wineserver to exit, so a lingering one delays a launch; a resident (frozen) game is the instant path.
- adb.sh mounts each pushed path's dirname: a path with `..` pushes nothing ("cannot stat") - resolve it first.

## Causes found (don't re-investigate)
- Every launch dies ~10-16 s into Wine, no window, gameprocess_log "exit code -1" (2026-10-23): the prefix's
  pfx/{system,user,userdef}.reg were all NUL bytes (size kept): wineserver saves them without fsync and the phone
  rebooted ~1 min after a save (f2fs /data). Check: `head -c 23 pfx/system.reg` != "WINE REGISTRY Version 2". Fix:
  /usr/bin/steam (pkgrel 21) `reg_guard` at each Steam start (no Steam running): fsynced copy of every prefix's good
  set in compatdata/<id>/powos-reg, restored over a broken one; no copy -> broken files to powos-reg-broken/ (+ log),
  creation_sync_guard removed so Proton re-copies its default registry (drive_c, game saves kept; Wine keys reset).
- A cold Steam runs the game's install script evaluator first through the same `reaper SteamLaunch AppId=<id>` /
  Proton chain (console_log "Running install script evaluator", 15-40 s; not in gameprocess_log). Its end is not the
  launch dying: bf-coldstart took it for one and its close killed the real launch ("exit code -1" 1 s later). A launch
  ended = gameprocess_log "Remove <id> from running list" after the tap.
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
