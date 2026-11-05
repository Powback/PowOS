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
3. Unity window -> frame, ~8 s: the game's own load; outside our control except CPU boost at launch (game-boost.sh).
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

Install-script evaluator skip on ARM64: not extendable the x86 way. ARM64's chain before the container is
pw-audio-namespace -> reaper -> SteamLinuxRuntime_4-arm64/_v2-entry-point (/bin/sh) -> pressure-vessel-wrap - no Python
runs before pressure-vessel, so sitecustomize.py has nowhere to hook; the skip already happens (user_settings.py,
evaluator log "skipped: script, Proton and prefix as at its last good run") but only after the container (1.0-1.5 s).
An earlier skip needs a PowOS layer in front of the ARM64 runtime (a compatibilitytools.d tool whose entry point runs
the check and then execs `_v2-entry-point --verb=... -- <Proton ARM64>/proton ...`), which changes the tool
powos-steam-compat pins - not done here.
