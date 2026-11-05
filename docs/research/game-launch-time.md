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
