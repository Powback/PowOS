# Broforce engine init: what can cut tap -> window and window -> frame (2026-11-12, agent/bf-engine-research)

Board task `broforce-launch-time` (tap -> first frame < 10 s, generic for every game). Question: which levers inside
the engine stack (Unity/Mono, FEX arm64ec, Wine/Proton ARM64) can cut **several seconds**? Reading list:
docs/research/game-launch-time.md (all of it; this doc does not repeat its measurements, it cites them by date).

## Where it stands (job 20261112-192132-28486, artefacts ~/.cache/powos-verify/bf-coldstart-2026-11-12_1927/)

`bf-coldstart.sh steam`, Broforce 274190 on `powos-proton-arm64` (Proton `experimental-11.0-20261105c-arm64`, its
arm64ec FEX **FEX-2610-175-geff9f45**, both updated by Steam 11-11 04:16), clocks unclamped (7dc78504: prime up to
3187 MHz in LPROF). Seconds from the tap:

| handoff | reaper | pv = wineserver | wineboot/services/winedevice/plugplay/svchost | exe (+explorer/rpcss/tabtip) | window | frame |
|---|---|---|---|---|---|---|
| 1.37 | 6.57 | 7.36 | 8.32 (first sample showing them) | 9.34 | 10.49 | 18.97 |

LPROF-SUM (window -> frame span): game 11.8 core-s on 9.6 s, main (`Broforce_beta.e`) 7.4, UnityPreload 1.8,
UnityGfxDevice 0.8; 341 MB read, 17 MB from storage; others: **steamwebhelper 3.6 core-s** (118 % at 12.0 s),
wineserver 1.9, com.powos.app 1.1.

**New fact: window -> frame does not scale with the CPU clock.** 8.48 s here with the prime at up to 3.19 GHz and the
gold cores at 2.0-2.8 GHz, against 8.65 s on 11-11 23:39 with the prime clamped at 1.36 GHz and gold at 1.65 GHz, and
8.2/8.6 vs 8.5 s in 11-05's caps-lifted A/B. The main thread reads 70-100 % "busy" (LPROF utime+stime) from 9.7 to
14.9 s either way. A thread that is busy on instructions would get ~1.5-2x faster with 2x the clock. This one doesn't,
so its "busy" time is mostly something the clock doesn't speed up: kernel entries (page faults, FEX's SMC write
faults, server round trips), spin-waits, or memory stalls. That changes how far each CPU-side lever below can reach:
**seconds removed from main's CPU profile are not seconds removed from the wall clock** until the wait part is known.
The first measurement in the plan below is there to settle this.

## Ranked levers

| # | lever | span | expected gain | generic? | risk | state |
|---|---|---|---|---|---|---|
| 1 | Wine session pre-booted at the tap (wineserver + wineboot --init + services up before Proton's `run`) | tap -> exe | **-1.5 to -2.0 s** (wineserver -> exe is 2.0 s today, 1.6-4.2 s in earlier runs) | every Proton ARM64 game (and x86, where the boot runs under FEX: 8-11 s) | medium: env of the pre-booted services, Steam's process tree, stop/freeze keys | design below; not a config switch |
| 2 | Mono AOT images (`<assembly>.dll.dll`) built with the game's own mono.dll | window -> frame (+ play stutter) | -0.5 to -1.5 s, upper bound from the 11-05 symbol split; how much is wall time depends on the clock finding above | every Unity game on legacy Mono (`*_Data/Mono/EmbedRuntime/mono.dll`, Unity <= 2018.x .NET 3.5); MonoBleedingEdge unverified | high: Mono 2.x's Win64 AOT path is untested, a bad image can crash (GUID/version checks refuse stale ones) | evidence below; offline toolchain needed |
| 3 | FEX arm64ec mapped code cache (`EnableCodeCachingWIP` + `EnableLazyCodeCachingWIP`) | exe -> frame | <= 0.3-0.5 s (what is left of FEX compile with the DiskCache warm: 0.85 s on main, 11-05) | every arm64ec game | low as a switch, **but not testable**: the generator `fexofflinecompiler64.exe` is not in Proton ARM64 | wait for Valve to ship it, or build it at eff9f45 |
| 4 | Steam's own prep (handoff -> reaper) | tap -> reaper | 2-3 s of variance: 5.2 s today vs 2.0-3.4 s on 11-07/09/11, with steamwebhelper 3.6 core-s | every Steam game | - | not engine-side: split it from console_log first |
| 5 | `ProfileStats` off (`FEX_PROFILESTATS=0`; Proton's Config.json sets it to 1) | all emulated code | small (< 0.2 s expected): per-thread counters + cycle-counter reads around each JIT/cache lookup | every arm64ec game | low | A/B command below; no code needed |

Ruled out or already done (each with its measurement in game-launch-time.md): FEX TSO off (11-05: flat on the launch,
now off for Mono games for fps), Multiblock (already 1), VolatileMetadata (only acts with TSO on), anonymous-code disk
caching (off for Mono games since steam -36), ntsync (no /dev/ntsync on the 5.15 GKI, Proton ARM64 has none),
thread pinning / WINE_CPU_TOPOLOGY (<= -0.17 s), GPU floor (-0.24 s), `-force-gfx-direct` (-0.10 s), clocks (above),
disk (17 MB from storage), shaders (all hits). `-nolog`: Broforce writes no player log at all (no output_log.txt /
Player.log in the game dir or the prefix), so there is nothing to skip.

## 1. A pre-booted Wine session (tap -> exe, ~1.5-2 s)

Evidence, Valve's Wine `experimental_11.0`:
- `dlls/ntdll/unix/env.c` `run_wineboot()`: the first process in a new wineserver session creates
  `\KernelObjects\__wineboot_event`, starts `C:\windows\system32\wineboot.exe --init` and **waits for it** (up to 5 min).
  If the event already exists (`STATUS_OBJECT_NAME_EXISTS`), it only waits for the event, which is already set when
  the session is up. So a game started into a live session skips the whole boot.
- `programs/wineboot/wineboot.c`: `--init` runs `start_services_process()`, which **waits** for services.exe's
  `SVCCTL_STARTED_EVENT`. Then it does the prefix work and `SetEvent(event)` only at the end.
- `programs/services/services.c`: services.exe sets that started event only **after**
  `scmdatabase_autostart_services()` has started the auto-start services: winedevice (drivers), plugplay, svchost.
  That is the serial chain in the timeline (8.32 s -> exe 9.34 s, with 4 Hz samples).
- `proton` (`experimental_11.0`): the `waitforexitandrun` verb Steam uses runs `wineserver -w` first, so the launch
  waits for any wineserver already running on the prefix to exit. A pre-booted session therefore needs the `run`
  verb. `powos-proton-arm64`'s entry (`arm64-gate-entry`) is the place to choose it, since it already picks the verb
  and execs `_v2-entry-point`.

Design sketch (not built here; it needs device iteration):
- At the tap, `powos-open-task` already knows the app id and runs during Steam's 2-5 s of prep. It asks the gate to
  pre-boot the prefix: `_v2-entry-point --verb=run -- proton run wineboot.exe --init`, with the game's compat env and
  a wineserver kept alive a short while after its last client (`wineserver -p<sec>`), so it survives until the game connects.
- When Steam's launch reaches the gate and finds that prefix's session alive and booted (the `__wineboot_event`
  set; in practice the wineserver socket under `/tmp/.wine-<uid>/server-<dev>-<ino>/` plus a marker the pre-boot
  writes), it execs `run` instead of `waitforexitandrun`. Otherwise it runs the old way.
- Close/freeze: services.exe, winedevice and the wineserver are outside Steam's reaper tree, so
  `powos game <id> stop` (lib/game.sh `_game_steam_close`, which already matches environ WINEPREFIX) has to kill
  them too. sleep-gui's freeze keys on Steam's tree, so these processes stay awake while frozen: idle in practice,
  but this needs checking.
- Risks: env differences between the pre-boot and the real launch (DLL overrides, `WINEDLLOVERRIDES`,
  `WINE_CPU_TOPOLOGY`, Proton's `PROTON_*`), since the services keep the env they were started with. A tap that
  never becomes a launch (a Steam prompt) leaves a booted session behind: give it a short `-p` timeout.
- Not the same as 11-05's rejected "wineserver kept between launches". This one lives only from the tap to the game
  (no idle server, no Steam "running" state); the game itself still starts from Steam's reaper.
- Measure: `bf-coldstart.sh steam steam` before/after; the STAGES `wineserver -> exe` should drop to ~0.2 s and
  wineboot should vanish from the game's own timeline. Also run `bf-coldstart.sh frozen` and `resume` (freeze
  keys), plus a second game (`app:<id>`, e.g. ABZU) to show it is generic.

## 2. Mono AOT for legacy-Mono Unity games (window -> frame)

game-launch-time.md (11-05, agent/fex-mono-start) said "Mono AOT can't apply (Unity 2017.4's embedded mono.dll, no
AOT/`MONO_ENV_OPTIONS` for an embedder)". **The source says otherwise.** Broforce is Unity **2017.4.7f1** (header of
`globalgamemanagers`) on legacy Mono (`Broforce_beta_Data/Mono/EmbedRuntime/mono.dll`, 2.6 MB; no MonoBleedingEdge).
- `strings mono.dll` (the phone's copy): `..\mono\mini\aot-runtime.c`, `..\mono\mini\aot-compiler.c`,
  `AOT loaded AOT Module for %s`, `mono_aot_file_info`, and the exports `mono_main` / `mono_jit_init`. Both the AOT
  loader and the AOT compiler are built in.
- Unity's 2017.4.7 Mono (dnSpy-Unity-mono `unity-2017.4.7/mono/mini/aot-runtime.c`): `mono_aot_init()` installs
  `load_aot_module` as an **assembly-load hook unconditionally**. For every assembly it tries
  `mono_dl_open("<image path>" ".dll")`, e.g. `...\Managed\Assembly-CSharp.dll.dll` (`SHARED_EXT ".dll"` on
  PLATFORM_WIN32), and uses the image when its `mono_aot_version`, the assembly **GUID** and
  `mono_get_runtime_build_info()` match. A game update changes the GUID, so a stale image is ignored rather than
  used. With `MONO_AOT_CACHE` set it looks in `~/.mono/aot-cache/<name>-<guid>.dll` instead, but on a miss it spawns
  `mono -O=all --aot=...`: no `mono` exists here, so keep that off.
- `aot-compiler.c` has a PLATFORM_WIN32 path: it emits gas assembly (`image-writer.c` has COFF-style `.section` /
  win32 symbol handling), then `as` and `gcc -shared --dll`. `--aot=asm-only` stops after the `.s`.

So an offline pipeline is possible, and it is generic for legacy-Mono Unity games:
1. Under the game's own Proton prefix, run a tiny x64 loader that `LoadLibrary`s the game's mono.dll and calls
   `mono_main("mono", "--aot=asm-only,outfile=X.s", "<Managed>\\Assembly-CSharp.dll")` (plus `mono_set_dirs` for
   Managed\mscorlib). Using the game's own runtime makes `build_info` match by construction.
2. Assemble and link off the phone (x86_64-w64-mingw32 `as` + `gcc -shared`, on .58).
3. Install `<asm>.dll.dll` next to each assembly: Assembly-CSharp (4.4 MB), -firstpass, UnityEngine*, Rewired*,
   System*. These are extra files in the game dir, untouched by Steam's updates and never loaded once stale. Legal:
   it is the user's own copy and nothing is redistributed.

Expected gain: from 11-05's main-thread split (13 s window), mono.dll emulated 0.57 s (runtime + JIT compiler + GC),
Mono's JIT output 0.39 s, FEX compile 0.85 s warm, mostly Mono's fresh anonymous code (file-backed code hits the
DiskCache). AOT removes the JIT compile inside mono.dll and FEX's compile of the anonymous code, because AOT code is
file-backed and the DiskCache keeps it. It also removes the write-after-execute churn: FEX tracks SMC on pages it has
compiled (`SMCChecks` default `mtrack`) while Mono keeps writing new methods into the same code-manager pages. That is
an upper bound of ~1-1.5 s of main's CPU, and given the clock finding, maybe only part of it in wall time. It also
helps play: there is no JIT hitch the first time a method runs.
Risks: Mono 2.x's Win64 AOT was never a shipped configuration (the compiler's Windows link line still says
`-mno-cygwin`), so a miscompiled trampoline or calling convention could crash. Test per assembly (Assembly-CSharp
alone first) and keep `.dll.dll` out of the dir to roll back. Unity's MonoBleedingEdge (`mono-2.0-bdwgc.dll`) has the
same loader convention in upstream Mono, but whether Unity built it with AOT is **not verified** (check its strings
the same way).

## 3. FEX arm64ec code cache (what FEX-2610-175 ships)

`strings libarm64ecfex.dll` (Proton ARM64, 11-11 build) lists `FEX-2610-175-geff9f45`, the DiskCache options
(`FEX_DISKCACHE*`, `RWCacheDB_*.foz`), and the newer mapped code cache: `EnableCodeCachingWIP`,
`EnableLazyCodeCachingWIP`, `FEXCore::Context::CodeCache::{LoadCache,ApplyCodeRelocations,InitiateCacheGeneration}`,
`MappedCodeCacheFile`, and the generator's name `fexofflinecompiler64.exe` / `fexofflinecompiler32.exe`.
`files/` has no such exe (`find -iname '*fex*'`: only lib{arm64ec,wow64}fex.{dll,so}, share/fex-emu/Config.json). At
eff9f45, FEX's `Config.json.in` defaults are `EnableCodeCachingWIP false`, `EnableLazyCodeCachingWIP false`,
`DiskCache false` (Proton turns it on), `DiskCacheAnonCaching true`, `DiskCacheMemorySize 0`, `DiskCacheRODBNames ""`
(extra read-only DBs: a way to ship a pre-built cache), `SMCChecks mtrack`, `Multiblock true`. Proton's own
Config.json sets `ProfileStats 1`, `TSOEnabled 1`, `MaxInst 500`, `Multiblock 1`, `X87ReducedPrecision 1`.
So turning the WIP code cache on for arm64ec today has nothing to generate it. FEX-2611.1 (11-11) reworked the code
cache's keying for Linux/WoW64/ARM64EC (linuxcompatible.org), and PR #6072 fixed WoW64 code-cache loading and
FEXOfflineCompiler `process-all` on Windows, so the Windows-side generator is moving upstream. Valve has said it plans
Steam pre-caching of FEX code (windowsforum.com, 11-07), with no timetable or numbers. Gain ceiling: the warm FEX
compile left on main, 0.85 s, mostly Mono's anonymous code, which a module cache does not cover either. Lever 2 is
what makes that code cacheable. Re-check when Proton ARM64 ships the offline compiler: `bf-coldstart.sh fexcache
fexcache` already exists (its x86 FEXOfflineCompiler step does not apply to arm64ec).

## Measurement plan (all through the verify queue, phone read-only otherwise)

1. **Settle "busy but clock-blind" first** (decides how much 2/3/5 can win): a scratch wrapper around
   `bf-coldstart.sh steam` that samples main's `/proc/<tid>/stat` utime vs stime and `schedstat` (run vs wait-on-CPU)
   at 20 Hz from window to frame, plus `simpleperf stat -e cpu-cycles,instructions,task-clock -t <main>` over the
   same span. Low IPC with high stime means faults/syscalls; spin shows as user time in Wine/FEX sync symbols. Also
   read FEX's own per-thread counters. Proton's Config.json has `ProfileStats 1`, so FEX keeps `ThreadStats` in
   shared memory (FEXCore/include/FEXCore/Utils/SHMStats.h at eff9f45): `AccumulatedJITTime`, `AccumulatedSMCCount`,
   `AccumulatedSIGBUSCount`, `AccumulatedDiskCacheHit/MissCount`, `AccumulatedDiskCacheLookupTime`,
   `AccumulatedCacheRead/WriteLockTime`. Find the mapping in the game's `/proc/<pid>/maps` and dump main's row at the
   first frame. A high SMC count on main confirms lever 2's churn argument.
2. Lever 5 (no code needed): `tools/phone/verify/queue.sh add --close broforce-launch-time bf-coldstart.sh
   env:FEX_PROFILESTATS=0 steam steam` against `... bf-coldstart.sh steam steam`. Check first that the variable
   reaches the game (`/proc/<game pid>/environ`). If env: does not get through pressure-vessel/Proton, use the
   proton-settings.json route (`GAME_ENV=FEX_PROFILESTATS=0` as in game-resize.sh).
3. Lever 4: read Steam's `logs/console_log.txt` between ExecCommandLine and CreatingProcess for today's run against
   11-11 23:39 (3.0 s), and steamwebhelper's 118 % at 12 s: is it the Library page redrawing behind the game?
4. Lever 1 (after it is built): `bf-coldstart.sh steam steam frozen` + `resume` + `app:<another Proton ARM64 game>`.
5. Lever 2 (after the offline pipeline): `bf-coldstart.sh steam steam` with Assembly-CSharp.dll.dll alone, then all
   Managed images. Check Mono actually loaded them (`MONO_LOG_LEVEL=info MONO_LOG_MASK=aot` gives "AOT loaded AOT
   Module for ..." on stderr; Proton log). Then `bf-pacing.sh base` and `bf-checker.sh base` for fps and visuals.

Bar for shipping anything: >= 0.5 s on window -> frame or tap -> window over two runs each (run-to-run noise ~0.3 s),
and no fps or visual regression.

## References read

- Valve Wine experimental_11.0: dlls/ntdll/unix/env.c (`run_wineboot`), programs/wineboot/wineboot.c,
  programs/services/services.c - https://github.com/ValveSoftware/wine/tree/experimental_11.0
- Valve Proton experimental_11.0 `proton` (verbs `run` / `waitforexitandrun`) - https://github.com/ValveSoftware/Proton/blob/experimental_11.0/proton
- Unity 2017.4.7 Mono (dnSpy-Unity-mono mirror): mono/mini/aot-runtime.c, aot-compiler.c, image-writer.c, mini-amd64.h,
  driver.c - https://github.com/dnSpy/dnSpy-Unity-mono/tree/master/unity-2017.4.7/mono/mini
- FEX eff9f45 FEXCore/Source/Interface/Config/Config.json.in, FEXCore/include/FEXCore/Utils/SHMStats.h - https://github.com/FEX-Emu/FEX
- FEX-2610 release notes (disk cache 1 GB cap, memory buffer, prune on update) - https://fex-emu.com/FEX-2610/
- FEX PR #6072 "Code cache wow64 fixes" (search snippet: offline compiler process-all on Windows, WoW64 cache load) - https://github.com/FEX-Emu/FEX/pull/6072
- FEX-2611.1 code-cache rework (search snippet) - https://www.linuxcompatible.org/story/fex26111-stable-patch-ships-with-codecache-rework-and-steam-frame-crash-fix
- Valve enables FEX code cache for Proton on Arm, plans Steam pre-caching - https://windowsforum.com/news/valve-enables-fex-code-cache-for-proton-on-arm-plans-steam-pre-caching.451345/
