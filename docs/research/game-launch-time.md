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
| kept LOCPATH (-35) | | | | | | pending re-measure after ship |

From the reaper: window -4.7 s, frame -4.5 s.

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
