# Broforce fps on the phone (20-38 fps): where the time goes

Measured 2026-11-03 ~18:45 on the OnePlus Open while the user played (read-only: /proc and sysfs reads only).
Game: Broforce (Unity, **32-bit x86**, Proton Experimental + DXVK, through FEX), pid 15454, fullscreen 2268x2439 X
window on KWin (KGSL Xwayland). KWin: commits == drawn at 18-23 fps in that run (20-38 fps at 18:33).
Raw data: `design-qa/bf-fps-20261103/` (sample-30s.txt, placement-caps.txt, sample.sh). Note: the per-thread column
in sample-30s.txt is 100x too big (divisor bug, HZ=100 over 30 s); the numbers below are corrected.

## Verdict: CPU-bound on the game's main thread, on frequency-capped cores. Not GPU/fill-bound. Not thermal.

| what | measured (30 s) | reading |
|---|---|---|
| main thread `Broforce_beta.e` (tid 15454) | **95 % of one core** | pegged: the frame loop (Unity main + FEX JIT'd x86-32) is the limit |
| `UnityGfxDeviceW` | 48 % | render thread waits on main (futex) |
| `dxvk-cs` | 26 % | not pegged |
| `dxvk-submit` / `dxvk-queue` | 3 % / 5 % | submit waits in `adreno_drawctxt_wait` - fine |
| 7 x Unity `Worker Thread` | ~18 % each | spinning job workers; keep cpu0-2 (little) at ~90 % busy |
| GPU `gpu_busy_percentage` | **50-67 %** | at gpuclk **220-348 MHz** of 680 MHz max: msm-adreno-tz keeps the clock low because the GPU idles; ~25 % of its capacity is used. Not fill-bound. |
| GPU thermal_pwrlevel / cooling | 0 / 0 of 8 | no GPU throttling |
| CPU cooling devices | all 0 | thermal-engine not mitigating; skin 37 C, CPU zones 55-60 C (Android HAL: 67-81 C, status 0) |
| **CPU scaling_max_freq** | policy0 1459 / 2016 MHz, **policy3 (A715 x4) 1920 / 2803**, **policy7 (X3) 1709 / 3187** (cur often 864) | capped while the game runs, by userspace (perf-hal-2-3 / oplus.performance.hal / gameopt_hal), not by the uag soft limit (soft_limit_freq = hw max) and not by a cooling device |
| main-thread placement (100 x 10 Hz) | cpu3 22, cpu4 22, cpu5 17, cpu6 18, cpu7 21; 129 781 migrations | never on little cores, but bounced across gold+prime every few ms; cpuset `/` (0-7), uclamp.min 0 |

So the one thread that sets the frame rate runs at ~1.7-1.9 GHz effective (the X3 prime is capped to 54 % of its
clock and spends a fifth of the time at 864 MHz) and loses cache on every migration. FEX's 32-bit guest path
makes the main thread ~2-3x the native cost, which is why one core is the wall.

## Next fix (do this): a per-game CPU boost while a game window is focused

1. **Lift the clocks**: while the game is the focused fullscreen task, raise `scaling_min_freq` on policy3/policy7
   (e.g. min 1.9 / 2.4 GHz) and hold `scaling_max_freq` at hw max - through the vendor perf HAL's game hint
   (the Android `PowerHAL` GAME / `perf-hal` boost that gameopt_hal answers) rather than raw sysfs writes the HAL
   would overwrite. Find who writes the 1709/1920 caps first (watch scaling_max_freq while toggling focus).
2. **Pin the main thread**: give the game's main + UnityGfxDevice threads uclamp.min ~768 (`sched_setattr` /
   `cpu.uclamp.min` on a `games` cgroup) and affinity cpu7 (main) / cpu3-6 (rest), so the main thread stops
   migrating and the scheduler picks the prime core at a high OPP. Generic: in the PowOS game launcher shim
   (`bin/powos-game-shim`) by the FEX process, not Broforce-specific.

Expected gain: the main thread is ~95 % busy, so fps scales with its effective clock. 1.7-1.9 GHz -> 3.19 GHz on
the X3 (plus better IPC than the A715 it spends 80 % of its time on, and no migrations) ≈ **1.7-2x: 20-38 -> ~35-60
fps** (Broforce's 60 fps target reachable in light scenes). Watch thermals: one prime core at max is ~2-3 W; skin is
37 C now, so sustained is plausible, but re-measure after 10 min.

Secondary (smaller, try after): FEX settings for the main thread's cost - `FEX_TSOENABLED`/`FEX_MULTIBLOCK`/
`FEX_SMC_CHECKS=mtrack` per-app config for Broforce (TSO emulation is the big one for x86 Unity games; ~10-30 %),
and fewer Unity job workers (7 spinning workers fill cpu0-2 and steal gold time from main).

## Status (2026-11-03): the boost is built (agent/game-boost)

Generic, in the PowOS app's game-window path: `shell/GameBoost.kt` ticks once a second; while a game (WebWindows.isGame)
is in front - its window task Android's top activity (`PowosWindowActivity.frontAppId`) or its web window full screen /
last pressed while home is in front - and the screen is on, `assets/game-boost.sh engage <app id>` (Android root) runs a
holder that lifts every big policy to hw max (min ~80 %), moves the game's threads (Steam: SteamAppId/SteamGameId in
their environment; others: the desktop file's Exec program) into `/dev/cpuctl/powos-game` (uclamp.min 75), pins the
hottest thread to the prime core and the rest to the other big cores, and restores everything (saved originals) on
blur / close / screen off / a 4 s stale lease (app crash) / the game exiting. Thermal untouched. Unit `game-boost`.
Not yet measured: the boost engages only while the user plays - run `tools/phone/verify/game-boost.sh` then (PASS =
policies at hw max, main pinned; its fps lines are the gain). Unknown until then: whether the vendor HAL fights the caps
(the holder logs each re-assert as a "HAL fight" in /data/powos/state/game-boost/log).

## Option evaluated (coordinator ask): gamescope at a lower internal resolution + FSR

Idea: run the game nested in gamescope inside KWin, e.g. `gamescope -w 1134 -h 1220 -W 2268 -H 2440 -F fsr -- %command%`.

- **Not a fix for this bottleneck.** The GPU is at 50-67 % busy at a *low* 220-348 MHz clock, i.e. ~25 % of its
  capacity: rendering 4x fewer pixels would only let the GPU clock drop further. The frame is set by the CPU main
  thread, which resolution does not touch. Expected gain: **~0-5 %** (maybe less DXVK/Xwayland copy work), and the
  extra gamescope composite pass + nested Xwayland could cost more than that.
- **Not runnable today:** `targets/android/phone-rules.conf:114-120` bundles only the gamescope-session scripts
  (`gamescope-session`, `-steam`, `-ogui-steam`); there is **no `gamescope` binary** in the phone rootfs
  (`/data/powos/root/usr/bin/gamescope*` absent). It would also need gamescope's Vulkan path to work on Turnip/KGSL
  with KWin as the nested parent - untested on the phone (install-powos-android.sh:237/258).
- Worth it later for a game that *is* fill-bound (GPU busy ~100 % at max clock); re-run `sample.sh` first.

## How to re-measure

`tools/phone/adb.sh shell "su -c 'sh -s'" < design-qa/bf-fps-20261103/sample.sh` (30 s, read-only; divide the
per-thread column by 100) or `tools/phone/verify/bf-prof.sh`. Pass = main thread on cpu7 at >= 2.8 GHz and KWin
`frames:` lines >= 45 fps.

## FEX per-app config + Unity workers (2026-11-04, agent bf-fps-fex)

User 11-04: "when it does launch it totally works but the fps is really low". Measured read-only at 17:10-17:13 while
the user played (pid 32648, x86 Proton Experimental under Valve's FEX compat tool FEX-2607-76-g37265b1, steam -33).

**Correction:** `Broforce_beta.exe` is **x86-64** (PE machine 0x8664, `steam_api64.dll`), Unity **2017.4.7f1** - not
32-bit. So FEX runs it in its 64-bit guest mode; "32-bit Unity" defaults don't apply to it.

| what | measured | reading |
|---|---|---|
| fps (KWin `window task 72 frames`, 36 x 5 s = 3 min of play) | **mean 30.8, p50 32.0, min 21.8, max 36.2** | the base line for every A/B below |
| main thread `Broforce_beta.e` | ~100 % of one core (10 s) | still the wall |
| `UnityGfxDeviceW` / `dxvk-cs` / `dxvk-submit` | 36 / 18 / 11 % | wait on main |
| 7 x `Worker Thread` | **~5 % each** | not spinning any more (18 % each on 11-03): fewer workers would buy little |
| main-thread placement + clock (game-boost on) | pinned to cpu7, **1.36 GHz of 3.19** (policy3 1.65 of 2.80) | game-boost's log: `thermal cap 1363200 of hw 3187200 by horaeCb - kept` - the vendor thermal controller sets the clock; that lever is the vendor-game hook (task game-boost-loses-to-a-vendor-cpu-cap), not FEX |
| FEX per-thread stats (`/dev/shm/fex-<pid>-stats`, 10 s delta, main thread) | JIT+lookup 3.70 M ticks of the 19.2 MHz counter = **~1.9 %**; 0 new blocks compiled; **SIGBUS 0, SMC 0, signal time 0, float fallbacks 0**; 3.5 k L1/L2 block-cache misses/s | FEX's runtime overhead outside the generated code is ~2 %: no SMC invalidation storm, no split-lock SIGBUS slow path (telemetry: one 64-byte split lock, ever) |

Where FEX's config comes from for a Steam game (checked on the phone): `FEX_APP_CONFIG_LOCATION` =
`compatdata/<appid>/fex-emu/` - `Config.json` there is rewritten from the compat tool's ConfigTemplate at every launch
(only `X87ReducedPrecision 1`, RootFS, thunk paths, `ProfileStats 1`); `FEX_APP_CONFIG=/tmp/fex-app-config-<pid>.json`
is Steam's per-game FEX setting (empty `{"Config": {}}`); `AppConfig/` is empty and left alone. FEX names the game's
app config **`Broforce_beta.exe`** (its telemetry file is `Telemetry/Broforce_beta.exe.telem`), so a per-game file
goes to `compatdata/274190/fex-emu/AppConfig/Broforce_beta.exe.json`; environment `FEX_*` (steam-env,
proton-settings.json) still wins over it.

What each candidate can still buy, from the numbers above:

- **Multiblock, SMCChecks=mtrack, X87ReducedPrecision, VectorTSO/MemcpySetTSO/ParanoidTSO off**: already the effective
  values (FEX-2607 defaults + the compat tool's template). Nothing to set; SMC events are 0 anyway.
- **Code cache** (`FEX_ENABLECODECACHINGWIP=1`): steady state compiles 0 blocks and spends ~2 % in JIT/lookup, so it can
  only shorten the launch (task broforce-launch-time), not raise fps. No FEX code cache exists today
  (`~/.cache/fex-emu/codemap` 7 KB from 10-23; FEX_PORTABLE=1 for games).
- **TSOEnabled=0**: the one FEX lever left on the main thread's generated code (every guest load/store is LDAPR/STLR
  for x86 memory order today). Unsafe in general for a multi-threaded engine (Unity render + job threads share memory
  with main), so per-game only and only after 2 stable runs. A/B queued: `bf-pacing.sh env:FEX_TSOENABLED=0` x2
  (jobs 20261104-170903-22566, -170911-23319) vs `bf-pacing.sh base` (-170901-22327).
- **Unity job workers**: Unity 2017.4 has no `-job-worker-count` (not in UnityPlayer.dll's strings; only
  `-force-gfx-*`). Wine's `WINE_CPU_TOPOLOGY=4:0,1,2,7` caps what the game sees to 4 CPUs (3 workers on the little
  cluster, main free for the prime) - A/B queued (job 20261104-171031-28324). Workers are ~5 % each now, so expect ~0.

Status 17:15: the queue had not run (the user was playing: "no window / touched"); results go into the table below when
the jobs land. Keep a setting only with >= +5 % mean fps over 2 runs and no crash / visual break.

| mode (bf-pacing.sh) | fps (KWin commits/5 s) | main thread | stable |
|---|---|---|---|
| base (user's own play, read-only) | 30.8 mean / 32.0 p50 | ~100 % on cpu7 @ 1.36 GHz | yes |
| env:FEX_TSOENABLED=0 run 1 / run 2 | queued | | |
| env:WINE_CPU_TOPOLOGY=4:0,1,2,7 | queued | | |
