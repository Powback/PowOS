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

## Next candidates, ranked (measure each with bf-coldstart.sh before it lands)

1. Wine boot under FEX, 8-11 s: FEX code cache (`fexcache` variant, FEX_ENABLECODECACHINGWIP=1 + FEXOfflineCompiler) -
   not yet measured with a populated cache (`fex 158 KB` at every tap = nothing cached).
2. Steam client prep on a cold Steam, 8-12 s: keep Steam resident (powos-steam-resident) so a tap skips it.
3. Unity window -> frame, ~8 s: the game's own load; outside our control except CPU boost at launch (game-boost.sh).
4. pressure-vessel locale-gen under FEX (`env:PRESSURE_VESSEL_GENERATE_LOCALES=0` candidate in steam-env), ~1-2 s x2.
