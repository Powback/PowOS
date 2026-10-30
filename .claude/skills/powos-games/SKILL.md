---
name: powos-games
description: Use for games on the PowOS phone (OnePlus Open) - Steam/Proton under FEX, Broforce runs and checks, Xwayland's KGSL patches (xwayland-kgsl), the phone kernel build + fastboot test boot + flash/rollback, and the dma-buf sync_file backport. Learned 2026-10-20..23.
---

## Quick recipe
- Files: `targets/android/steam/*` (fex-compat-tool, sysvipc), `targets/android/pkgs/steam`, `lib/game.sh`,
  `targets/android/kernel/` (dma-buf patches), checks in `tools/phone/verify/bf-*.sh` / `td-launch.sh`.
- Build: `targets/android/build-pkgs.sh steam` (needs gitignored inputs from the shared build-inputs cache);
  kernel: `STOCK_BOOT=<img> JOBS=12 ./build-containers-kernel.sh` (~2h, see Kernel section for test-boot/flash).
- Check: PHONE ONLY (hardware/GPU driver) — `tools/phone/verify/queue.sh add --close <task> bf-run.sh` /
  `bf-pacing.sh <mode>` / `bf-coldstart.sh [cold|steam]` / `td-launch.sh`. No emulator lane for games.
- Land/install a package: `tools/phone/verify/pkg-install.sh <abs pkg path>` queued, same task as the feature check.
- Friction: `tools/agents/friction add --area games --kind <...> "<title>" --repro "<cmd>"`.

Access, idle windows and on-device rules: the powos-phone skill (adb/root/idle/cdp and the on-device verify checks). This is the games/kernel part.

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
  steam -shutdown`, KILL at 6 s, one sweep after (the KILL was always needed before pkgrel 28: forwards were lost). The old
  per-process pgrep loop took 16.5 s and bf-stop's `timeout 15` left Steam running: keep the wait loop to /proc stats.
  /usr/bin/steam execs ./steam (no steam.sh restart loop). `pgrep -f
  Broforce_beta.exe` matches the launch chain too: wait for X window `"Broforce"` (XAUTHORITY = Xwayland's `-auth`).
- Frame numbers: `bf-pacing.sh [base|cap60|fifo|nolatency]...` (~4 min/mode; queue it): 30 s SurfaceFlinger presents
  (bf-present.sh) + 20 s screenrecord -> bf-frames.py: fps, frame-time percentiles, % at 16.7 ms, dup/stale frames,
  window vs screen, activity in front. Artefacts ~/.cache/powos-verify/bfp-<date>/<mode>/.
- KWin shows every X toplevel (the game too) as its own Android task (PowosWindowActivity); never `am start andro.marchy.MainActivity` (PowOS home).
- Export gap (fixed kwin 0024, 3.28): an Xwayland window gets its wl_surface AFTER KWin manages it; a game that goes full
  screen in between (Unity/Wine) was dropped by both export paths and ran unseen (from Steam's Library nothing else calls
  show; powos-open-task's show masked it). hyprland.log: "has its surface now (full screen)", "full-screen window X opened
  as a task" / "... not a task: normal .. skipTaskbar .." (why). Check the Library path: `bf-coldstart.sh [app:<id>]
  via:steam steam` (asserts "window task N live .. for <title>" = FAIL export-<v> else, + a SHOT screenshot).
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
- Ship: build-pkgs.sh steam needs out/pkgs/{fex-emu,gtk2}*.pkg + pkgs/steam/sysvipc-emu.tar.gz (sha 7dab8e01, pkgrel 28;
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
- Forwarded launches (`steam steam://rungameid/N`, `steam -shutdown` into a running client), ROOT CAUSE 2026-10-23 22:30:
  the forwarder writes the command line into ~/.steam/steam.pipe; the client's bootstrapper (steamrtarm64/steam) reads
  it, stores it as registry.vdf HKCU/Software/Valve/Steam/TempAppCmdLine and sets a NAMED EVENT = a SysV semaphore
  (key 0xe93c17d9); steamui's CSteamBootstrapperController pump (SteamBootstrapper_GetForwardedCommandLine) waits on
  that event (semop -1 IPC_NOWAIT), reads TempAppCmdLine, clears it and runs CSteamDoc::ExecCommandLine (console_log
  "ExecCommandLine:"). Valve's event open/close calls a semaphore ABANDONED when GETNCNT+GETZCNT == 0 and GETPID is 0,
  the caller, or a dead pid (kill(pid,0) ESRCH), and IPC_RMIDs + recreates it. sysvipc-emu left sempid 0 after SETVAL
  (Linux sets it to the setter), so the next Steam process removed the live client's event: its semop -> EIDRM forever,
  TempAppCmdLine stayed in registry.vdf, every forward lost. Fix: shim SETVAL/SETALL set sempid (steam pkgrel 28;
  sysv-test checks it, kernel SysV passes the same test). pkgrel 24-27's restart-on-lost-hand-off is gone.
  Check a live client passively (root, no window): /proc/<pid>/maps lists `y700-sysv/sem-<id> (deleted)` and the
  header's removed=1 = the broken state; registry.vdf keeping TempAppCmdLine after a forward = not consumed. A client
  started before the pkgrel-28 install keeps its removed event: it needs one restart.
- The forward gate inside ExecCommandLine (steamui): CSteamDoc+0x1d1 set, and in state 0 (+0x1d8) IClientUser::
  BNeedsSSANextSteamLogon false (CUser+0xcc8 bit 30); "-login" lines go another way. Read with /proc/<pid>/mem.
- "Forward lost" but console_log HAS ExecuteSteamURL and no GameAction line after it = the game already has a launch
  action waiting for the user (an earlier one): read `grep 'waiting for user response' console_log` (skip
  ShowInterstitials/CreatingProcess that "continues" at once). 2026-10-24 05:10 Broforce: Steam frozen ~30 min lost
  its CM link (connection_log "Disconnected By Remote Host" at the thaw = the tap, reconnect backoff 9-19 s); the
  launch's cloud sync ran logged off (cloud_log "[login=false]") -> "SynchronizingCloud "syncfailed"" waits in
  Steam's own (hidden) window, and every later launch of that game joins it until Steam restarts. Fix (pkgrel 29,
  /usr/bin/steam): a rungameid forward waits for Logged On over a live link (kernel socket of connection_log's newest
  ConnectionCompleted local port ESTABLISHED), max 30 s. Such a launch takes the backoff (~10-20 s); a live link 0 s.
- Never attach gdb to Steam in a check: a client frozen meanwhile never takes the attach's SIGSTOP; `timeout` killed gdb
  and the SIGSTOP stayed pending, delivered at the next thaw (state T, do_signal_stop: 04:40 -> 05:00). /usr/bin/steam
  (pkgrel 24) SIGCONTs a stopped client tree.
- One Proton prefix per Wine architecture: a prefix ARM64 Proton set up (its VC++ redists) breaks x86 Proton
  (VCRUNTIME140/MSVCP140 c000007b, Teardown 06:04). powos-steam-compat apply, td-launch and bf-coldstart cfg: swap
  compatdata/<id> <-> compatdata/<id>.powos-<family> (powos-family file says which is in place; saves stay with theirs).
- A compat tool change across native <-> Windows builds is a DEPOT SWAP (Steam downloads the other build; Broforce
  arm64 after native: LaunchApp AppError_19 2 s in, 05:20). Checks: `fetch` token (bf-coldstart) / fetch_deps
  (td-launch) download untimed before a timed run. Group check variants by depot.
- Steam's "Processing Vulkan shaders" (ProcessingShaderCache, fossilize under FEX) held RimWorld's launch 28 s (05:46).
  pkgrel 24: POWOS_STEAM_ARGS (steam-env) e.g. -noshaders; measure with bf-coldstart env:POWOS_STEAM_ARGS=-noshaders.
- Check-script pitfalls fixed 2026-10-23: `cmd | tr -d '\r' | tee run.txt` block-buffers - a budget-killed check left an
  EMPTY run.txt (use `sed -l $'s/\r$//'`); the runner's TERM killed only the Mac side, the phone script ran on (trap it,
  pkill the phone side); bf-lib close_mine ran ON_CLOSE as one word (eval); `BF_ADB=$A . bf-lib.sh` scopes BF_ADB to the
  source (pill keeps BF_ADB_PATH); root.sh/user.sh scripts must live under $HOME (adb.sh mounts the dirname: a
  /var/folders mktemp "cannot stat" - every pkg-install FAILed); queue.sh needs the script's +x bit in git.
- Fire-and-forget installs (steam-install.sh): appmanifest stubs (StateFlags 1026, name/installdir from appinfo.vdf)
  with Steam off, one `steam -silent`, exit; Steam downloads in the background, game checks wait ("not ready", exit 3).
- Measured 2026-10-23 (cold, tap -> window / first frame): Broforce x86 77.3/82.2 s (Steam 24, evaluator 32 even when
  skipped, chain 20); Besiege x86 52.4/72.1 s; Teardown ARM64 63.4 s (38.8 s with a warm prefix), window BLACK 30 s
  later (vkd3d device up, SM 6.6); Teardown x86: VC runtime c000007b (prefix); RimWorld x86: exe exits 49 s in, no
  window; Broforce native: exe at 41 s, no window in 300 s.
- A -silent Steam (powos-steam-resident) has no window, so sleep-gui never tracked it (tracked began at a window) and it
  was NEVER frozen: 12.7% of a core all session (127 ticks / 10 s, Steam tree + webhelpers). Fix c39ec1b: Gui.adopt every
  30 s tracks a unit's live pidfile root without a window (idle from then; its grace/busy rules). Install a lib/ file
  without a full deploy: `queue.sh add <task> tools/phone/verify/lib-install.sh apps/powos-sleep-gui game.sh`
  (lib/<p> -> /usr/lib/powos/<p>, backup /var/cache/powos/lib-<name>.<time>.bak, restarts sleep-gui).
- bf-coldstart `win:<title>` goes base64 (WIN_B64) through su -c: spaces kept (RimWorld = "RimWorld by Ludeon Studios").
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
  Warm variants also print `handoff <ms>` (the running client logged the URL); a new client after the tap = FAIL restart-<v>.
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
- Where a cold start's ~32 s to the reaper went (MFP 14:27, Steam's own logs, ms-exact enough at 1 s): wrapper 2 s
  (reg_guard reads 43 MB of prefix registries twice ~1.1 s, powos-steam-compat apply ~0.6 s) -> bootstrap: update
  manifest 1 s + "Verifying all executable checksums" 0-4 s (-noverifyfiles skips it) -> client + web UI up 5 s ->
  steamui_login "WaitingForNetwork" -> "Timed out waiting for network" 10 s (20 s on some starts) -> logon <1 s ->
  library/UI ready 5 s -> ExecuteSteamURL -> ShowInterstitials 4 s (UI busy, continues by itself) -> CreatingProcess.
  The network wait (213 of 222 logins): Steam reads NetworkManager through libnm, and libnm needs the D-Bus
  ObjectManager at /org/freedesktop + the Devices/StateReason properties; Andromarchy's android-nm had neither, so
  libnm saw "not running". Fixed in PowOS's copy targets/android/session/android-nm (deploy installs + restarts it).
  Check what libnm sees: python gi NM.Client.new() with DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/powos-app/system_bus.
  That alone did NOT end the wait (2026-10-23 23:04): steamrtarm64/steamclient.so (CNetworkDeviceManagerLinux, the
  only libnm user) opens each NM device with libudev from its Udi as a sysfs path and DROPS it on failure -
  console_log "Init: failed to open udev_device for wlan0 (sysfs path: /org/freedesktop/NetworkManager/Devices/1)" -
  and reads the IP from nm_device_get_ip4_config. android-nm now serves the real interface (Udi = realpath of
  /sys/class/net/<if>, MAC, IP4Config with address/gateway/DNS, from `ip route get`). steamui.so waits on that
  manager (NetworkDeviceStateChange), not on NM State/Connectivity. android-nm is started by every session
  (powos-rooted-session `bg android-nm`, app mode SessionService); `pgrep android-nm` (comm) works since this fix,
  before it was "python3" - use `pgrep -af android-nm`. Measured MFP cold 23:52: steamui_login WaitingForNetwork ->
  LogOn in the same second; steam-ui -> reaper 15.2 s (23:08: 26.0 s), reaper 26.5 s (31.7/33.9 s; this run's
  checksum verify took 7 s). The idle wired device (android0, no interface) still logs one udev line: harmless.
- Steam logs per stage: bootstrap_log (update/verify), steamui_login (network wait), connection_log (CM logon),
  console_log (ExecCommandLine, GameAction tasks), gameprocess_log (pids). Read them before strace.
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
- New games for tests: `queue.sh add <task> steam-install.sh <appid>...` (steam-install-phone.sh: Steam's own
  steam://install/<id>, Return on its install dialog, done when the appmanifest appears; closes the windows it raised;
  never launches/buys). Then queue `bf-coldstart.sh app:<id> cfg:auto keep cold` per game: it exits 3 "not ready"
  (retried next window) while the game isn't StateFlags 4 or any manifest has a download running (256|1024|1048576).
  Window match (bf-lib gamewin / xframes): the Steam name, else a title starting "<name> " (Noita's has its build).
  Test set 2026-10-23 (board "Game test set: varied engines", owned + single-player only): see that task.

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

- Minimised game (Broforce 2026-10-30: WM_STATE Iconic + _NET_WM_STATE_HIDDEN = isMinimized, since KWin clears
  HIDDEN for a window merely on another desktop): a full-screen Wine/Unity game minimises ITSELF when it loses KWin's
  activation. Its task hidden as "off page" (WindowFrames.showOnly -> FreeformTasks.away) or never live was enough.
  Fixed: kwin 0040 (a full-screen task's window minimise is undone; a never-live task restores it on the desktop;
  floating task gone full screen takes the output size at once, not 1360x1708) + WindowFrames.mayHide (never hide a
  window full screen or launched/activated < 10 s ago). Check: `grep minimized itself` in KWin's log, `xprop WM_STATE`.
- ABZU (UE4, 384190) pillarbox: our window IS the container size; the game's own GameUserSettings.ini has
  DesiredScreenWidth/Height=1280x720, Fullscreen=ON, bUseDesktopResolutionForFullscreen=False, so it renders 1280x720
  and Proton's fullscreen hack scales it. Lever: a UE twin of unity-screen (`-ResX=W -ResY=H` / desktop resolution).

## Teardown (1167630; board task teardown-doesn-t-start)
- Build 25295735 is D3D12 (D3D12/ Agility SDK, dxcompiler/dxil, WinPixEventRuntime, sentry/crashpad, mimalloc):
  VKD3D-Proton, not GL. Prefix pfx registry is good ("WINE REGISTRY Version 2", powos-reg copy exists).
- 2026-10-23 01:38/01:39 (local): two launches on x86 Proton Experimental under FEX, chain gone 8-9 s after
  CreatingProcess, gameprocess_log "exit code -1", no window. FEX telemetry (compatdata/<id>/fex-emu/Telemetry, one
  .telem per x86 program at exit, mtime = when) shows the last x86 program to exit was pv-locale-gen; python3 (Proton's
  script), wineserver, wineboot, teardown.exe: no telem since the 10-16 install = the chain died inside pressure-vessel
  before Proton ran. Read Telemetry mtimes first when a launch dies without logs: cheap "how far did it get".
- The last x86 programs of the 01:39 launch (Telemetry mtimes, UTC 23:39): x86_64-linux-gnu-detect-lib / -detect-platform
  = pressure-vessel's graphics-stack probe under FEX; nothing after it. Next: td-launch's Steam stdout.
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
- 0032 (3.37, 2026-10-28, board games-resize-live-to-their-container-portrait-la): REVERSES 0017's size-keeping. The user
  wants the game to match its container: fitWindow -> fitFullScreen sizes an exported full-screen window to taskSize /
  targetScale on every task change (goLive after rotate/fold, resizeTo for a floating drag, setAppFullScreen). Evidence:
  hyprland.log "window task 2 touch ... (steam_app_274190, 496x1104+0+0) (outside its input region)" while the task was
  2484x1116 / 2268x2440 / 1360x1708 = launched on the cover at 1116x2484 / scale 2.25, never resized. 0017's fit-scale
  letterbox stays as the fallback for a game that ignores the ConfigureNotify. Log: "full screen follows its task".
  Check: bf-resize.sh (window aspect == screen aspect: unfolded, landscape, cover landscape/portrait, unfold again).
  Unverified: whether Unity/DXVK under Wine re-renders at the new size or DXVK just scales its old swapchain.
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

## Frame rate (board task games-fps-my-friend-pedro; MFP 557340 = proton-experimental-arm64, Unity x64 via arm64ec FEX)
- `env APP=<id> bf-pacing.sh base|env:K=V[,K=V]|cap60|...` (one mode per job): SF presents + screenrecord + bf-prof.sh
  ("prof <mode>:" lines: 25 busiest threads with process/thread/last cpu, per-cluster avg clock + min cap vs hw max,
  GPU busy/clock/thermal_pwrlevel, hottest zones, cpuset of busy processes). WIN_NAME defaults to Steam's name.
- Idle 2026-10-24 00:00: clusters CAPPED below hw (policy7 1708/3187 MHz, policy3 2054/2803, policy0 1459-1785/2016),
  cooling devices all 0, uag soft_limit off: an OPlus scene cap (perf HAL), not thermal. /proc/game_opt (game_pid,
  disable_cpufreq_limit, cpu_max_freq) is OPlus's game hook - game_pid=-1: PowOS games are not known to it. Check the
  cap DURING a game (prof cluster lines) before acting.
- Frame callbacks of a window task (kwin 0013 AnlandWindowTask::render): KWin sends them after every frame it draws
  into the task's buffer (framePainted), paced by the consumer offering a buffer (native_consumer.c render thread:
  dequeueBuffer -> select_dmabuf -> refresh_done). No task surface (activity stopped: screen off, task behind) = task
  in the background = no callbacks: Xwayland's KGSL line then shows ~all commits "forced" (~2/s: one per 64 damage
  passes) - that is a game nobody sees, not a compositor fault. The 2026-10-24 03:58 "evidence" run was that (no
  SurfaceView layer, nothing resumed, no screenrecord). bf-pacing now says INVALID unless display ON + PowosWindowActivity
  resumed + its SurfaceView layer, before and after the 30 s; prints the KGSL commits/forced and KWin's "window task"
  lines (kwin.txt). Toybox grep has no BRE `\|` (bf-present picked container layers with no buffer: "no presents").
- Full-screen window tasks keep the screen on (PowosWindowActivity.immersive: FLAG_KEEP_SCREEN_ON): a controller's
  input goes to Linux, never Android's user-activity timer, so the screen timed out mid-game.
- bf-pacing time (300 s budget, one mode/job): each adb.sh call is a docker run over the VPN (~2.5 s); waits are one
  phone-side call each (bf-nap.sh, `bf-window.sh wait <s> <irq>`), the window waited only while the rest fits
  (AFTER_WIN_S 165; "FAIL no game window" instead of a budget kill). MFP runs 02:19/02:55 waited 3.5+ min for a window
  that never came, past the budget.
- Window path per frame (lfdevs 0003): DRI3 pixmap from the client's LINEAR dma-buf, its EGLImage re-created before
  every Present copy (refresh_dri3_pixmap), Present flips disabled on KGSL -> glamor copy into the window pixmap ->
  window buffer commit (a forced commit also replaces the wl_buffer = KWin re-imports) -> KWin AnlandWindowTask draws
  the window item into the Android task buffer -> SurfaceFlinger. 2-3 full-screen copies + per-frame imports.

## Latest hand-off
2026-10-24 05:35 (steam-launch-drop). State: steam pkgrel 29 (ca94c10e) waits, in /usr/bin/steam, for a resident
client's logon before forwarding a rungameid (dead CM link after a long freeze -> cloud "syncfailed" prompt hidden in
Steam's window -> every later launch of that game joins it). Queued: pkg-install 29, `bf-coldstart.sh cold steam`
(cold first: the live Steam still holds Broforce's stuck action), `via:steam steam`, Desk Job answer.sh (--close).
Gotchas: "no launch yet" with ExecuteSteamURL logged = a waiting game action, grep console_log 'waiting for user
response' + connection_log/cloud_log; bf-coldstart's dump hides it (f89). Package inputs (sysvipc-emu.tar.gz 7dab8e01,
out/pkgs fex-emu/gtk2) only in powos-multiplatform/bf-fast (f76); answer.sh is in ~/.cache/powos-verify (f88).
Next: (1) dead-link launches now take Steam's 9-19 s backoff: keeping a frozen Steam's CM link alive is a unified-sleep
decision (manager); (2) powos-open-task should raise Steam's main window when a launch logs "waiting for user
response" with no Steam Dialog window; (3) Desk Job = a real ShowInterstitials notice, separate.

## Latest hand-off (fps)
- State 2026-10-24: no valid fps number yet. The 03:58 "low fps" evidence was Broforce (no APP=) measured with the
  screen off: no task surface, so no frame callbacks and Xwayland forced ~2 commits/s. KWin's live task path does send
  callbacks (0013 render -> framePainted); the "no callbacks for exported windows" hypothesis is rejected.
- Landed: bf-pacing INVALID unless the game is on screen; fits 300 s (phone-side waits); prints xwl commits/forced +
  kwin.txt; full-screen tasks FLAG_KEEP_SCREEN_ON (APK, ships after the service resumes).
- Gotchas: toybox grep has no BRE `\|`; each adb.sh call ~2.5 s; queue fps jobs with `env APP=<id>`; the runner
  doesn't keep the screen on through long windows.
- Next: read jobs 20261024-041624-8926 (MFP) and -041626-9196 (Broforce). Low fps with few forced commits = CPU/GPU
  (OPlus cluster caps, game_opt game_pid=-1; Xwayland 2-3 copies/frame; xalia). Mostly forced while on screen = a real
  KWin callback gap: separate kwin patch after the in-flight 0025s. INVALID every night = keep the screen on in the runner.
