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

## Non-game load (2026-11-04, agent/game-quiet)

Goal: while a game is the focused full-screen window, everything else goes quiet (cooler phone, higher thermal cap,
more CPU for the game). Live snapshot 17:25, user 48 min into Broforce: skin 42.7-45.5 C -> OxygenOS ThermalController
tempLevel 10 -> policy0/3/7 capped at 1.02/1.17/1.25 GHz of 3.19. Besides FEX wine64 (112-165 %): surfaceflinger
19-27 %, the WebView renderer 13-17 %, com.powos.app 13-14 %, `steam` 13-14 %, Xwayland 6-14 %, kwin 6-10 %,
system_server 7-19 %, pipewire-pulse 6-7 %. Measured read-only while the user played (top, `cdp.sh idle 15`,
`dumpsys SurfaceFlinger`, framework.jar disassembled with build-tools dexdump).

| load | cause found | fix |
|---|---|---|
| surfaceflinger 19-27 % (+ GPU) | **every layer GPU-composed each frame**: HWC list wallpaper, HomeShell, the game's `[BBQ] powos-ww-1-linux`, panel anchor, `PowOS controller`, EdgeFloatBar, `PowOS status bar` all `CLIENT`, `forceClientComposition=true clientType=BLUR`. The status-bar strip's layer carries `blurRegions.size()=1 {radius=0 rect=[0,0,0,0]}` - a region that blurs nothing, but any blur region makes SF client-compose every layer under it. Origin: GlassBlur's encoder drawable. `ViewRootImpl.createBackgroundBlurDrawable` calls `setBlurRadius(default)`, which **adds** the drawable to the window's `BackgroundBlurDrawable.Aggregator.mDrawables`; the encoder then only wrote fields (`mVisible=false`, zeroed after the probe), so it stayed in the aggregate and went out as that window's region. | `GlassBlur.Codec` init calls `setVisible(false, false)`, the aggregate's own removal path (`onBlurDrawableUpdated`: not drawn -> removed). Generic: every window with a page glass (home, status bar, shade, pull, switcher). Expect the game, home, wallpaper and controller layers back on DEVICE (HWC overlays), SF's per-frame GPU pass gone. |
| WebView renderer 13-17 % + app main/RenderThread ~10 % | home's page under the full-screen game: **rAF 60/s, 120 BeginFrames/s, 37 ms/s script**, all from `tick@ui/webwindows.tsx:2208` (the window-geometry loop runs every frame while any window exists, even with nothing moving). Other pages (shade, pull, quicktools, statusbar, assist) were idle (0 frames). | GQ1: `WebWindows.quietCheck` pauses home's WebView (`onPause`: page hidden, no rAF/frames) while a game's immersive full screen covers it (`GameBoost.pageQuiet`), and resumes it on full screen off, the window closed, the switcher up / a swipe headed home, or an edge-strip gesture's DOWN (before the page gets the event). RenderWatch doesn't count a paused page as a stall (`homeShown`). |
| `steam` 13-14 % | not the CEF UI (steamwebhelper ~3 %): `CSteamController` (Steam Input, polling the controller) and `IPC:CSteamEngine`. | none: Steam Input is the game's input path; never stopped. |
| Xwayland 6-14 %, kwin 6-10 % | the game frame's path Xwayland -> KWin -> the web window consumer (a copy per frame into an RGBA_8888 BBQ buffer, `isOpaque=false`). | next: the consumer's buffers RGBX (opaque) for a full-screen game, so SF also drops home + wallpaper from the HWC list (occlusion); then direct scanout. Needs native_consumer.c. |
| com.powos.app other | powos-ww-linux consumer ~3 % (needed), powos-game-boost tick ~3 % (1/s, cheap: cached front window). | none |

After-numbers: pending a ship (same method: `top -b -n2 -d 60`, `cdp.sh idle 15` (home: 0 rAF/s expected), SF HWC list
(`dumpsys SurfaceFlinger | grep -A2 "HWC layers"`: DEVICE expected), skin temp over 10 min, policy caps). Not measured
in this run: the Mac's Docker VM (Colima) hit input/output errors mid-run (`mkdir /tmp/containerd-mount...: input/output
error`), which also took down adb and the JVM test.

2026-11-05 03:02 soak (`bf-quiet.sh 600`, job 20261104-194031-7308) is INVALID: it printed PASS with HomeShell focused and no game process - its `adb shell "pgrep -f Broforce_beta.exe"` matched its own `sh -c`, so it never started the game, and it read a non-existent `run/hyprland.log`. Its HWC list (all CLIENT) is also not the fix's: the phone ran com.powos.app 2026.11.04-1230 (installed 13:31, build b6980d5b), and every APK ship after a7f7792c (17:37) was HELD (modules-first rc 11: phone offline over WireGuard). bf-quiet.sh now starts the game like bf-pacing, FAILs unless PowosWindowActivity is focused + resumed and the game's processes use >= 25 % CPU in every sample (bf-quiet-verdict.py), and logs the app versionName and SF blur lines with the HWC list.

## Present path (2026-11-05, agent/game-present-path)

Soak 11-05 03:40-03:53 (`bf-quiet.sh 600`, app f19d5059, artefacts `~/.cache/powos-verify/bf-quiet-2026-11-05_0340`):
game 146 % CPU, 38.0 fps; showing it cost surfaceflinger 28-31 %, Xwayland 19 %, kwin_wayland 12 % (~60 % of a core);
skin 42.3 -> 44.3 C in 10 min. Chain: game (Wine X11 Vulkan WSI) -> Xwayland (glamor, Present) -> KWin anland window
task (renders the X window item into the consumer's gralloc buffer: one GPU draw per game frame, 0052) ->
`SurfaceView[PowosWindowActivity](BLAST)` -> SurfaceFlinger/HWC.

| stage | found (sf-end.txt / hwc-end.txt) | change |
|---|---|---|
| SurfaceFlinger 28-31 % + GPU | **every HWC layer CLIENT** (SurfaceView, the activity, panel anchor, EdgeFloatBar, status bar, ...), `forceClientComposition=true clientType=BLUR`. The status-bar fix (a7f7792c) took: `PowOS status bar` has no blur region now. The one blur owner left is **`PowOS verify status`** (the verify pill, VerifyRun.kt): `blurRegions {radius=386u rect=[0,0,479,66]}` - home's glass, set on every add, over whatever is in front. So each verify run's own pill made SF GPU-compose the whole screen every frame: the measuring instrument caused the compositor cost it measured. The game's own layer is already right: `isOpaque=true blend=NONE` (RGBX consumer), so with no blur SF can put it on a DEVICE overlay and skip what's under it. | `VerifyRun.glassOver`: the pill keeps its glass only over home's own page with no game web window full screen/focused; over anything else (an Android window activity, a web-window game) a near-opaque tint (`SOLID`), checked on the pill's 1 s tick. Test `VerifyPillGlassTest`. bf-quiet.sh now prints `blurowner <layer>` for every layer with a blur region. Expected: all layers DEVICE, SF's per-frame GPU pass gone (SF ~5-10 %). After-number: next `bf-quiet.sh 600` once shipped. |
| kwin_wayland 12 % | one full-screen render of the window item into the consumer buffer per game frame (0052: drawn once per commit since 11-02, was ~2.7x). | none yet. A pass-through (Xwayland's dma-buf queued to the Android consumer without the KWin draw) is not possible as is: the consumer's buffers are gralloc buffers the BufferQueue owns, KWin imports them; passing the client buffer through needs Xwayland/the game to render INTO consumer-allocated gralloc buffers (a wl_drm/linux-dmabuf allocator fed by native_consumer.c) - a separate project. |
| Xwayland 19 % | the Vulkan WSI's Present of each frame into the X window's pixmap (glamor copy unless xwl_present flips; a flip needs the swapchain image the window's size - Broforce's X window must equal its swapchain). | not measured yet: next is `bf-present.sh` / Xwayland `-verbose` on a run to see flip vs copy counts. |

## How to re-measure

`tools/phone/adb.sh shell "su -c 'sh -s'" < design-qa/bf-fps-20261103/sample.sh` (30 s, read-only; divide the
per-thread column by 100) or `tools/phone/verify/bf-prof.sh`. Pass = main thread on cpu7 at >= 2.8 GHz and KWin
`frames:` lines >= 45 fps.
