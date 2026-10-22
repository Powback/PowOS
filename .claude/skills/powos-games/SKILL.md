---
name: powos-games
description: Use for games on the PowOS phone (OnePlus Open) - Steam/Proton under FEX, Broforce runs and checks, Xwayland's KGSL patches (xwayland-kgsl), the phone kernel build + fastboot test boot + flash/rollback, and the dma-buf sync_file backport. Learned 2026-10-20..22.
---

Access, idle windows and on-device rules: the powos-phone and powos-verify skills. This is the games/kernel part.

## The stack a Proton game runs on
- Steam = native ARM64 client (`~/.local/share/Steam` in PowOS). A Windows game launches as
  steam-launch-wrapper -> reaper -> FEX-Emu `fex-compat-tool` -> SteamLinuxRuntime_4 `_v2-entry-point` -> Proton Experimental.
  CompatToolMapping (config.vdf) forces proton_experimental for 274190 Broforce, 294100, 346010.
- Vulkan: DXVK on Fedora's x86 Turnip 26.2 inside FEX's RootFS (`/usr/share/guestos/fex-mesa` -> Fedora_44);
  Steam's FEX has the Vulkan thunk OFF for games (compatdata/<id>/fex-emu/Config.json, empty ThunksDB).
- X11: Xwayland `/usr/local/bin/Xwayland` = package `xwayland-kgsl` (targets/android/pkgs/xwayland-kgsl), glamor on
  KGSL surfaceless, no DRI3 syncobj. KWin output `anland-1` follows the Android surface (one mode, resized on fold/rotate).
- Logs: Steam `~/.local/share/Steam/logs/{console_log,gameprocess_log,compat_log}.txt`; `/tmp/fex-compat-tool-<pid>.log`
  (the launch env); session log `/run/powos-app/hyprland.log` (KWin session, name historic) with `Xwayland KGSL:` stats.
  Proton log: `PROTON_LOG=1` via `Proton - Experimental/user_settings.py` (remove after) -> `~/steam-<appid>.log`.

## Run and check Broforce (tools/phone/verify, header of each says where it runs)
- `bf-start.sh` / `bf-stop.sh` (session user via powos-run.sh): `powos sleep never steam` + `steam steam://rungameid/274190`;
  stop closes game + Steam and removes the never entry. `pgrep -f Broforce_beta.exe` also matches the launch chain:
  wait for the X window `"Broforce"` (xwininfo, DISPLAY=:0, XAUTHORITY from Xwayland's `-auth` arg) - ~1-2 min.
- `bf-run.sh` (~10 min, memory + SF pacing + KGSL stats). Queue it, don't wait for a window yourself:
  `tools/phone/verify/queue.sh add <board-task> bf-run.sh` (result lands on the board task).
- Grab Xwayland's copy of the window (independent of what's on screen): `ffmpeg -f x11grab -window_id <id> -i :0 -frames:v 1`.
- Corruption metric (half-drawn frames): isolated dark pixels at game-pixel scale (holes.py in the 2026-10-22 run:
  `c<30 && min4neighbours > c+50`); old kernel screenrecord: holes in ~57% of frames, ~8% heavily striped.
- Unity prefs: pfx `user.reg` `[Software\\Free Lives\\Broforce]` `Screenmanager Resolution Width/Height`, `Is Fullscreen mode`.
- Steam login: a session crash can set `loginusers.vdf` AutoLogin 0 (logon "Service Unavailable") -> back to 1 with Steam off.
- The cover pad (CoverPadActivity) starts in game mode when unfolded; it was the source of a session-killing ANR (fixed 425ac57).

## Causes found (don't re-investigate)
- Session killed while gaming: Xwayland dma-buf leak via KGSL forced commits (fixed c8ab446, xwayland-kgsl 0007).
- Controller dead in games: Steam's virtual pad /dev/input/eventN is root:1004; PowOS `input` group = Android gid 1004
  (powos-deploy.sh). Android also reads Valve pads: MainActivity drops their key events.
- Stale/half-drawn frames: KGSL has no implicit sync; Mesa's X11 WSI never waits for Xwayland (x11_needs_wait_for_fences).
  Fix = kernel dma-buf sync_file ioctls (Mesa then imports its render fence into the dma-buf) + xwayland-kgsl 0008 (Present
  copy waits on the exported read fence; glFinish before idle). 0008 logs ENOTTY once on a kernel without the ioctls.
- Resolution: Unity keeps its saved/launch size (1116x2484 portrait folded) when the output resizes; open.

## Kernel (targets/android/kernel, docs/PHONE-KERNEL-CONTAINERS.md)
- Build: `STOCK_BOOT=<stock boot_b.img> JOBS=12 ./build-containers-kernel.sh` (~2 h; the full-LTO link is single-threaded
  under Rosetta). Needs `out/vendor-modules` (extract-vendor-modules.sh) and the stock boot at
  `targets/native/backup/8e5d600d/boot_b.img` (gitignored: copy/point from a checkout that has it). Docker volume
  `powos-gki-cache` holds clang, the source tree and build dirs; patches = targets/native/patches/gki + kernel/patches.
- Quick compile check of one file: worktree of the cache tree, apply all patches, `make O=<dir> drivers/dma-buf/dma-buf.o`.
- Checks the script runs: config diff vs running, pahole layout diff (`OK - every shared type has the same layout`),
  kmi-check.py vs vendor modules (`OK - the modules accept this kernel`). Module.symvers identical = old modules load.
- patches/0004 = DMA_BUF_IOCTL_EXPORT/IMPORT_SYNC_FILE backport (5.15 dma_resv excl/shared). Flashed to boot_b
  2026-10-22 (boot-powos-dmabuf.img d969681e, 5.15.180 #5). Test: a dma-heap buffer + both ioctls from Python as root.
- Test boot (writes nothing): phone on the Mac's USB, `adb reboot bootloader`,
  `~/Library/Android/sdk/platform-tools/fastboot -s 8e5d600d boot out/<img>` (Homebrew's fastboot is SIGKILLed at
  launch). Verify uname -v, root, kwin/Xwayland/plasmashell, module count (549), 17 inputs, adb over the VPN (restart
  powos-vadb's adb server if it says "closed").
- Flash: `fastboot -s 8e5d600d flash boot_b out/<img>` + reboot (USB). Only boot_b; never set-active slot a (older firmware,
  no _a dynamic partitions - no safe A/B fallback). Needs the user's explicit yes.
- Rollback: `~/Projects/PowOS/backups/oneplus-open/2026-10-22-before-dmabuf-kernel/boot_b.img` (e8205808, containers
  kernel) flashed the same way; a hang: hold power + volume-down -> bootloader -> flash it.

## Xwayland package
- `targets/android/build-pkgs.sh xwayland-kgsl` (BUILD_ON_ROOTFS: needs targets/android/out/powos-rootfs.tar.gz).
  Install: copy the .pkg.tar.xz into PowOS, `pacman -U` (root.sh); takes effect at the next session start.
  Smoke test without restarting the session: extract the binary and run it as `:7 -rootless` in the session.
- Patches 0001-0004 lfdevs (Andromarchy pin), 0005/0006 Present hangs, 0007 leak, 0008 fence wait. HACK in 0007 (registry).
