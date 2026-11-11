# Game launch time (tap -> first frame), Broforce under x86 Proton + FEX

Rule: a game tap -> first frame under 10 s; a timeout is a FAIL; fixes are generic for every game.
Board task: `broforce-launch-time` (user, 2026-11-04: "still takes forever to launch").

## Where the ~50 s go (Broforce 274190, x86 Proton Experimental under FEX, the user's pinned setting)

From `tools/phone/verify/bf-coldstart.sh cold` (4 Hz process samples, ms from the tap; 8 cold runs 2026-10-27, Steam
off at the tap, prefix up to date, evaluator already "skipped" by user_settings.py) and Steam's console_log (33
launches 11-03/11-04):

| stage | from -> to | typical | notes |
|---|---|---|---|
| Steam UI | tap -> steamwebhelper | 2.3-5.1 s | cold Steam only; resident Steam (powos-steam-resident) skips it |
| Steam client launch prep | UI -> evaluator reaper | 8-12 s | logon, CheckShaderDepotManifest; cold Steam only |
| **install script evaluator** | `reaper Install=1` -> its exit | **median 9 s, 33-35 s in 9 of 33 launches** | does nothing: input unchanged since its last good run |
| -> game reaper | | 1.2-1.7 s | Steam's cloud/stats sync, CreatingProcess |
| FEX + pressure-vessel | reaper -> pv-adverb | 2.6-3.6 s | FEX RootFS, pv container, pv-locale-gen (localedef under FEX) |
| Proton -> wineserver | pv -> wineserver | 2.9-4.7 s | Proton's Python under FEX |
| Wine boot | wineserver -> game exe | 8.1-11.5 s | wineboot/services/explorer/rpcss under FEX; prefix NOT updated (`.update-timestamp` = wine.inf mtime) |
| game exe -> X window | | 4.2-5.7 s | Unity player init |
| window -> first frame | | 7.8-8.3 s | Unity splash + first scene |
| **total** | tap -> frame | **49-55 s** cold; ~52.9 s on 11-04 (ARM64 Proton, evaluator really ran after a prefix switch) | |

The evaluator's chain is the whole launch chain a second time: `steam-launch-wrapper -> reaper Install=1 ->
FEX-Emu/fex-compat-tool run -> FEX -> SteamLinuxRuntime_4/_v2-entry-point (pressure-vessel, locale-gen) -> Proton's
python3 under FEX -> user_settings.py`, and only there did PowOS's skip (2026-10-23) see "nothing to do" and exit 0.
ARM64 Proton (no FEX layer, native pv + Python) does the same chain in ~3 s; under FEX it is 7-35 s.

## Fix 1 (2026-11-04): skip the evaluator before the container

`targets/android/pkgs/steam/sitecustomize.py` (installed as `/usr/lib/powos-steam/py/sitecustomize.py`, put on
`PYTHONPATH` by `steam-env`) runs at the start of Valve's FEX compat tool's own (host, native) Python - the FIRST
layer of every x86 Proton launch. For an evaluator run (`proton run iscriptevaluator.exe ...` in its argv) it loads
that Proton's PowOS `user_settings.py` and asks `iscript_skip_early()`: the same key (script bytes, Proton version,
prefix inode) and the same record (`compatdata/<id>/powos-iscript.done`) Proton's in-container skip uses. Match ->
exit 0 before FEX, pressure-vessel and Proton start. Anything changed / no record / the user's own user_settings.py /
any error -> nothing happens and the chain runs as before (Proton still records after a real run). Logged in
`powos-iscript.log` as "skipped before the container (FEX compat tool)". Generic: every x86 Proton game.
Test: `test/tier1/test-steam-iscript-skip.py`. HACK row: docs/REMOTE-POWOS.md §4.

Expected: -9 s median, -33 s on the slow launches (evaluator stage -> ~0.3 s: one native Python start).

| stage | before | after |
|---|---|---|
| install script evaluator | median 9 s (3-35) | pending re-measure after ship (bf-coldstart.sh cold + steam) |

Measured 2026-11-05 02:59 (steam 1.0.0.87-34 shipped): Steam running -> window 29.4 s, frame 37.6 s (reaper 3.3,
pv 6.9, Proton 11.4, exe 23.2); Steam cold -> window 47.9 s, frame 56.8 s (reaper 20.8: Steam's own start + login).

## Fix 2 (2026-11-05): the session's locales kept, not compiled every launch

pressure-vessel's pv-locale-gen runs `localedef` (x86, under FEX) for every LANG/LC_* locale the container lacks plus
en_US.UTF-8, into a temp dir, on EVERY launch: 3.6 s (timeline: localedef + gzip at pv+0.8 s, Proton's Python at
pv+4.5 s). The session's LANG=en_CH.UTF-8 has no glibc definition at all (de_CH/fr_CH/it_CH only), so pv-locale-gen
failed on it every time and the game ran on "C" anyway.

`/usr/bin/steam` (`steam_locales`, pkgrel 35) compiles those locales once with the host's native localedef into
`~/.cache/powos/steam-locales/<glibc version>/` (1.35 s the first time, 18 ms after) - a locale with no definition points
at its language's (en_CH -> en_US) - and exports `LOCPATH`. pv-locale-gen checks each locale with setlocale() first,
which honours LOCPATH: all there -> "No locales need to be generated", LOCPATH stays. If the container's glibc couldn't
read them, pv-locale-gen generates as before. Generic: every Steam Runtime game (x86 / ARM64 Proton, native builds).
Off: `POWOS_STEAM_LOCALES=0` in ~/.config/powos/steam-env. Test: `test/tier1/test-steam-locales.sh`.

| run (Steam running) | reaper | pv | Proton | exe | window | frame |
|---|---|---|---|---|---|---|
| before (-34, 11-05 02:59) | 3.3 | 6.9 | 11.4 | 23.2 | 29.4 | 37.6 |
| PRESSURE_VESSEL_GENERATE_LOCALES=0 (11-05 03:57, the upper bound) | 4.6 | 7.8 | 8.7 | 21.1 | 25.9 | 34.4 |
| kept LOCPATH (-35, 11-05 04:13) | 3.5 | 7.7 | 8.7 | 21.5 | 27.3 | - (window not focused, black: FAIL frame, re-queued) |
| Steam cold, before (-34, 11-04 03:00) | 20.8 | 24.4 | 29.3 | 42.2 | 47.9 | 56.8 |
| Steam cold, kept LOCPATH (-35, 11-05 04:17) | 27.2 | 31.5 | 33.3 | 45.7 | 51.1 | 59.8 |

No localedef in either -35 timeline. pv -> Proton: 4.5 -> 1.0 s (warm), 4.9 -> 1.7 s (cold); from the reaper: window
26.1 -> 23.8 s (warm), 27.1 -> 24.0 s (cold), frame 36.0 -> 32.6 s (cold). The cold run's later reaper (27.2 s) is
Steam's own start + login (varies run to run), not this change. The warm run's missing frame: its window never got
_NET_WM_STATE_FOCUSED (the cold run's did, and drew) - a focus/export flake, not the locale (re-queued).

## Tried: FEX code cache (2026-11-05, FEX-2607)

`FEX_ENABLECODECACHINGWIP=1` (bf-coldstart fexcache x2): FEX's own FEXServer generated caches at the next start
(shadercache/274190/fex-emu/cache, 49 MB: ntdll.so, steamclient.so, lsteamclient.so, bcrypt.so, crypt32.so, ...)
and both launches then died right after pressure-vessel (exit -1, no window). Not usable in FEX-2607; the
caches left behind are only read with the option on. Note: FEX keeps the cache under Steam in
`STEAM_COMPAT_SHADER_PATH/fex-emu` (shadercache/<id>/fex-emu), not compatdata - bf-coldstart's fexcache now compiles
and lists that dir.

## Next candidates, ranked (measure each with bf-coldstart.sh before it lands)

1. Wine boot under FEX, 11.8 s (Proton -> exe): FEX code cache crashes (above); left: ARM64 Proton for the game
   (Wine native, wine boot ~3 s - powos-steam-compat's `arm64`, the user pinned x86), or a prefix's wineserver +
   services kept between launches (needs a wineserver outside Steam's reaper, or Steam shows the game as running).
2. Steam client prep on a cold Steam, 8-12 s: keep Steam resident (powos-steam-resident) so a tap skips it.
3. Unity window -> frame, ~8 s: profiled below (not disk, not shaders, not clocks; the main thread waits ~half the time).
4. ~~pressure-vessel locale-gen under FEX~~: Fix 2.

## A/B: ARM64 Proton vs x86 Proton under FEX (2026-11-05, steam 1.0.0.87-35)

bf-coldstart.sh, Broforce 274190, same Steam build. arm64 = `cfg:arm64` (Wine native, prefix compatdata/274190.powos-arm64);
x86 = the user's pinned Proton Experimental under FEX. Seconds from the tap.

| run | iscript | reaper | pv | wineserver | exe | window | frame | job |
|---|---|---|---|---|---|---|---|---|
| arm64 steam#1 | 1.5-2.9 | 5.3 | 6.1 | 6.1 | 9.6 | 10.8 | 19.1 | 20261105-070802-37476 |
| arm64 steam#2 | 1.2-2.2 | 3.6 | 4.3 | 4.3 | 7.3 | 8.5 | 16.5 | 20261105-070803-37693 |
| arm64 cold#1 | 13.1-13.6 | 15.9 | 16.6 | 17.4 | 19.6 | 20.7 | 28.7 | 20261105-070805-37968 |
| x86 steam (ref) | skipped | 4.0 | 7.9 | 9.7 | 20.6 | 25.4 | 33.8 | 20261105-041912-28057 |
| x86 cold (ref) | skipped | 27.2 | 31.5 | 33.3 | 45.7 | 51.1 | 59.8 | 20261105-040827-75111 |

Wine boot (wineserver -> exe) is 3.0-3.5 s on ARM64 vs 10.9 s under FEX; pv -> wineserver 0 vs 1.8 s. Unity's
window -> frame stays ~8 s on both. The install-script evaluator still runs on ARM64 (1-1.5 s; the skip in
pkgs/steam only covers the FEX compat tool) - worth adding.

| arm64 check | result | x86 baseline | job |
|---|---|---|---|
| fps (bf-pacing base) | 19.4 fps, p50 33.5 ms, p95 133 ms, 71.6% >25 ms | 38-39 fps | 20261105-070808-38385 |
| visuals (bf-checker base) | 0/88 X frames checkered, screen 0/9, 18.5 fps | 0 dashes | 20261105-070810-38599 |

Verdict: ARM64 launches ~2x faster and draws clean, but runs at half the frame rate - Broforce stays on the
user's pinned x86 (restored 07:25 with the x86 prefix, `powos-steam-compat mode 274190` = pinned:x86). Next for
ARM64: why the game's frames halve there (where the frame time goes under arm64ec/wow64fex), then re-run this A/B.

### Why ARM64 Proton halves Broforce's frame rate (2026-11-05, agent/arm64-fps)

Measured live during four `bf-coldstart.sh` runs (jobs 20261105-074525/-074527/-074528/-074530; per-thread CPU over
5 s from /proc, gdb stacks of the busiest thread, the game's environment, Proton log with `PROTON_LOG=1`).

| | ARM64 (Wine native, game code via FEX arm64ec) | x86 (Wine under FEX, Vulkan thunked to host Mesa) |
|---|---|---|
| busiest thread | **`WSI swapchain queue` 61-76 %** (Mesa's x11 present thread) | game main thread 51-55 % |
| game main thread | 19 % (~10 ms CPU per frame: not the limit) | 51-55 % (~13 ms per frame) |
| WSI swapchain queue | running, every sample in `xcb_put_image` <- libvulkan_freedreno+0x1c6840 | idle (futex), never in the top 25 |
| Xwayland | 23 % | 11-12 % |
| DXVK swapchain | IMMEDIATE, 1116x2484, 4 images, created once (no recreate loop) | same DXVK v3.1.1-97 |
| Xwayland KGSL stats | 277/30 s commits forced past a stale frame callback, up to 16854 held back at 4 buffers | 2 forced, 0 held back |

The cause is the present path, not FEX: on ARM64 every frame goes to Xwayland through Mesa's **software** X11 present
(`x11_present_to_x11_sw`: one `xcb_put_image` Z_PIXMAP of the whole 1116x2484x4 = 11 MB image over the X socket,
disassembly of the installed libvulkan_freedreno 27.0.0_devel.20261029.geb3e7fd4-2 at 0x1c67fc-0x1c6840 confirms
the call), while the x86 run presents the same swapchain through DRI3 dma-buf (WSI thread idle). The 11 MB copy per
frame on the WSI thread + Xwayland's upload is the ~33 ms p50 frame (19 fps); FEX / arm64ec settings don't matter here
(the game's own threads are faster per frame on ARM64). Ruled out: present mode (IMMEDIATE already; FIFO quantization
is not it), swapchain recreation (one swapchain in the log), device access (/dev/kgsl-3d0 and /dev/dma_heap/system are
open in the game), `MESA_VK_WSI_DEBUG=sw` (not in the game's environment, not in Proton ARM64's files).
In wsi_device_init, `wsi->sw` (byte 0x348) = `sw_device || WSI_DEBUG & sw`; Turnip passes `sw_device=false`. The
branch taken in the present thread instead tests a pointer (`[[[[chain+0x50]+0x70]+0x50]+0x2c8]`, null -> CPU path,
set -> 0x1c655c DRI3 path) - next: identify that field in the eb3e7fd4 source (wsi_common_x11.c x11_present_to_x11 /
image init, likely the image's DRM/pixmap state) and why it is unset only in the native ARM64 container process
(candidate: Wine's own Xlib/xcb in the container - the process maps BOTH pressure-vessel's libxcb.so.1 and
/run/host/usr/lib/libxcb.so.1.1.0, so Mesa's host libxcb-dri3/-present may not talk to Wine's connection), then fix
there and re-measure with bf-pacing. Until then ARM64 stays at ~19 fps and Broforce stays pinned x86.

**Cause found + fix (same day):** the pointer test above is irrelevant - the installed Turnip has no DRI3 path at all.
Its NEEDED list has libxcb-shm but no libxcb-dri3 / libxcb-present / libdrm: with `-Dfreedreno-kmds=kgsl` alone and
Turnip as the only driver, Mesa's meson sets `system_has_kms_drm = false`, so `with_dri_platform` isn't drm and
`HAVE_X11_DRM` is never defined - the X11 WSI is software-only (`x11_present_to_x11_sw` is the only present). The
ARM64 game maps ours (/run/host/usr/lib/libvulkan_freedreno.so via pressure-vessel); the x86 game runs the FEX RootFS's
own x86 Turnip (Fedora 44, DRM build) and so presents through DRI3. Fix: vulkan-freedreno-kgsl 27.0.0_devel.20261029.
geb3e7fd4-3 builds `-Dfreedreno-kmds=kgsl,msm` (links libdrm, xcb-dri3/-present/-sync, xshmfence, libdisplay-info,
libudev; /dev/kgsl-3d0 still enumerated first). Published; queued: vulkan-freedreno-install.sh, then
`bf-pacing.sh cfg:arm64 base`, `bf-checker.sh cfg:arm64 base` (cfg: now a first argument of both, bf-cfg-phone.sh) and
an x86 `bf-pacing.sh base` for no regression. After-numbers: pending those jobs.

Install-script evaluator skip on ARM64: not extendable the x86 way. ARM64's chain before the container is
pw-audio-namespace -> reaper -> SteamLinuxRuntime_4-arm64/_v2-entry-point (/bin/sh) -> pressure-vessel-wrap - no Python
runs before pressure-vessel, so sitecustomize.py has nowhere to hook; the skip already happens (user_settings.py,
evaluator log "skipped: script, Proton and prefix as at its last good run") but only after the container (1.0-1.5 s).
An earlier skip needs a PowOS layer in front of the ARM64 runtime (a compatibilitytools.d tool whose entry point runs
the check and then execs `_v2-entry-point --verb=... -- <Proton ARM64>/proton ...`), which changes the tool
powos-steam-compat pins - not done here.

## Window -> first frame, ~8 s (2026-11-05, agent/unity-load, ARM64 Proton + DRI3 Turnip)

Before: steam#1 09:23 (job 20261105-091504-97682) reaper 3.6, pv 4.3, wineserver 4.3, exe 6.8, window 7.7, frame 15.6 s.
New instrument: bf-coldstart's launch profile (`tools/phone/verify/bf-lprof.py`, run by every bf-coldstart run from the tap
to the first frame, "LPROF" lines): the game process's threads' CPU at 4 Hz, its file reads (rchar vs read_bytes = from
storage), the whole phone's busy share and each cpufreq policy's clock. Run 09:37 (job 20261105-093023-48404), seconds
from the tap:

| span | game CPU (cores) | busiest threads | file reads | clocks gold / gold2 / prime (MHz) |
|---|---|---|---|---|
| 6.4-7.4 (exe -> window) | 0.3-1.0 | main | 6 -> 21 MB | 1785-2016 / 1785-2457 / 1977-2956 |
| 7.7-11.5 (Unity player init) | ~1.0 | **main 70-97 %** (one thread), UnityPreload | 21 -> 48 MB | 1459-2016 / 1785-2803 / 1977-2592 |
| 11.5-16 (first scene load) | 1.1-2.0 | UnityPreload 30-60 %, main 20-40 %, AsyncReadManager, UnityGfxDevice, dxvk-submit | 48 -> 309 MB | 1785-2016 / 1785-2803 / 1977-3187 |

Sum, exe -> frame: 10.8 core-s in 9.8 s (main 5.4, UnityPreload 2.1, UnityGfxDevice 0.9, audio 0.4, dxvk-cs/submit
0.6); the phone 45-75 % busy overall.

What it rules out:
- **Disk I/O**: 309 MB read, **0 MB from storage** (read_bytes) - every asset already in the page cache. Prefetching
  (vmtouch at the tap) can't win anything on a warm launch.
- **Shader compiles**: the Mesa cache (`shadercache/274190/mesa_shader_cache_sf`, Steam's per-game dir, Proton points
  Mesa there) wasn't written by the 09:23 launch (files from 09:08) - every pipeline a hit; dxvk-shader threads <20 %
  for under 0.5 s. DXVK v3.1.1 has no state cache any more (`DXVK_state_cache` empty, by design); nothing to persist.
- **FEX JIT cache**: ARM64 Proton's arm64ec FEX already keeps a disk cache per game
  (`shadercache/274190/fex-emu/DiskCache/<hash>/RWCacheDB_*.foz`, 47 MB, updated by every launch) - unlike the x86
  FEX-2607 code cache (above), this one works and is on.

What is left is CPU: one thread (Unity's main: Mono runtime init + managed code JIT - Mono JITs x86-64 code every
launch, which FEX then translates; no cache can hold Mono's output) and then the preload thread, **at 1.5-2.0 GHz on
the gold cores and 2.0-2.5 GHz on prime, of 2.80 / 3.19 GHz hw**. The game boost (GameBoost.kt, game-boost.sh: clocks
min 80 %, uclamp.min 75 %, hottest thread on the prime core, the vendor's game thermal table) wasn't on during any of
it: its log shows the engage 09:23:50 for a 09:23:18 tap (frame at 09:23:33) and 09:37:33 for the 09:37 run - the boost
starts only once the game's window is Android's front task, and came 17-23 s after the window, after the first frame.

Fix: boost from the tap. `powos-open-task` (the drawer's / widget's launch path, and bf-coldstart's) writes
`$XDG_RUNTIME_DIR/game-launch/<app id>` (= the app's files/run/game-launch) when it starts a launch, removes it when the
launch failed; GameBoost's tick takes the newest such mark younger than `LAUNCH_S` (60 s) whose id is a game's
(`WebWindows.isGame`) as the game in front when no game window is (`GameBoost.launching` / `front(web, task, launch)`),
so the boost holds through Wine's boot and the game's load and the window task takes over without a gap. Generic: every
game launched through powos-open-task. game-boost.sh's holder already copes with a game whose processes don't exist
yet (it adopts threads as they appear, every 5 s).

**Measured: no gain on the launch.** A/B before the APK ships, emulated exactly (scratch wrapper: bf-coldstart steam +
the app's own `game-boost.sh engage steam_app_274190 <the app's lease>` at the tap, lease kept fresh to the first
frame): boosted 09:49 (job 20261105-094216-88295) window 8.1 frame 16.2 s; unboosted 09:51 (job
20261105-094218-88434) window 7.5 frame 15.7 s; earlier unboosted 15.6 / ~16 s. Same 10.5-10.8 core-s, same thread
split, clocks barely different (horae, the vendor's thermal controller, owns the max; the boost holds only the min). The
mark stays (it is right that a launching game is the boosted one, and the boost no longer starts 20 s late), but it
does not move tap -> frame.

So the load is **not clock-bound either**: Unity's main thread is busy only 55-97 % (5.4 core-s of 9.8 s) and the whole
game ~1.1 cores, with the phone 45-75 % idle - the main thread waits about half the time. Next (bf-lprof now also lists
the busiest OTHER processes per sample, `LPROF-OTHERS`: wineserver, Xwayland, KWin, FEX helpers): find what it waits
on - wineserver round trips (Wine's server calls under Mono's startup: file/registry/sync), the X server (window
setup), or futex waits on its own threads (gdb stacks of the main thread during 8-11 s, as bf-stack-syms.py does for
hangs). Candidates by result: wineserver-bound -> esync/fsync/ntsync in Proton ARM64 (PROTON_NO_FSYNC unset? the
kernel's futex_waitv), X-bound -> KWin/Xwayland side; own-thread waits -> nothing outside the game.

**LPROF-OTHERS result (job 20261105-095416-32959, a slower run: window 11.1, frame 19.2 s):** beside the game,
**wineserver is busy 35-46 % of a core through the whole window -> frame span** (3.3 core-s; next: com.powos.app 0.9,
steam 0.9, winedevice.exe 0.5), while the game's two busiest Wine threads run 40-97 %. Unity's start is a stream of
Wine server calls, so the lead is wineserver round trips: next, check whether Proton ARM64 uses fsync/ntsync here
(`PROTON_LOG=1`: "fsync: up and running" / ntsync, `/dev/ntsync` in the kernel, `PROTON_NO_FSYNC` unset) and which
requests dominate (`WINEDEBUG=+server` counts over the load).

## Main thread split, wineserver requests, ARM64 evaluator gate (2026-11-05, agent/unity-mainthread)

Broforce 274190 on Proton Experimental (ARM64) (Wine native, game code via arm64ec FEX, DiskCache on). Instruments
(scratch wrappers around `bf-coldstart.sh steam`): `simpleperf record -a -e cpu-clock -f 1000` for 13 s from the game
exe's start, reported per thread by DSO (`unknown` = anonymous executable memory = FEX's JIT output, i.e. emulated x86
code running; `libarm64ecfex.dll` = FEX's frontend/compiler/dispatcher; `aarch64-unix|windows` = Wine), and a run with
`WINEDEBUG=+server PROTON_LOG=1` (via `~/.config/powos/proton-settings.json`) counting wineserver requests.

**Main thread (CPU s in the 13 s window, exe -> ~2 s past the first frame)**

| run | main total | emulated code (JIT out) | FEX compile/dispatch | kernel | Wine | wineserver | exe -> frame |
|---|---|---|---|---|---|---|---|
| as shipped (job 103601) | 7.8 | 4.1 | 1.15 | 1.9 | 0.4 | 3.3 | 10.5 s |
| FEX_DISKCACHEANONCACHING=0 #1 (104915) | 6.0 | 2.9 | 0.8 | 1.6 | 0.4 | 1.0 | 9.9 s |
| FEX_DISKCACHEANONCACHING=0 #2 (104916) | 6.0 | 2.9 | 0.85 | 1.6 | 0.4 | 0.85 | 9.2 s |
| FEX_DISKCACHE=0 (104917) | 7.0 | 2.7 | 1.8 | 1.75 | 0.45 | 0.8 | 9.9 s |

So the main thread is **executing emulated code**, not compiling: FEX compile is 0.8-1.15 s (1.8 s with no disk
cache: the RWCacheDB does save ~1 s of compile for file-backed code), Wine 0.4 s. esync/fsync is not the issue:
`WINEFSYNC=1`, "fsync: up and running", `/dev/shm/wine-*-fsync` mapped (the GKI 5.15 kernel has futex_waitv);
`select` was only ~2k requests.

**wineserver 3.3 core-s = FEX's disk cache thread.** Requests over one launch (+server; each counted once):
`lock_file` 74k + `unlock_file` 74k, open_key 45k, close_handle 31k, enum_key/enum_key_value 15k, get_window_tree 7k.
All 148k lock/unlock come from ONE thread, `FEX:DiskCache` (Windows tid 014c, created by FEX right after opening
`shadercache/274190/fex-emu/DiskCache/<hash>/RWCacheDB_*.foz` + `_idx.foz`): `lock_file(offset=0x4000000000000000,
count=1)` on both files, unlock both, ~37k times, for the whole session (first lock at log line 64k of 662k, last at
656k). That is FEX's `CacheStoreWorkItem` -> `StoreCacheBlob`, which locks both FOZ files per stored block (LockFileEx
= a wineserver round trip each). The RWCacheDB doesn't grow (48.15 -> 48.14 MB): these are anonymous blocks - Mono's
JIT output, different every launch - which FEX caches by default (`DiskCacheAnonCaching`, default true) but never hits.
In the profile the thread is 90 % kernel (3.4 s) and wineserver 35 % `finish_task_switch`: the pair burns ~2 cores.

Fix (pkgs/steam user_settings.py, steam pkgrel 36): `FEX_DISKCACHEANONCACHING=0` for Mono games (Unity's
`*_Data/Mono/EmbedRuntime/mono*.dll` or `MonoBleedingEdge/EmbedRuntime/`); file-backed code stays cached; a
proton-settings.json value still wins. Result above: wineserver 3.3 -> 0.9 core-s, the DiskCache thread gone from the
top, main thread 7.8 -> 6.0 s CPU, exe -> first frame 10.3 (10.0-10.5 today) -> 9.2-9.9 s. It also stops the same
storm during gameplay (it ran all session), which should show in arm64 fps (not measured here).

What is left on the critical path is the emulated Mono/Unity code itself (~3 s on main + UnityPreload 2 s) and kernel
time (page faults, wakeups). Knobs left: FEX TSO (`TSOEnabled` 1 from Proton's Config.json; diagnostic run with
TSO off, job 105916: worse, exe -> frame 10.2 s - TSO is part of FEX's cache key, so every block missed, was
recompiled (main FEX 1.8 s) and stored again (the lock storm back, wineserver 2.4 core-s); not a candidate default
either, Unity/Mono is multi-threaded), Multiblock already 1. Next: the emulated code's own cost (Mono's JIT + Unity
init) - FEX's AOT/precompile of mono.dll/UnityPlayer.dll is already what the file-backed cache gives; past that,
reducing kernel time on main (1.6 s: page faults/clear_page, wakeups) or a Unity-side option.

**Install script evaluator on ARM64: gate before the container.** New compat tool `powos-proton-arm64`
(`pkgs/steam/arm64-gate-entry` + manifests, installed by /usr/bin/steam into compatibilitytools.d): Steam runs it
instead of Valve's layered chain; it runs `iscript_skip_early` (same key/record as the x86 FEX-tool hook) and otherwise
execs exactly `SteamLinuxRuntime_4-arm64/_v2-entry-point --verb=<verb> -- <Proton ARM64>/proton <verb> ...` with
STEAM_COMPAT_TOOL_PATHS = Proton:runtime (what Steam sets itself). powos-steam-compat maps mode `arm64` to it when the
gate, Proton ARM64 and the arm64 runtime are installed (else Valve's tool, so Steam still fetches the runtime). Device
check (job 104137, scratch install of the same files, pinned, then restored to pinned:arm64): two launches fine,
evaluator log "skipped before the container (PowOS ARM64 entry)"; evaluator stage 0.4-1.2 s -> under one 250 ms sample;
tap -> reaper 3.0-3.4 s (today without it 3.1-6.3), window 7.6-7.9 s, frame 15.7-16.6 s. The ARM64 evaluator was
never the 1-5 s it was on x86 (no FEX/Python-under-FEX here): the win is ~0.5-1 s.

**After, steam 1.0.0.87-36 installed (jobs 20261105-111321..111326):** tool `powos-proton-arm64` mapped by the policy on
its own, evaluator "skipped before the container (PowOS ARM64 entry)" both runs. steam#1: reaper 3.0, exe 5.8, window
7.6, frame 15.9 s, wineserver 2.2 core-s (the first launch after the change still stored blocks); steam#2: reaper 4.8
(Steam's own prep), exe 7.8, window 8.7, frame 16.9 s, wineserver 0.7 core-s, game 10.2 core-s (was 14.5-16.4).
Exe -> frame 10.1 / 9.1 s (was 10.0-10.5). bf-pacing base: 41.6 fps, p50 14.7 ms (baseline 40.7).

## Fresh launch < 10 s? Where the 15-16 s go now, and the frozen-Steam handoff (2026-11-05, agent/launch-under-10)

Broforce 274190, `powos-proton-arm64` (steam 1.0.0.87-36), bf-coldstart `steam`, ms from the tap. Scratch A/B wrappers
(clocks, thread sampler, link lifetime) ran through the verify queue; jobs 20261105-1428..1449.

| run | Steam at the tap | handoff | reaper | pv | wineserver | exe | window | frame |
|---|---|---|---|---|---|---|---|---|
| base (job 142854) | **frozen 52 min** | **12748** | 16149 | 16863 | 17598 | 20384 | 21438 | **30301** |
| base (job 142910) | awake | 1035 | 4680 | 5384 | 5384 | 7999 | 10014 | 18467 |
| caps lifted (job 142856) | awake | 990 | 2708 | 3308 | 3932 | 5610 | 6582 | 14815 |
| caps lifted (job 142911) | awake | 989 | 3598 | 4214 | 4214 | 6627 | 7605 | 16187 |
| sampler (job 143924) | awake | 934 | 3638 | 4295 | 4997 | 7710 | 8683 | 17091 |

**The frozen-Steam handoff (fixed here).** Every earlier `steam` run had Steam AWAKE at the tap (the harness's wait for
it to sleep timed out). The user's case is a Steam frozen out of sight (units/phone/steam.json: 15 s) while they stay
in PowOS: its CM server drops the silent client **79 s into the freeze** (job 144202: socket ESTABLISHED -> CLOSE_WAIT in
/proc/net/tcp, no thaw needed to see it), the client only notices at the thaw = the tap, then Steam's own reconnect
backoff ("StartAutoReconnect() will start in 11.0 seconds (attempt 1)") and only then the launch: handoff 12.7 s,
tap -> frame 30.3 s. reconnect_ahead (2026-10-24) covered only PowOS coming back on screen.
Fix (lib/apps/powos-sleep-gui `link_watch`, every 5 s while a display is lit, generic for any `games: pause`
launcher): a frozen launcher running no game is thawed for 1.5 s every 50 s (its overdue heartbeat goes out, then
frozen again, not logged), and thawed to reconnect at once when the kernel shows its link closed anyway (the backoff
then runs off the tap's path; reconnect_poll puts it back to sleep once logged on). Screen off: no pulses (battery);
a link dropped meanwhile is found within 5 s of the screen coming on. First cut keyed on "PowOS on screen" only: the
`frozen` check (job 145940, PowOS off screen, Android's home lit - the games-widget path) still waited: link closed at
the tap, handoff 17.0 s, frame 33.3 s; now any lit backlight counts. **After** (e8c933dd lib-installed, job 151139, the same `frozen` check, PowOS off screen): link live after 100 s frozen, handoff 1.9 s, reaper 3.7, exe 7.9, window 8.9, **frame 17.4 s** (was 33.3 / 30.3 s). Test: test/tier1/test-sleep-gui-screen.py LinkWatch. HACK row: REMOTE-POWOS §4.
Pulse checked on the phone (job 144859, the same timings by hand: Sleep, then Wake 1.5 s / Sleep every 50 s): the link stayed ESTABLISHED through 200 s frozen (it died at 79 s without), no disconnect in connection_log. Expected: the frozen case back to the awake numbers (-11.7 s: 30.3 -> ~16 s); end-to-end check `bf-coldstart.sh frozen` (new variant: Steam frozen FROZEN_S=100 s before the tap, its link state printed) after the sleep-gui install.

**Clocks (ruled out).** The vendor's oiface (thread `horaeCb`) holds cpufreq caps of 2054 MHz (A715) / 1708 MHz (X3 prime,
of 3187) at 28-33 C, with or without the vendor game class (sys_thermal_control_config.xml level 2; category_4 should
lift it at gear <= 4, it never does here - the class is never re-evaluated, the front package stays com.powos.app).
A/B with oiface stopped and the caps at hw max from the tap (jobs 142856/142911, A715 at 2.6-2.8 GHz): window -> frame
8.2 / 8.6 s against 8.5 s capped. Not clock-bound.

**Unity window -> frame, ~8.3 s: the two loading threads wait on each other.** Thread sampler (job 143924, 200 Hz,
/proc/<tid>/stat + syscall from the exe's start): Unity's main thread is running user code 54 % and **sleeping in
futex_waitv (syscall 449 = Wine's fsync waits) 40 %**; from +6 s to +16 s it is 50-64 % in futex_waitv. UnityPreload:
61 % in futex_waitv, 32 % running. Only +3..+5 s (Unity's player init) is main 90 % CPU. So past player init the load is
a hand-off between main (integrating loaded objects) and UnityPreload (reading/deserialising), each waiting for the
other through Wine sync objects - wake-up latency x hand-offs, not CPU and not disk (0 MB from storage). Nothing PowOS
can cut generically from outside the game short of a faster futex wake path (candidates for a next step: ntsync instead
of fsync in Proton ARM64 when the kernel gets /dev/ntsync; the two threads pinned to one cluster to cut cross-cluster
wake latency).

**What < 10 s would need.** Awake-Steam floor today: Steam's own prep ~2.5 s (URL -> CreatingProcess: shader-depot
check, iscript, cloud/stats sync, controller config), reaper -> exe 2.6-3.0 s (pressure-vessel 0.6, Proton's Python
0.7, Wine boot 1.6), exe -> window 1.0-2.0 s, window -> frame 8.2-8.5 s (game-internal hand-off above). The last stage
alone is 8 s, so a FRESH launch of this Unity game can't reach 10 s from the PowOS side; < 10 s holds for the
return-to-a-left-game path (freeze/resume, 0.6-0.8 s). Not done (evaluated): a pre-warmed container + wineserver per
prefix (saves at most ~2 s of reaper -> exe; a wineserver outside Steam's reaper makes Steam show the game running,
and the game-resume freeze keys on Steam's tree); unity-screen's Python (55 ms, not worth it).

## Unity window -> frame: the emulated main-thread time by symbol, TSO A/B (2026-11-05, agent/fex-mono-start)

Broforce 274190, `powos-proton-arm64` (steam -36). Instrument (scratch `fms-run.sh`/`fms-watch.sh` around `bf-coldstart
steam`, job 20261105-174324): `simpleperf record -a --call-graph fp` 13 s from the exe, with `FEX_LIBRARYJITNAMING=1
FEX_BLOCKJITNAMING=1` (proton-settings.json). Proton ARM64's arm64ec FEX writes the perf map to the chroot's
`/tmp/perf-<linux pid>.map` (37 MB: guest `<dll>+0x<rva>` per file-backed block, `JIT_0x<guest rip>` per anonymous
block); joined offline with the host NDK's simpleperf_report_lib, FEX's own samples symbolised from
`libarm64ecfex.dll`'s COFF symbol table (llvm-nm; it has one). Naming makes FEX compile more (frame 19.2 s), so the split
below is from that run; the warm FEX split is from job 105337 (symbolised the same way).

| main thread, 13 s | s |
|---|---|
| FEX compile (warm 0.85 s: RA `TryPostRAMerge`, `GenerateIR`, `FlushRegisterCache`, `AddBlockExecutableRange`) | 1.94 |
| kernel (page faults 0.28, server round trips write/writev/readv ~0.6, futex 0.19, mmap 0.14) | 1.64 |
| UnityPlayer.dll emulated (named 0.52 + ~1.0 in blocks not in the map) | ~1.5 |
| mono.dll emulated (runtime, JIT compiler, bdwgc) | 0.57 |
| Mono JIT output (anonymous, managed code) | 0.39 |
| Wine ntdll (dll + so) + vdso clock_gettime | 0.79 |

- **Managed code is small**: Mono's JIT output runs 0.39 s and mono.dll 0.57 s on main; the emulated time is mostly
  UnityPlayer's own native init. Mono AOT can't apply (Unity 2017.4's embedded mono.dll, no AOT/`MONO_ENV_OPTIONS` for
  an embedder), and the managed share it could cut is < 0.5 s anyway.
- **Main idles while UnityPreload works** (sample bins: one 1 s span with 11 main samples and UnityPreload 76 %), and in
  the last ~3 s main is 25-30 % busy (the GPU work agent/load-uploads saw): the hand-off, not one slow loop.
- **The main thread's server calls are mostly Steam's**: of 58k wineserver requests by the main thread before the first
  frame (job 104344's +server log), ~35k are `steam_api64` `SteamAPI_IsSteamRunning` polls - HKCU\Software\Valve\Steam\
  ActiveProcess `pid` + open_process/get_process_info, ~80/s during the load and ~150/s in play, each 23 requests
  because Wine probes `Wow6432Node` after every path component. ~0.4 s of main's kernel time; only a Wine registry change
  (client-side cache / no per-component Wow6432Node probe for a non-WoW64 process) would cut it - a Proton ARM64 build; done in the next
  section (agent/steam-poll).
- **TSO off: no gain** (warm cache, `FEX_TSOENABLED=0` + `FEX_DISKCACHEPRUNESTALEENTRIES=0` so the base cache survived;
  jobs 175352..175445), exe -> frame ms:

  | variant | runs | mean |
  |---|---|---|
  | base | 10639, 10648 | 10.64 s |
  | TSO off | 10579, 10792, 10676, 10487 | 10.63 s |

  So the emulated code isn't barrier-bound; with no gain there is no reason to take Unity/Mono's memory-ordering risk.
  Proton's Config.json already has Multiblock 1, MaxInst 500 (FEX's Mono hacks need both), X87ReducedPrecision 1.
- Note: the FEX disk cache dir hash isn't keyed on the JITNaming options (the naming run wrote into the base dir), but a
  TSO change is a new dir, and a launch with prune on deletes the other dirs - A/Bs of cache-keyed FEX options need
  `FEX_DISKCACHEPRUNESTALEENTRIES=0` and a warm-up run per variant.

Nothing ships (no knob cleared 0.5 s). What is left of window -> frame is UnityPlayer's native init on main (~1.5 s
emulated), FEX compiling Mono's fresh JIT output every launch (~0.85 s, uncachable by design), kernel/server calls
(~1.6 s, ~0.4 s of it Steam's IsSteamRunning polls) and the main <-> UnityPreload / GPU hand-off waits. Fresh tap ->
frame < 10 s stays out of reach for this game from config; the < 10 s path is resume (0.6-0.8 s).

## steam_api's IsSteamRunning polls: Wine's 32-bit-view registry walk (2026-11-05, agent/steam-poll)

Follow-up to agent/fex-mono-start's finding (~35k of main's 58k server requests before the first frame are
`SteamAPI_IsSteamRunning`). Who polls: the game. Broforce's `SteamController.IsSteamEnabled` calls
`SteamAPI.IsSteamRunning()` every time and is called from per-frame/per-string paths (LanguageManager,
SteamControllerUser.get_Name, DesktopPlatform, FileIO; found by IL scan of Assembly-CSharp.dll). Steam IS seen as running
(ActiveProcess pid 0x20 = steam.exe, exit_code 259 = STILL_ACTIVE in the +server log of job 104344), so nothing on the
Steam side makes the game poll less - (b) has no lever.

Why each poll costs 24 requests: steam_api64 reads `HKCU\Software\Valve\Steam\ActiveProcess` with KEY_WOW64_32KEY. For a
64-bit process Wine's **kernelbase** (not the server: it strips KEY_WOW64_32KEY for non-WoW64 processes) emulates the
32-bit view itself: `open_wow6432node_parent` queries the root's name, then `open_subkey` opens every component of
`\REGISTRY\User\<sid>\Software\Valve\Steam\ActiveProcess` from the top and probes each for a `Wow6432Node` child
(open + probe + close = 3 calls per component), then `is_classes_wow6432node` queries the name again: 19 calls, + value,
close, open_process, get_process_info, close. Same code in upstream Wine master (2026-11-04) and Valve's
experimental_11.0 (which adds `is_wow6432_shared` for HKCU\Software) - not fixed anywhere.

Fix (Wine side, `targets/android/steam/proton-overlay/0001-kernelbase-wow32-direct-open.patch`): `open_key_wow32_direct`
- when no component has a Wow6432Node child (the common case) the walk's result is just the key at the plain path, so
probe each prefix's `Wow6432Node` by absolute name (1 call each, no handle to close; HKCU\Software skipped exactly as
`is_wow6432_shared` ignores it) and open the full path once: **7 calls instead of 19** (12 instead of 24 per poll).
Anything else (a Wow6432Node found or named, leading/trailing/double backslashes, OPEN_LINK, a failed open) falls back to
the unchanged walk, so results are identical. Shipping: kernelbase is a PE (ARM64X) dll and Wine loads builtins from
Proton's lib dir, not the prefix's system32 symlink, so the file in Proton itself is replaced: `build.sh` builds Valve's
own tag `experimental-wine-11.0-20261027b` (llvm-mingw 20261006, arm64ec+aarch64, tools + dlls/kernelbase only, ~10 min
first time, docker volume powos-steam-poll-wine) -> pkgs/steam/proton-arm64-kernelbase.dll (gitignored, build-inputs
cache); steam -37 ships it in the powos-proton-arm64 tool dir and `arm64-gate-entry` swaps it in only while Proton's file
is that exact Valve build (sha256; Valve's kept as `.valve`; a Proton update is left alone until rebuilt). A full Proton
rebuild was not needed. Re-basing on a new Proton: bump TAG, rebuild, update the two hashes (~15 min).

A/B queued (jobs 20261105-183239..183312: bf-pacing base on Valve's dll, then the PowOS dll: bf-coldstart steam x2,
bf-pacing base, bf-checker base, Valve's restored). Expected: ~1800 fewer wineserver requests/s in play (150 polls/s x
12), ~0.2 s of main-thread load time.

**Result (steam -37 installed, jobs 20261105-192135..192142):** the gate put the PowOS kernelbase in on the first launch
(sha a3f08252, checked after each run). bf-coldstart steam, Valve dll: exe -> frame 10.8 s (frame 20.6 s from the tap),
wineserver 0.8 core-s, main 6.4 s; PowOS dll #1 (first launch with the new dll: FEX re-stored blocks) wineserver 2.7,
#2: exe -> frame 10.8 s (frame 19.1 s), wineserver 0.7 core-s, main 6.8 s. bf-pacing base 40.4 -> 41.2 fps, main thread
29.2 -> 29.5 %, wineserver not among the top threads in play either way; bf-checker base 0 % checkered. So the call
count halves, but it costs no measurable time on this phone: the ~0.4 s estimate did not hold. Kept, since it is exact
and cheap; not a fps lever. Requests/s not counted directly (+server would distort the timing).

## Unity window -> frame: sync path, thread placement, CPU topology, render thread (2026-11-05, agent/unity-sync)

Broforce 274190, `powos-proton-arm64` (steam -36), `bf-coldstart steam` + a 50 Hz sampler of main/UnityPreload (state,
syscall, CPU; scratch `us-run.sh`/`uswatch.py`, jobs 20261105-153856..155313). Window -> first frame, ms:

| variant | run 1 | run 2 | mean | vs base |
|---|---|---|---|---|
| base | 8684 | 8358 | 8521 | - |
| `WINE_CPU_TOPOLOGY=5:3,4,5,6,7` (5 big cores, Wine maps + pins) | 8373 | 8333 | 8353 | -0.17 s |
| all game threads pinned to 3-7 at exe start | 8514 | 8377 | 8446 | -0.08 s |
| main + UnityPreload pinned to 3-6 (one cpufreq domain, A715+A710) | 8675 | 8399 | 8537 | 0 |
| Unity `-force-gfx-direct` (no render thread) | 8407 | 8445 | 8426 | -0.10 s |

Nothing clears the 0.5 s bar (run-to-run noise is ~0.3 s), so nothing ships. Findings:
- **ntsync: not available.** Kernel 5.15.180 GKI, no `/dev/ntsync`, no CONFIG_NTSYNC (mainline 6.10, usable 6.14); and
  Proton Experimental `11.0-20261027b-arm64`'s ntdll has no ntsync support either (fsync only). A backport would be a
  separate task: an out-of-tree ntsync.ko for this 5.15 (CONFIG_MODULE_SIG set but not forced) plus a Wine/Proton
  ARM64 build with the ntsync client. Expected gain is small anyway (see the gfx-direct point below).
- **Placement is already good.** Unscheduled, main is on 3-7 ~100 % of the time (X3 core 7 29-36 %), UnityPreload on
  little cores 2-6 %; both migrate a lot (main ~300, UnityPreload ~170 per 16 s), but pinning them (to 3-7 or one
  cpufreq domain 3-6) leaves the wait share unchanged (main W449 34-39 %, UnityPreload 57-63 %): cross-cluster wake
  latency is not the cost. Note Proton on aarch64 already derives WINE_CPU_TOPOLOGY from its own affinity
  (`get_current_cpu_affinity`), so a launcher affinity is the one knob if it ever pays.
- **Main's futex_waitv is the render thread, not UnityPreload.** With `-force-gfx-direct` UnityGfxDeviceWorker is gone
  and main's Wine-sync wait drops 39 % -> 6 %, but the same time reappears as plain futex (syscall 98, 28-31 %): DXVK's
  own cs/submit threads' condition variables. So main is waiting on the D3D11 -> DXVK -> Turnip path (uploads/
  resource creation during load) whichever thread drives it; the window->frame stays 8.4 s. Next lead: what DXVK's cs
  thread is doing then (DXVK_HUD/`DXVK_LOG_LEVEL=debug` timings, Turnip BO alloc/upload cost on kgsl), not Wine sync.
- Unity 2017.4 boot.config has only `wait-for-native-debugger=0`; gfx-jobs options are left untested (render-side
  experimental path in 2017.4, visual risk, and the wait is in DXVK either way).

## Unity window -> frame: what the render path does during the load (2026-11-05, agent/load-uploads)

Broforce 274190, `powos-proton-arm64` (steam -36), DXVK v3.1.1-97 (Proton Experimental ARM64, aarch64 build), Turnip
with `TU_DEBUG=noubwc`. `bf-coldstart steam` + a 20 Hz sampler from the exe's start (scratch `lu-run.sh`/`luwatch.py`):
kgsl `gpu_busy_percentage` + `gpuclk`, the state/syscall/wchan of main, UnityGfxDeviceWorker, dxvk-cs, dxvk-submit,
dxvk-queue, UnityPreload, and (one run) the DXVK debug log timestamped as it is written. Jobs 20261105-162655..163940.

**The render path is idle for most of the 8.5 s.** Seconds from the exe (window ~1-2 s, first frame ~9.5-10.5 s):

| span | GPU busy | GPU clock | dxvk-cs / submit / queue | main | DXVK log (debug) |
|---|---|---|---|---|---|
| 0-6.5 | **0-4 %** | 220 MHz (floor) | futex-idle 100 % | running ~90 % (3-7 s), Wine-sync waits at 1.5-2.5 s | 145 shader creates, all "Shader cache hit"; swapchain at 5.6 s; 5 memory chunks mapped |
| 6.5-10.5 | 11-43 % | 220 MHz | queue: `adreno_drawctxt_wait` (GPU fences) ~25 % | Wine-sync waits ~60 % | a few shaders |
| after the frame | 55-80 % | 295-680 MHz | | | |

So it is not uploads, staging allocations or pipeline compiles: over the whole launch DXVK logs no pipeline compile,
only 5 chunk allocations (`Mapped memory region`), dxvk-cs/submit are 85-87 % futex-idle (waiting for work), and the
GPU does nothing until ~3 s before the first frame. The UBWC-off linear path can't matter either (no GPU work to slow
down). Main's 39 % Wine-sync wait (agent/unity-sync) falls mostly in the last ~3 s, where UnityGfxDeviceWorker waits
on DXVK (plain futex) and DXVK's queue thread on GPU fences: the first frames' GPU work, at the 220 MHz floor (the
msm-adreno-tz governor ramps only after the frame). Before that, main runs emulated Mono/Unity code (the previous
sections' cost); the dxvk.conf knobs (`d3d11.cachedDynamicResources`, `dxvk.numCompilerThreads`, staging size) have
nothing to act on.

**GPU floor during the load (A/B, `min_pwrlevel` 7 -> 2 = 550 MHz from the tap, restored after):**

| variant | window -> frame run 1 | run 2 | mean |
|---|---|---|---|
| base | 8615 | 8479 | 8547 |
| GPU min 550 MHz | 8299 | 8316 | 8308 (-0.24 s) |

GPU busy in 6.5-10.5 s drops to 12-40 % at 550 MHz but the frame comes only ~0.24 s sooner: under the 0.5 s bar and
inside run-to-run noise (~0.3 s), so nothing ships (it would also cost GPU power for every game launch). Conclusion:
**window -> first frame is CPU on Unity's main thread (emulated Mono/Unity init), not the D3D11 -> DXVK -> Turnip
path.** Next lead, if any: the emulated code itself (FEX: Mono's JIT output is uncachable; Unity 2017.4 player init) -
e.g. FEX `SMCChecks`/`Multiblock`/`ParanoidTSO` costs on main, or simpleperf of main's JIT blocks by Mono symbol.

## Per-phase timeline now, and the page-cache read-ahead from the tap (2026-11-09, agent/game-launch-time)

Best current run (bf-coldstart steam, 11-07 04:37, job 20261107-032738-52211; steam -39, Broforce on `powos-proton-arm64`,
Steam awake at the tap), seconds from the tap (4 Hz process samples + LPROF):

| phase | from -> to | s | what |
|---|---|---|---|
| launcher | tap -> Steam handoff | 0.8 | powos-open-task -> Steam's URL |
| Steam prep | handoff -> reaper | 3.2 | Steam's own (iscript gate skipped at ~3.0 s, cloud/stats sync, CreatingProcess) |
| container | reaper -> pv-adverb/Proton/wineserver | 1.5 | pressure-vessel (no localedef since Fix 2) |
| Wine boot | wineserver -> game exe | 3.9 | wineboot --init -> services/winedevice/plugplay (6.4) -> svchost (7.4) -> explorer/rpcss/tabtip (8.3) -> exe (9.4) |
| engine init | exe -> X window | 1.1 | Unity player init |
| first scene | window -> first frame | 8.8 | black window; main ~95 % busy 10.1-16 s (emulated Unity/Mono), then render hand-off |
| **total** | | **19.3** | goal < 10 s |

Every phase is slower than the 11-05 runs (frame 15.7-16.9 s: pv 0.6, Wine boot 1.6-2.6, window->frame 8.2-8.5) and
LPROF shows why: clocks `?/1785/1651/1363` MHz the whole launch - horae's cap held the prime core at 1.36 GHz of 3.19
while the launch is one CPU-bound thread. That lever is task game-boost-loses-to-a-vendor-cpu-cap (oplus-hook in
com.oplus.battery), not repeated here. The board's suspects are not on this path any more: no FEX RootFS (ARM64 Proton,
arm64ec FEX in-process), FEX's DiskCache persists and hits (49632 KB before and after the launch), and the
IsSteamRunning poll fix (steam -37) measured no change (above). Of what's left, I/O is the one PowOS-side cost that
grows with idle time: this run read **68 MB from storage** during the load (11-05's back-to-back runs: 0 MB), and a game
not run since boot reads its whole load (~300 MB for Broforce) cold, in page faults on the emulated main thread.

**Cut: read-ahead from the tap.** `powos-open-task` (drawer/widget/shortcut launch path, every Steam game) finds the
game's install dir (appmanifest_<id>.acf in any library of libraryfolders.vdf) and issues `posix_fadvise(WILLNEED)` on
its files in a thread - code first (.exe/.dll/.so/configs), then data smallest-first - capped at 1 GB and a quarter of
MemAvailable (`POWOS_LAUNCH_PREFETCH_MB`, 0 = off). It runs during Steam prep + container + Wine boot (~8.6 s with no
game I/O), so the engine's reads hit the page cache. Asynchronous kernel readahead: nothing copied or written, cache
stays reclaimable, every error ignored. HACK row: Valve's client could read ahead the depot while it prepares the launch.
Test: test/tier1/test-open-task-prefetch.py.
Expected: warm (back-to-back) launches ~0; after idle 0.3-1 s; first launch since boot more (the cold ~300 MB read
moves off the critical path). Check after merge: `bf-coldstart.sh steam` with the page cache dropped first
(`echo 1 > /proc/sys/vm/drop_caches` as root) vs today's 19.3 s, read_bytes in LPROF-SUM -> ~0 MB.

Ranked next cuts: (1) the clock cap (other task; 11-05's caps-lifted A/B: tap->frame 14.8/16.2 vs 18.5 s); (2) Wine
boot 2-4 s - wineboot waits on every auto-start service (winedevice drivers, svchost) serially; a prefix pre-booted
while Steam preps needs Proton's `waitforexitandrun` not to wait on that wineserver (`run` verb in powos-proton-arm64's
entry) - big, needs device iteration; (3) window->frame 8.8 s is the game's own emulated init: < 10 s for this Unity
game fresh is not reachable from PowOS alone; resume (0.6-0.8 s) is the < 10 s path.

## Why the boost lost to the vendor cap at launch (2026-11-09, agent/game-boost-cap)

Who writes scaling_max_freq: only `horae` (thread horaeCb, holding every policy's limits open), applying
com.oplus.battery's ThermalControllHandler policy; it rewrites on each evaluation (a temperature gear change or a
front-package change) - minutes apart, not a fight. The holder never raised it (under horae it keeps the cap and holds
the prime min up to it: 0 fights in every 11-08/09 log). The cap at launch was the wrong TABLE, not heat: the holder log
shows `thermal cap 1785600 / 1593600 by horaeCb, skin 28.1 C` (21:29, 11-08) = `thermal_cpulevel` level 4 = common_config
at gear 6-7, and the 19.3 s run's 1.36 GHz = level 5 = common_config gear 8-10. game-boost.sh sets the vendor game
marker at the tap and the oplus-hook answers appType 4, but the controller only asks on its next evaluation; the front
package stays com.powos.app for the whole launch, so category_4 arrived at the next gear change (11-06: 2 min in).
category_4 vs common_config (folding profile): gears <= 4 no cap (common: level 2 from gear 3), gears 5-6 level 1
(prime 1.98 / gold 2.19 GHz; common: 3-4 = 1.71-1.59 / 1.92-1.79), gear 7 level 3, 8-9 level 4, 10 level 5.

Fix (oplus-hook `reevaluateOnMarker`): a ContentObserver on Settings.Global powos_game_front in com.oplus.battery runs
the controller's own category evaluation (jadx of Battery.apk 16.0.5.1301: `ThermalControlUtils` app switch ->
`m.M0(ctx).q1()`) on its handler thread, on and off. No thermal limit is touched: the vendor's game table, at the
vendor's own temperature gear, sets the cap; a hot phone stays capped. Off goes back through the vendor's protect
period. Test: test-game-boost-holder.sh (marker on from the hold's start and off after, min follows a lifted cap, a
lowered cap stands; polls instead of fixed sleeps - it flaked on .58 under load).
Expected: prime 1.98-3.19 GHz instead of 1.36-1.59 for the launch on a phone at gear <= 6; per the 11-05 caps-lifted A/B
(14.8/16.2 vs 18.5 s) ~2-3 s off tap -> frame, 19.3 -> ~16-17 s. Check: `bf-coldstart.sh steam` after the ship (needs
the oplus-hook APK installed and com.oplus.battery restarted), LPROF clocks + logcat `configItemName=category_4` at the tap.

## 11-11 regression: Broforce tap -> window 55.4 s / frame 62.9 s (agent/launch-regress)

Job 20261111-140919-1279 (game-fps-counter, bf-return-phone launch, Steam resident + sleepable), read off Steam's
console_log/connection_log + compatdata/274190/powos-iscript.log; t0 = 14:54:38 (window 55382 ms after it):

| phase | 11-07 (s) | 11-11 (s) | what |
|---|---|---|---|
| launcher -> handoff (ExecCommandLine) | 0.8 | ~13 | /usr/bin/steam's forward waits for Logged On: Steam's CM link was dead (Disconnected By Remote Host 14:53:19, GetCMListForConnect failed twice, reconnect backoff 8/16/26 s; logon 14:54:51) |
| Steam prep (handoff -> evaluator) | 3.2 | ~10 | post-logon work right after the reconnect (CheckShaderDepotManifest, "Waiting for compat in post-logon" 1.5 s) |
| install script evaluator | skipped | 22 | powos-iscript.log "running it (input changed)" 14:55:03 -> "exited 0, recorded" 14:55:23 |
| cloud/stats/CreatingProcess -> reaper | (in prep) | 2 | |
| reaper -> window (pv + Wine boot + init) | 6.5 | ~8 | unchanged within noise (unity-screen's `/bin/sh -c` wrapper visible, costs nothing) |
| window -> first frame | 8.8 | 7.5 | unchanged |

The window->frame and reaper->window phases (unity-screen a612f179/cb6fa290, KWin 3.79, collect_dmabufs 44804a4f) did
NOT regress. The evaluator ran because Steam auto-updated **Proton Experimental (ARM64)** at 04:17 (its `version`
mtime) and the skip's key hashed Proton's version: every game's first tap after a Valve Proton update paid a full
evaluator Wine boot (ABZU 13:51:22-43 the same way - that is why bf-pacing saw no window in 20 s). Not a PowOS commit.
Fix (steam pkgrel 42, user_settings.py): the key = script bytes + prefix inode only (the marks the evaluator checks
live in the prefix registry; a Proton update keeps them, a rebuilt prefix changes the inode / creation_sync_guard);
old-format records still match and are rewritten. Test: test-steam-iscript-skip.py (Proton update still skips, old
record honoured). The dead CM link after a freeze (~13 s + ~7 s of post-logon prep) is the open unified-sleep item
from 10-24 ("keeping a frozen Steam's CM link alive"), unchanged: manager decision.

## 11-11 cold start after Steam 42 (agent/bf-launch-1111)

Job 20261111-154535-55790 (`bf-coldstart.sh steam`, 21:16, steam 1.0.0.87-42, build 7e731aa1; artefacts
`~/.cache/powos-verify/bf-coldstart-2026-11-11_2115/`): **window 12.4 s, frame 21.4 s**. Steam was *frozen* at the tap
(11-07/11-09: awake); the phone was folded (outer screen, 1116x2484) and idle 814 s before the job. Phases from each
run's STAGES line (ms from the tap; the 11-07 table above used slightly different cut points, so 11-07 is re-read here):

| phase | 11-07 04:36 | 11-09 16:39 | 11-11 21:16 | what changed |
|---|---|---|---|---|
| launcher (tap -> handoff) | 0.8 | 1.1 | 1.3 | Steam thawed from frozen first |
| Steam prep (handoff -> reaper) | 3.2 | 2.0 | 3.4 | evaluator **skipped** (iscript 2.8-3.3 s, "skipped before the container ... as at its last good run"): the pkgrel 42 key fix holds |
| container (reaper -> wineserver) | 1.5 | 1.4 | 2.3 | |
| Wine boot (wineserver -> exe) | 2.9 | 1.8 | 4.2 | |
| engine init (exe -> window) | 2.1 | 2.3 | 1.2 | |
| window -> first frame | 8.8 | 8.3 | 9.0 | |
| **tap -> frame** | **19.3** | **17.0** | **21.4** | goal < 10 s |
| prime clock (LPROF, MHz) | 1363 flat | 864-2227, governor-driven | 1363 flat | |
| read from storage during load | 68 MB | | 238 MB | |

**Boost: no lift.** LPROF read `?/2016/1651/1363` MHz in all 42 samples (10.8-21.5 s) - the prime held at 1.36 GHz, the
same level-5 cap as 11-07 before the oplus-hook fix; 11-09 16:39 (3 min after the fixed hook APK was built) ran the prime
up to 2.23 GHz and got 17.0 s. Whether the holder engaged, set `powos_game_front`, and whether com.oplus.battery
answered `category_4` is **not in the evidence**: bf-coldstart recorded no boost status, holder log or vendor logcat. The
precondition is **unverified**: the fixed APK (`android-app-dev/output/powos-oplus-hook.apk`, 11-09 16:36, after
ded11835's NPE fix) exists, but the only recorded device deploy (REMOTE-POWOS.md 4.1) is 11-04's b05e2a6a build, which
predates `reevaluateOnMarker` - no install/restart of com.oplus.battery is logged since. A flat 1.36 GHz also fits
category_4 at gear 10 (a hot phone), or the folded-profile table; the run alone can't tell them apart.

Code read (no defect found): powos-open-task writes run/game-launch/<id> at the tap, GameBoost engages a fresh mark
(LAUNCH_S 60 s) while the screen is interactive, game-boost.sh sets the marker under horae (`vendor_game_class`), and the
hook's ContentObserver re-evaluates on it. No code fix without device evidence.

**Fix (measurement):** `bf-coldstart.sh` now pulls the boost's evidence after each run into `boost.txt` and prints a
`BOOST holder: engaged|no holder line; hook <versionName lastUpdateTime>; battery_started <STIME>; category: N
configItemName=...` line (holder log since the check began, `dumpsys package com.powos.oplushook`, com.oplus.battery's
start time, ThermalControllHandler + PowOS-oplushook logcat since the check began). Read-only, Android side.

Why the 2.1 s over 11-07 (same clocks): Steam frozen at the tap (+0.5 s thaw, steamwebhelper 72 % of a core at the start)
and a cold page cache - 238 MB read from storage during the load vs 68 MB, landing in container + Wine boot (+2.1 s);
engine init and window->frame are within noise. So the tap read-ahead (powos-open-task prefetch) did not cover this
launch, or was not on the phone's copy (the STAGES "open-task:" field is truncated).

Next lever, in order: (1) install the 11-09 oplus-hook APK + restart com.oplus.battery (logged in REMOTE-POWOS.md 4.1),
then rerun `bf-coldstart.sh steam` and read the BOOST line - expected ~17 s like 11-09 16:39; (2) check the prefetch ran
(read_bytes should be ~0 MB, not 238 MB); (3) the frozen-Steam thaw at the tap (~0.5 s) and Wine boot pre-boot (above).

### 11-11 22:15: the hook works; the cap is not the vendor's category table (agent/boost-cat)

Re-read of the 21:30 bf-coldstart (`BOOST holder: engaged ... category: -`), read-only on the phone:
- **Module active in com.oplus.battery.** Vector 2.2 (`/data/adb/lspd/cli modules ls` / `scope ls com.powos.oplushook`):
  enabled, scope `com.android.systemui` + `com.oplus.battery` (no `com.android.launcher`: separate gap for the launcher
  hooks). Vector's own log (`/data/adb/lspd/log/modules_<boot>.log`) has the battery process 30626 (started 11-10
  02:35:22) loading the 11-09 APK: `gameClass: hooked G`, `the category is evaluated on every powos_game_front change`.
- **The trigger fires.** game-boost.sh writes `Settings.Global powos_game_front` (VENDOR_GAME_KEY) and Hook.java observes
  the same key; every engage since 11-10 has the pair `marker steam_app_<id>, category evaluated now` (main thread) +
  `com.powos.app appType 4 (... boosted)` on thread 30922 = thermal_Controller_thread, i.e. q1() ran and asked the
  hooked lookup. 21:32:51.067 on, 21:33:05.045 off. So the vendor DID evaluate with appType 4.
- **"category: -" was logcat's wrap, not the vendor.** The main buffer is 256 KiB = ~1 min on this phone; the probe ran
  minutes later. No ThermalControllHandler line from 21:32 survives anywhere.
- **Root cause: the 1363/1651 MHz clamp is not ThermalControllHandler's table.** Every holder engage since the 11-10
  01:16 boot logged `policy3 1651200 / policy7 1363200 by horaeCb` at skin 24.5-39.4 C (e.g. 17:06 at 27.8 C) - flat,
  temperature-invariant. Right now (22:13, phone idle) the vendor logs `tempGear=[1], configItemName=common_config`
  and the clamp is still policy3 1651200/2803200, policy7 1363200/3187200, policy0 uncapped. In
  `/odm/etc/temperature_profile/sys_thermal_control_config_folding.xml` neither `common_config` (first cpu entry
  gear 3) nor `category_4` (gear 5) caps anything at gears 1-2, so switching category cannot lift this clamp - the
  hook is doing its job against the wrong lever. Before that boot (11-08 17:11 .. 11-09 23:27) the cap moved with
  temperature/boost (1593-3187 MHz, the 11-09 16:39 run reached 2.23 GHz); the 1363 values then came at 41-43 C.
  The values match thermal_cpulevel 5's big clusters (policy0's 1459200 not applied). Who holds it is still open:
  Battery.apk's other horae users (`ThermalControlUtils` transacts: pkg name, folding mode 24, IPA 107, levels 108),
  the PowerSave CpuLevelConfig (only with low_power=1: it is 0), OPlus perf HAL / ORMS / osense (`oplus_perf_service`,
  `osensemanager`). A cap left from the 41-43 C stretch that the controller's release path (V1/U1 at gear < 3) never
  cleared fits the "flat since the hot hour" pattern.
- Second finding: the holder releases at the WINDOW (restore asked 21:33:04, ~13 s), the first frame came at 21.4 s;
  the boost does not cover window -> frame (~9 s). GameBoost's end condition, separate fix.

Fix landed (measurement): bf-coldstart's boost probe now reads the hook lines from Vector's module log since the
check began (`hooklog`) and prints the clamp after the run (`clamp_after policyN=max/hw`); the BOOST line counts the
hook's appType-4 answers. Test: test/tier1/test-bf-boost-probe.sh. No hook or holder code change: neither is wrong.
Next (device, read-only first): find the clamp's writer - `dumpsys oplus_perf_service` / `osensemanager`, horae's
binder clients, and whether a com.oplus.battery restart (the coordinator's call) clears the flat 1363 at gear 1; if it
does, the cause is a stuck release after a hot gear and the hook can call the controller's release (V1) when the
marker goes on at gear < 3.

### 11-11 23:00: the launch boost holds to the first frame (agent/boost-hold-frame)

GameBoost.LaunchHold: a launch is the game in front from its tap until its **first frame** - its window task in front
presenting new frames on 2 ticks in a row (`PowosWindowActivity.frontPresents`, the fps meter's counter; a map/clear of
Wine's window is one or two presents) - or 30 s after its window with none (`FRAME_CAP_S`), or 60 s after the tap with
no window (`LAUNCH_S`). Neither the launch mark going (powos-open-task drops it, or it ages out on a 55 s iscript launch)
nor the front task reading null / a non-game while Unity re-creates its window ends it any more; screen off, another
game in front and the holder's game-gone exit still do. Test: GameBoostTest.aLaunchIsBoostedToItsFirstFrameNotItsWindow
(control with the old mark-only front: FAILS; now passes) + aLaunchHoldEndsAtItsCaps; jvm-offload on .58.
Evidence caveat (re-read of bf-coldstart-2026-11-11_2130/boost.txt, same phone clock as run.txt's pills): the holder
log has `clocks restored` at 21:32:19 (tap 21:32:01, window 12.7 s, frame 21.4 s: a release ~2 s before the frame),
then the `boost` engage at 21:32:51 (50 s after the tap) and `restore asked` at 21:33:04 = the check closing the game -
the "restore at ~13 s" above was the close, and no engage line at the tap is in the log. Next run's BOOST line should
show one engage at the tap and `launch hold released: its first frame` in the app's PowosGameBoost log.

### 11-11 23:45: Steam's reconnect off the launch path (agent/steam-cm)

Job bf-coldstart-2026-11-11_2327 (`steam`, Steam FROZEN at the tap): **handoff 9.6 s, window 21.4 s, frame 30.0 s**
vs 12.7 / 21.4 s with Steam awake. Read-only off the phone (connection_log + powos-sleep-gui.log):
- Steam frozen 23:26:34, screen dark until the check woke it for the tap at 23:28:09 (95 s). The server had dropped the
  silent client (79 s into a freeze, measured 11-05): `Disconnected By Remote Host` 23:28:09, `StartAutoReconnect()
  will start in 7.0 seconds (attempt 1)`, GetCMListForConnect 23:28:16-18, Logged On 23:28:19 = the 9.6 s handoff
  (/usr/bin/steam's forward waits for Logged On; skipping that wait is unsafe: the 10-24 cloud "syncfailed" prompt).
- link_watch's keepalive pulse (1.5 s every 50 s) ran only while a display was lit, so 95 s dark = a dead link. Its
  screen-on "reconnect ahead" fired at 23:28:09 together with the tap: no overlap. All reconnects logged on 11-11 took
  5.0 / 21.4 / 25.6 / 23.6 / 9.5 s (attempt-1 delay is Steam's 7-22 s) - a user's wake -> tap (a few s) can never
  hide that, so thawing earlier (games page, icon touch-down) can't either: the link must not die.
- Decision (coordinator, b): the keepalive pulse also runs for 15 min after the screen went dark
  (`POWOS_SLEEP_LINK_DARK_S=900`, wall clock), pulses only (no ~25 s reconnect while dark), nothing past the window.
  Power: <= 18 pulses x 1.5 s per dark period, and GLib timers never wake a suspended phone (5580 suspends since boot),
  so a pulse only rides wake-ups that happen anyway. A tap more than 15 min after the screen went dark (or after a long
  suspend) still pays the reconnect, from the screen-on reconnect-ahead (unchanged).
- Test: test/tier1/test-sleep-gui-screen.py LinkWatch.test_dark_screen_keeps_the_link_for_a_while (+ past-window costs
  nothing, lit restarts the window); control with the old link_watch: FAIL + 2 ERROR; now 18/18 (tier1 on .58).
- Expected: `bf-coldstart.sh steam` handoff ~1 s (11-09: 1.1 s), frame ~21 s; still above the 10 s goal - the rest is
  container + Wine boot + window -> frame (resident game = the instant path).

### 11-11 23:43: did the tap's prefetch cover the load? Window -> frame split (agent/bf-prefetch)

Job 20261111-233653-94113 (`bf-coldstart.sh steam`, artefacts `~/.cache/powos-verify/bf-coldstart-2026-11-11_2339/`),
Steam awake at the tap: handoff 1.2, reaper 3.0, pv 3.8, wineserver 4.7, exe 6.7, **window 8.8, frame 17.5 s**. Read-only
re-read of LPROF + the 21:16/21:30/23:27 runs (same powos-open-task pushed by every job, prefetch code in):

| run | game read | from storage | storage reads when |
|---|---|---|---|
| 21:16 (idle 814 s before) | 280 MB | **238 MB** | 15 MB by the exe (10.7 s), 130 MB in the asset load 17.8-21.4 s |
| 21:30 (14 min after 21:16) | 251 MB | 193 MB | 110 MB in 19.0-20.8 s |
| 23:27 (Steam frozen, handoff 9.6 s) | 248 MB | 2 MB | |
| 23:39 (12 min after 23:27) | 328 MB | 20 MB | ~8 MB by 11.6 s, ~12 MB in the asset load 13.7-17.4 s |

**Verdict (1): the prefetch ran but read almost nothing.** It had 18 s before the 21:16 asset load and the 1 GB /
quarter-of-MemAvailable cap (6.3 GB available -> 1 GB) fits Broforce's whole 526 MB dir, so neither the cap nor the order
was the problem: the kernel clamps every `fadvise(WILLNEED)` (and `readahead(2)`, `MADV_WILLNEED` on a file) to
max(read_ahead_kb, max_sectors_kb) of the file's bdi (5.15 `force_page_cache_ra`); /data (dm-79, bdi 254:79) has 512 KiB
for both, so the one `fadvise(fd, 0, 0)` per file read its first 512 KiB - 0.4 % of scenesmain (138 MB) /
sharedsounds (144 MB) assetbundles, 2 % of UnityPlayer.dll (22 MB). The 23:27/23:39 low numbers are the page cache
left by the run before, not the prefetch.
Fix (`powos-open-task` `readahead_whole`): WILLNEED one bdi window per call over the whole file (window from
`/sys/class/bdi/<maj:min>/read_ahead_kb`, 128 KiB if unreadable; ~1000 async calls for 526 MB), and the game's
`steamapps/shadercache/<appid>` (FEX DiskCache .foz ~50 MB + Mesa cache, 85 MB here) right after the code, before the
data; logs `powos-open-task: prefetch N files M MB queued in X ms` to stderr. Test: test-open-task-prefetch.py
`test_whole_file_is_read_ahead_not_just_one_window` (kernel clamp modelled; FAILs on the old one-call code) + caches
order. Not prefetched: Proton ARM64's runtime (`files/lib/wine/aarch64-windows` alone is 713 MB, read by wineboot/
services, not the game; which files is not in the evidence - LPROF counts only the game's read_bytes).
Expected: a cold-cache launch (the 21:16 case) loses most of its 238 MB from storage (-> < 20 MB), worth ~1-2 s (21:16
was +2.1 s over 11-07 in container + Wine boot + exe, part of it Proton's own files); a warm launch ~0. Check: queue
`bf-coldstart.sh steam` after the phone sat (or with `echo 1 > /proc/sys/vm/drop_caches` first): LPROF-SUM "from
storage" and the prefetch line in the open-task output.

**Split (2): window 8.8 -> frame 17.5 s (8.65 s), LPROF 4 Hz, clocks `?/2016/1651/1363` = the prime clamp all along.**

| span (s from the tap) | s | what | evidence |
|---|---|---|---|
| 8.8-9.8 | 1.0 | UnityPreload alone 76-84 %, main idle | com.powos.app 42 % / plasmashell / steamwebhelper busy (window task going live) |
| **10.0-13.7** | **3.7** | **Unity main thread, one core 69-99 %: emulated Unity/Mono player init under FEX** | rd flat 41.6 -> 50 MB, storage 5.6 -> 8.3 MB, GPU path idle |
| 13.9-17.5 | 3.6 | first scene load: UnityPreload 15-72 %, main 26-41 %, GfxDevice 7-15 %, dxvk-cs/submit <= 11 % | rd 50 -> 328 MB at 1.1-2.2 cores; only 12 MB of it from storage |
| sum | 8.65 | game 11.1 core-s (main 6.5, UnityPreload 2.0, GfxDevice 0.7) | wineserver 0.8 core-s; shader caches +12 KB (DXVK/Mesa all hits; dxvk-shader 15 % in one sample) |

Disk: <= 0.3 s here (12 MB in the load phase; the 21:16 run's 130 MB from storage in the same phase cost ~0.35 s of
window -> frame, 9.0 vs 8.65 s). wineserver: 0.8 core-s spread, not on the critical path. GPU shaders: none compiled.
**Biggest remaining chunk: the 3.7 s single-thread emulated Unity/Mono init on main**, at a prime core clamped to
1.36 GHz of 3.19 (the clamp writer is the open boost-cat item, out of scope here). Next lever, in order: (a) the clamp -
11-05's caps-lifted A/B gave -2 to -3 s tap -> frame, most of it this span (CPU-bound, ~2.3x clock headroom on main);
(b) nothing else PowOS-side clears 0.5 s in the window -> frame (FEX TSO/placement/GPU floor/gfx-direct all measured
below the bar on 11-05); the < 10 s path stays resume.
