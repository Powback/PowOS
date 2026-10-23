---
name: powos-games
description: Use for games on the PowOS phone (OnePlus Open) - Steam/Proton under FEX, Broforce runs and checks, Xwayland's KGSL patches (xwayland-kgsl), the phone kernel build + fastboot test boot + flash/rollback, and the dma-buf sync_file backport. Learned 2026-10-20..23.
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
- Xwayland's copy of a window: NOT ffmpeg x11grab (FFmpeg 9 needs MIT-SHM, none on Android): Xlib XGetImage, bf-lib
  `xframes first|change|count|grab` (python ctypes; grab writes PNGs with zlib, no PIL). bf-checker's grab and bf-fold's
  "changes" use it (both got no frame before). td-launch-phone.sh's window.png still uses x11grab. Half-drawn = dark px
  `c<30 && min4nb>c+50`.
- Budget 300 s per job (never raised): one bf-checker variant (~4 min) or one bf-pacing mode per job.
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
- /proc/<pid>/cgroup can list cgroup v1 hierarchies too (since the 02:07 boot: freezer, memory:/apps, cpuset, cpu,
  blkio before `0::`): read only the `0::` line (bf-lib cg2). Reading the whole file as the path made bf-resume FAIL
  freeze-auto/freeze at 02:58 although powos-sleep-gui had frozen Steam at 02:56:50 (start grace ended 02:56:44). The
  product (sleepd cgroup_v2, game.sh, /usr/bin/steam) matched substrings / the 0:: line and was fine.
- Lost launch 2026-10-23 02:42 (bf-launchpaths FAIL launch, 394 s, no reaper): Steam 27858 (`-silent`, started 02:37:32
  by powos-steam-resident) was NOT frozen (no sleep cgroup, no freeze line) and alive: open-task's URL went into
  ~/.steam/steam.pipe (mtime 02:42:47) but the client never logged it (console_log silent 02:38:05-02:53:57, no
  ExecCommandLine); the session restart at 02:53 replaced it and the next launch (a cold Steam) worked. Cause not
  pinned yet: bf-lib step_launch now fails `launch-handoff` after 20 s with handoff_diag (thread states, wchan, frozen
  sleep cgroups = a D-Bus/X peer it may wait on, pipe mtime). sleep-gui's log restarts with each session: read
  watcher lines in the check log for older ones.
- Never auto-frozen before its first window (sleep-gui GAME_WINDOW_S 600): a cold start outlasts the 2 min grace.
- The user's model (2026-10-23): a game is kept in the background ONLY after the user started it and navigated away
  (home, another app, fold) - frozen like Steam, a tap on its icon resumes it. No game is ever started for the user:
  ~/.config/powos/steam-resident-games stays EMPTY (powos-steam-resident still has the code that would start them).
- Any game, not just Broforce (the user: same rules for every game/app they start): bf-lib/bf-return/bf-game/bf-start/
  bf-stop/bf-pacing/bf-fold take APP=<appid> (default 274190, the test case; queue as `env APP=<id> ...`); GAME and
  WIN_NAME come from Steam's appmanifest (bf-lib steam_field, any library folder). bf-checker stays Broforce's (Unity/DXVK).
- The user's way back: `queue.sh add <task> bf-return.sh` (bf-return-phone.sh launch|away|back|close): open-task launch
  -> full-screen window -> Android HOME intent (`am start -a MAIN -c HOME`, from the Mac side: the session can't) ->
  frozen by itself (grace + 15 s) with the same game alive -> open-task again -> tap -> first changed frame (FAIL past
  10 s, goal < 3 s), the game's task in front (PowosWindowActivity), its X window focused, its pactl sink-inputs back
  uncorked. "TIMES resume N ms ..." line. ~3-4 min.
- A Broforce running before a check is the USER's (bf-game.sh state: game=frozen = they left it, game=awake = they
  play it, a controller doesn't move the touch IRQs). awake: every check skips (exit 3). frozen: bf-pacing measures it
  as it is (base only) and bf-fold uses it, both freeze it again after (`powos game 274190 freeze`), never close it;
  bf-checker skips (it needs the loading screen). A game the check started is closed (bf-stop.sh: game only, Steam
  stays). Between modes/variants: bf-stop.sh, not `pkill -f Broforce_beta.exe` (left the prefix's wineserver).
## Launch time (tap -> first frame; goal < 10 s; board task games-launch-instantly-steam-wine-resident-fex-s)
- `bf-coldstart.sh [cold|steam|fexcache]...` -> "STAGES" lines, ms from the tap: steam-ui, iscript <start>-<end> (the
  install script evaluator), reaper (the GAME's), pv, wineserver, exe, window, frame; "evaluator:" = its log line.
  fexcache = FEX_ENABLECODECACHINGWIP=1 through ~/.config/powos/proton-settings.json + FEXOfflineCompiler between runs.
- Cold 2026-10-23 01:17 (Steam off), read off console_log/gameprocess_log: tap -> ExecuteSteamURL 23 s (Steam's own
  start) -> CheckShaderDepotManifest 2 s -> install script evaluator 30 s (01:17:35-01:18:05; 6-42 s over 8 launches)
  -> SynchronizingCloud/Stats/controller ~1 s -> game reaper 55 s -> exe 64 s -> window 82 s (314x208, full screen a bit
  later) -> frame never recorded. The old "reaper 25.7 / pv 28.7 / wineserver 33.9 s" were the EVALUATOR's chain.
- Causes found (don't re-investigate):
  - Steam runs `proton run legacycompat/iscriptevaluator.exe legacycompat\evaluatorscript_<id>.vdf` (its own reaper
    `SteamLaunch AppId=<id> Install=1`) before EVERY launch, cold or warm Steam: a whole Wine boot under FEX, then the
    game's `waitforexitandrun` waits for that wineserver. Fix: pkgs/steam/user_settings.py (Proton imports it after
    the container is up, before Wine): exits 0 at once when script bytes + Proton version + prefix inode match the
    last run that exited 0 (compatdata/<id>/powos-iscript.{done,log}); reg_guard deletes .done on a registry restore.
    The container + Proton's own start (~3-5 s, x86 python under FEX) still happen: only a Valve-side change avoids them.
  - frame "-": FFmpeg 9's x11grab needs MIT-SHM, Android has no SysV shm ("Could not get shared memory buffer",
    "Error during demuxing: Permission denied") - every x11grab on the phone fails (bf-checker's grabs too). bf-lib
    `xframes` = Xlib XGetImage of 16 rows from python ctypes (first_frame <s> by window name, first_change <id> <s> <fps>).
  - Unity maps a 314x208 "Broforce" window first, then goes full screen (bf-window.sh read 314x208 at map).
  - bf-start.sh's bare `steam steam://rungameid` gave the game no task in front (bf-pacing measured HomeShell): it goes
    through powos-open-task now. A raw steam:// launch does NOT bring the game to the front.
  - Proton's user_settings.py: one file per Proton dir; checks that wrote their own (bf-checker, td-launch) replaced
    ours and a killed run left it (DXVK_LOG_PATH, 02:01). Checks put env in ~/.config/powos/proton-settings.json.
- Base state: Steam resident (pkgs/steam powos-steam-resident, session autostart, `steam -silent` 60 s after login,
  frozen by unified sleep; off: ~/.config/powos/steam-resident-off; log $XDG_RUNTIME_DIR/powos-steam-resident.log).
- < 10 s needs the GAME resident: warm Steam + skipped evaluator still leaves ~4 s evaluator container + 9 s reaper->exe
  + 19 s exe->window under FEX. The user ruled out starting games at login (steam-resident-games
  stays empty): the instant path is the game THEY started and left, frozen, resumed by its tap (bf-return.sh).
- Still open: FEX code cache (fexcache never measured), pressure-vessel locale-gen (PRESSURE_VESSEL_GENERATE_LOCALES=0),
  Steam's CheckShaderDepotManifest 2 s. Persistent wineserver: Proton's waitforexitandrun waits for the prefix's
  wineserver to exit, so a resident one blocks the launch - a resident (frozen) game is the instant path.
- Verify queue gate: a job waits until its commit is in the live shell / installed APK; only shell/ and the APK's
  inputs count (queue.sh ship_paths). A commit with others' unshipped shell/Kotlin still waits: queue a `git archive
  <commit> tools/phone targets/android/session` copy (as bf-checker's job did) when the check needs only scripts.
- adb.sh mounts each pushed path's dirname: a path with `..` pushes nothing ("cannot stat") - resolve it first.

## Per-game compat policy: every Steam game, not just Broforce (pkgs/steam powos-steam-compat, pkgrel 23)
- Each game runs one of: `native` (its Linux build, no compat tool: x86 under FEX, no Wine; FEX's GL/Vulkan thunks to
  the phone's Mesa), `arm64` (proton-experimental-arm64, appid 4427310: Wine native, game code via arm64ec/wow64fex;
  needs SLR 4 arm64 4185400, Steam fetches it at the first launch), `x86` (proton_experimental: all Wine under FEX).
- Mode `auto` (new games): fastest MEASURED working tool (median tap->window, warm Steam samples first), else the
  first the game has of native / arm64 / x86; a tool whose last launch failed is skipped. Mode `kept`: games that
  already ran under Proton (compatdata/<id>/pfx/drive_c/users exists) keep their tool until `auto` - native would hide
  saves kept in the prefix and swaps the depot. `pinned`: `powos game <x> compat native|arm64|x86`.
- Builds per game come from appcache/appinfo.vdf (v29: string table at offset 8; launch entries' config.oslist).
  2026-10-23: Broforce/RimWorld/Besiege linux+windows+macos, Teardown windows only; all four `kept`.
- Written into config.vdf CompatToolMapping ONLY with Steam off: /usr/bin/steam runs `powos-steam-compat apply` in its
  not-running branch (Steam rewrites config.vdf from memory at exit). A `set` while Steam runs waits for its next start
  (resident Steam: `powos game <x> stop --steam`). State ~/.local/share/powos/steam-compat.json; config.vdf/localconfig.vdf
  backups `<file>.powos-bak-<time>` (last 10).
- Measured by powos-open-task (LaunchRecord: tap -> picked window, "fail" when none in WAIT_GAME_S; skipped when anything
  downloaded meanwhile - steamapps/downloading non-empty or any manifest's LastUpdated changed - or for a resume;
  POWOS_NO_LAUNCH_RECORD=1 off) and by bf-coldstart (`record` per run). `powos-steam-compat status` shows it all.
- powos-open-task matches a game's window also by its process running under `reaper SteamLaunch AppId=<id>` (native
  builds have their own class, e.g. Broforce.x86_64, not Proton's steam_app_<id>).
- Only a COLD launch (one that started Steam) can record a tool as failed: a warm launch without a window is Steam's
  freeze/thaw (2026-10-23 02:53/02:58: frozen Steam never thawed / never frozen), bf-coldstart prints "INVALID ..."
  (warm wait 150 s) and records nothing - re-queue those runs after unified sleep's fix.
- Environment for Steam and every game: /usr/lib/powos-steam/steam-env then ~/.config/powos/steam-env (KEY=VALUE,
  empty value unsets), exported by /usr/bin/steam. Candidates go in only measured (bf-coldstart `env:K=V`).
- Tests: test/tier1/test-steam-compat.sh (fake Steam tree). Install: build-pkgs.sh steam (needs pkgs/steam/
  sysvipc-emu.tar.gz + out/pkgs/{fex-emu,gtk2} - copy from a checkout that has them, e.g. worktrees/games-launch),
  then `queue.sh add <task> tools/phone/verify/pkg-install.sh <abs pkg path>` (pacman -U + rollback tar).
- bf-coldstart works for any appid: `app:<id>` (`win:<title>` if the window isn't titled like the Steam name); the exe
  stage = a process running a file from common/<installdir>/ whose exe is FEX or Wine. Setup tokens: cfg:x86|arm64|
  native|auto, opt:vk|gl|base, env:K=V, keep (else mode + launch options are put back at the end).

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

## Teardown (1167630; board task teardown-doesn-t-start)
- Build 25295735 is D3D12 (D3D12/ Agility SDK, dxcompiler/dxil, WinPixEventRuntime, sentry/crashpad, mimalloc):
  VKD3D-Proton, not GL. Prefix pfx registry is good ("WINE REGISTRY Version 2", powos-reg copy exists).
- 2026-10-23 01:38/01:39 (local): two launches on x86 Proton Experimental under FEX, chain gone 8-9 s after
  CreatingProcess, gameprocess_log "exit code -1", no window. FEX telemetry (compatdata/<id>/fex-emu/Telemetry, one
  .telem per x86 program at exit, mtime = when) shows the last x86 program to exit was pv-locale-gen; python3 (Proton's
  script), wineserver, wineboot, teardown.exe: no telem since the 10-16 install = the chain died inside pressure-vessel
  before Proton ran. Read Telemetry mtimes first when a launch dies without logs: cheap "how far did it get".
- After that someone set Teardown to `proton-experimental-arm64` (CompatToolMapping priority 250, 01:39:43): Steam
  installed "Proton Experimental (ARM64)" (4427310; ships libarm64ecfex/libwow64fex) but it needs tool 4185400 (SLR 4
  arm64), not yet installed: the next launch downloads it.
- Steam's stdout (pressure-vessel, Proton, Wine stderr) is only kept when Steam was started from the session
  (hyprland.log); a Steam started by powos-open-task / the drawer loses it. Check: `td-launch.sh [arm64|x86]...`
  (queue, --budget 1500): starts Steam itself with stdout to a file, PROTON_LOG via user_settings.py, per-Proton
  variant, puts the mapping back (KEEP=<variant> keeps it). bf-lib.sh/bf-stop.sh take APP/GAME/WIN_NAME.

## Fold mid-game (kwin 3.21 = pkgs/kwin 0017; check: `queue.sh add --close <task> bf-fold.sh`)
- Before: a fold resized the game's full-screen X window to anland-1's new size (Unity kept its own) and the window
  task (patch 0013) cropped it. 0017: exported full-screen windows keep their geometry (QObject property
  `powosKeepFullScreenGeometry` -> checkWorkspacePosition returns; ABI unchanged) and AnlandWindowTask::scale/viewport
  fit them, centred, letterboxed (touch too); scale 1 when buffer == window. Every full-screen task letterboxes now.
- bf-fold.sh: needs KWin >= KWIN_MIN (6.7.5-3.21); installs only an explicit KWIN_PKG NEWER than the installed one
  (vercmp). An old kit's KWIN_PKG=3.21 once DOWNGRADED the installed 3.22 (0018) (2026-10-23 02:02): never queue a kit
  with a pinned package. Fresh session (`android-request power logout`, never with Broforce up) when the running KWin
  maps a deleted libkwin; state 3->0->+25s->3; Broforce via bf-lib step_launch (open-task: a frozen one is resumed). kwin_wayland: pgrep as root; "libkwin (deleted)" in maps = old one running.
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
