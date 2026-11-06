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
| Xwayland 19 % | **never flipped**: lfdevs's 0003 made `xwl_present_check_flip` return FALSE on KGSL surfaceless, so every present was a copy: export the client's fence + wait (0008), re-validate the import (0012), a window-sized glamor blit, a `glFinish` (`xwl_present_flush`), then a window-buffer commit with its own fence (0009). Log before (11-05 ~07:40): `3264 Present copies` / 30 s, `961 commits`. | xwayland-kgsl 24.1.13-8, **0013** (agent/present-path-2): a client's DRI3 buffer (0003 keeps its dma-buf planes) goes to KWin as itself (linux-dmabuf, depth-24 = XRGB8888, no Xwayland fence - the client's KGSL fence is on the dma-buf, KWin waits on it), so Present flips it under upstream's rules. KGSL flip timer 100 ms (a registered workaround for stale frame callbacks, docs/REMOTE-POWOS.md §4). One `Present flips, N copies <why>=n` line per 30 s. Device 08:05: `1652 Present flips, 0 copies`, window commits 961 -> 2 / 30 s. Soak 08:02 (`bf-quiet-2026-11-05_0802`): Xwayland 19-20 % -> under top's list (<4.5 %), game CPU 149 % -> 79 % mean, KWin window task 40.0 fps mean (same lines 32.1 in the 04:16 soak), kwin 12.8 %, SF 17 %, skin 34.7 -> 37.1 C; bf-checker base 0 % checkered, 40 fps. |
| kwin "2 commits per frame" (kwin 3.65 probe: ~84 commits/s for 40 drawn) | **not a second commit**: 0014's per-site line showed every commit is a damaged flip (2500 / 30 s, 0 others; frame callbacks ~29/s). Broforce presents **async** (DXVK on Wine's X11 WSI, PresentOptionAsync), and upstream completes an async flip on a `wl_display_sync` round trip, so all ~84 presents/s went to KWin, which drew 40 and dropped the rest. | xwayland-kgsl 24.1.13-11, **0015** (agent/xw-commits): on KGSL an async flip waits for the frame callback like a vsync'd one and is never skipped by a newer one, so the swapchain throttles the game to KWin's draw rate (-10 skipped queued flips instead: their buffers went back idle at once and the game rendered flat out, 220 % CPU at ~200 presents/s). Soak 17:07 (`bf-quiet-2026-11-05_1707`, PASS 300 s): commits 407-449 -> 221-229 / 5 s, drawn 40 fps kept, game CPU 108-111 % -> 80-83 %, kwin 14.0-14.8 % -> 13.4-13.7 % (per-commit work is not where kwin's cost is), SF ~18-20 %. Open: ~5 frame timeouts/s (100 ms timer: draws whose callback doesn't come back), p90 commit->drawn ~104 ms, unchanged from before. |

## Toward 120 (2026-11-05, agent games-120)

User goal (11-05): "goal is 120" - games at the 120 Hz panel's rate. Every stage's rate at once, from bf-pacing base
of 19:33 (cover screen, kwin 3.66 direct scanout off, xwayland-kgsl 24.1.13-11; kgsl.txt, kwin.txt, L1.txt, and the
19:38 bf-quiet SF dump for the panel):

| stage | rate | how measured | reading |
|---|---|---|---|
| game presents (DXVK, async) | ~45/s | Xwayland "Present flips" / 30 s (0015 paces them on frame callbacks) | the game would render more: main thread ~30 % |
| Xwayland commits | 45.4/s, frame callbacks 40.4/s, **timeouts 5.0/s** | 0014's 30 s line | 5 commits/s go out only after the 100 ms TIMER_LEN_FLIP_KGSL |
| KWin window task drawn | 40.3/s; commit -> drawn p50 12, **p90 104 ms** | kwin "frames:" 5 s lines | KWin draws only into a buffer the consumer offered; it waited for one |
| consumer queueBuffer | ~40/s (= drawn) | - (no meter before this change) | serial: dequeue -> CPU-wait release fence -> offer -> KWin's frame -> queue |
| SurfaceFlinger latch (frame ready) | 41.2/s; intervals p50 14 ms, every ~8th **114-121 ms** | `--latency` column 3, deduped | the stall is ~100 ms + the 16 ms nap after a timed-out dequeue |
| panel | **60 Hz** (cover activeMode 60, displayManagerPolicy render [0, 60]) | `dumpsys SurfaceFlinger` Pacesetter display | ColorOS's per-package policy: com.powos.app is unlisted -> 60 Hz (shell/HighRefresh.kt) |
| skin | 35.1 -> 38.3 C over 10 min (16:06 soak) | skin-msm-therm | headroom for 120 Hz |

Two caps, in order: (1) the panel itself: 60 Hz on the cover under every game, so 60 fps was the ceiling whatever the
game did; (2) the consumer's buffer pipeline: KWin keeps the buffer it was offered until the client's next frame, so
of `min_undequeued + 2` buffers only one was left for SurfaceFlinger - every queue waited for a release before the
next offer (the 12 ms median), and every ~8th frame the dequeue ran into its 100 ms timeout, slept 16 ms more, and the
game's frame callback timed out behind it (5 stalls/s x ~110 ms = 0.55 s of every second; the other 0.45 s at ~13 ms a
frame is ~35 frames, + the 5 stalled ones = the ~40 fps).

Changes (agent/games-120; APK ship needed, no kwin/xwayland change):

1. **Panel at 120 under a game** - `PowosWindowActivity.gameRefresh` (+ `GameRefresh.wanted`, JVM test
   GameRefreshTest): a game's window task (WebWindows.isGame: steam_app_<id> or a Game desktop file; never Steam
   itself) asks for its screen's fastest mode at the current resolution while it is the top task, again on every
   surface change (fold: per-screen mode ids), and gives it back when it leaves the top. Rooted and non-rooted alike.
   HACK row in REMOTE-POWOS.md §4 (same ColorOS policy as HighRefresh).
2. **One more buffer for a window task** (native_consumer.c do_connect: `min + 3`, the desktop keeps `min + 2`):
   the offer goes back to KWin right after a queue, so a game commit is drawn when it lands, not one release later.
3. **No 16 ms nap after a timed-out dequeue** (it already waited 100 ms): a stall left is <= 100 ms, not ~116.
4. **Meters**: the consumer logs `surface N pacing: ... queued (/s), N bufs; free-buffer wait p50/p90/max (timeouts),
   release-fence wait max; producer wait p50/p90/max` every 5 s; bf-present.sh keeps SurfaceFlinger's actual present
   times (A<n>.txt) and `--displays` (displays.txt); bf-prof.sh a `skin <start> <end>` line; bf-pacing.sh prints
   bf-layers.py's `layers <mode>:` line - the table above in one line per run (tier1 test-bf-layers.py).

After: pending the APK ship, then `queue.sh add --screen cover broforce-fps-low-cpu-bound-under-fex bf-pacing.sh base`
(+ bf-checker base for dashes). Expected: panel 120, consumer free-buffer wait ~0, Xwayland timeouts ~0, KWin drawn =
the game's presents (the game then sets the rate: its main thread was ~30 %, so well past 60). If timeouts stay, the
stall is SurfaceFlinger not releasing (the consumer's free-buffer wait p90 says so) - next lever there.

## The 100 ms stalls: KWin's own reconnect poll (2026-11-06, agent games-120-b)

After games-120 (panel 120 Hz, consumer min+3 buffers, 0 dequeue timeouts) the cover still showed
`layers base: game 66.1 > xwayland 66.0 (cb 61.8, timeouts 4.2/s) > kwin 67.1 (commit->drawn p50 1 p90 8 ms) >
consumer 67.4 (5 bufs, ... 0.0 timeouts/s) > sf 65.1 > panel 120 Hz`, frame ms p50 7.5 / p95 104 (job
20261105-235740-47903, app c995b83c). SurfaceFlinger's present times (A1.txt) are **two states, not a slow game**:
runs at 116 fps (frame mean 8.6 ms = the 120 Hz vsync) cut by a ~100 ms stall (median 99.6 ms) every ~200 ms (189-209
ms apart, at 40 fps before and at 66 now alike) - 48 % of the time stalled. KWin's `commit -> drawn max` was ~110 ms
in every 5 s line, so KWin itself held a damaged game frame that long.

Cause: the **desktop** output's reconnect. Behind a full-screen game task the desktop has no consumer (home is not
shown: "no desktop consumer: the output follows the window tasks' screen" in the session log), so AnlandBackend sits in
fallback and its 200 ms `m_reconnectTimer` calls `try_exit_fallback()` - which sent PICKUP_FDS and `poll()`ed up to
`HANDSHAKE_TIMEOUT_MS` (100 ms) for the answer **on KWin's main thread**. KWin stopped for 100 ms of every 200: no
draw, no frame callback; Xwayland's 100 ms TIMER_LEN_FLIP_KGSL then fired (the 4.2 timeouts/s), the game's next
frame went out and KWin drew both. The display daemon already keeps a PICKUP_FDS until a consumer deposits its fds
(`try_deliver_fds`), so asking again each tick was never needed.

Fix (kwin 6.7.5-3.67, **0059**): `try_exit_fallback()` asks once (`pickup_asked`, reset with the daemon connection)
and only checks for the answer (`poll(..., 0)`); redial's HELLO answer likewise. A QSocketNotifier on ctrl_fd while
in fallback (`AnlandBackend::watchCtrl`) runs the reconnect as soon as the answer comes, so a returning home is picked
up at once instead of on the next tick. Cap (2) of the brief - what holds the game at ~66 - is the same stall: the
game is not CPU/GPU-capped below 120 (between stalls it presents at the panel's 116-120; main thread 38 % of a core,
UnityGfxDeviceW 12 %, GPU busy 60 % at 374 of 680 MHz, skin 38.1 -> 38.4 C, no Unity/DXVK cap: async presents).

## The 60 Hz render rate under a 120 Hz panel: ColorOS touch idle (2026-11-06, agent sf-latch-60)

After kwin 3.67 every run was ~58 fps with frames 16.7 ms apart, direct scanout or not: `layers base: game 116.0 >
xwayland 115.8 > kwin 121.7 (direct, 13111/13113 frames) > consumer ? > sf 57.1 > panel 120 Hz (render 120-120)`
(job 20261106-114545-74705). "sf" is the game layer's `dumpsys SurfaceFlinger --latency` ACTUAL present times
(column 2, deduped over the 0.5 s polls) - what reached the panel; the screen recording agrees (~58 fr/s).

A 4 s atrace during the same run (probe 20261106-120052-98429, `atrace gfx view sched freq` in the measure window):
the app applied 127 powos-direct buffers/s, but SurfaceFlinger's `VSYNC-sf` fired every 16.7 ms (235 in 4 s), its
VSyncPredictor traced `CVT-fps 60` and each `scheduleFrame` skipped the next 120 Hz vsync ("VSP-prediction" +4 ms ->
"VSYNC in 20.7 ms"). No missed frames (HWC/GPU missed counters unchanged), no client composition on the cover, no
per-uid frame-rate override (GameFrameRateOverrides / FrameRateOverrides empty), display policy [120 120].

Cause: ColorOS's own render-rate cap in SurfaceFlinger - OPlus VRR "CVT", source **oti-adfr** = touch idle (OTI): 2.5 s
after the last touch (IdleTimeOut 2500000000, ADFR "H->L [120 -> 60]") SurfaceFlinger wakes at 60 while the panel stays
at 120. `dumpsys SurfaceFlinger --oplus vrr` shows it: `CVT: CurrentRate [60, oti-adfr]` and a history of
`{ fps 60, source oti-adfr, enable at 12:04:03, disable at 12:08:38 }` = exactly the probe's game run (and 10:39:59 -
11:45:13 over the morning's runs). system_server (`VRR [OPlusExternalRefreshRateManager] notifyDisableOtiMode: false` ->
`setTouchIdleShouldPause false`) arms it when the screen is on; it exempts only its package blacklist (games such as
com.tencent.ig, /my_product/etc/oplus_vrr_config.json) and an app's own request (OTI SW "AppRequest: fps, layer, pkg").
The verify runs never touch the phone (a free window needs 120 s without touch), and a game played on a gamepad or
keyboard doesn't either, so the game ran at 116 into a 60 Hz latch. The 11-05 runs at 116 between stalls predate the
reboot of 11-06 morning (whatever kept OTI paused then is not reproducible now).

Fix (APK, non-rooted alike): a game's window surface votes its mode's rate while the task is the top one -
`PowosWindowActivity.surfaceVote` (Surface.setFrameRate(rate, DEFAULT, ONLY_IF_SEAMLESS) on the SurfaceView's surface;
the direct child powos-direct inherits it and also votes itself - `direct_set_vote` / ASurfaceTransaction_setFrameRate
with its next frame, Native.nativeSetWindowFrameRateVote; 0 when the task leaves the top; `GameRefresh.rate`, JVM test). HACK row in
REMOTE-POWOS.md §4. Meter: bf-present.sh saves `--oplus vrr` (vrr.txt) and the layers line ends `panel 120 Hz (render
120-120, render cap 60 oti-adfr)` while the cap holds (tier1 test-bf-layers.py).

Check after the APK ship: `queue.sh add --screen cover broforce-fps-low-cpu-bound-under-fex
tools/phone/verify/direct-scanout-on.sh bf-pacing.sh base` (+ plain `bf-pacing.sh base`, + `bf-checker.sh base` for 0
dashes). Pass: sf >= 110 and no "render cap" in the layers line; the app logs `window N: surface votes 120.00001 Hz`.
If the cap stays (OTI ignores both votes), the next lever is finding what OTI's "AppRequest" takes (SurfaceFlinger strings: findTargetLayer / appRequestLayerReady - a target layer of the focused
process, every other visible layer "negligible").

## Real play at 38 fps: the vendor's thermal gear, not a profile (2026-11-06, agent play-cpu-cap)

Live capture of the user's own Broforce play (11-06 ~13:20-13:30, unfolded inner 2440x2268 @120 Hz, direct scanout off):
`layers live: game 38.5 > xwayland 38.7 > kwin 37.0 (commit->drawn p50 1 ms) > sf 39.1 > panel 120 Hz, no render cap`.
Every stage passes the game's rate on (0 Xwayland timeouts, KWin draws each commit in ~1 ms), so the game itself makes
38 frames a second: its main thread `Broforce_beta.e` 75.9 % on cpu7 at **1593 MHz of 3187**, UnityGfxDeviceW 24 %,
GPU 69 % busy at 469 of 680 MHz. The benchmark (bf-pacing base = the title menu) reaches 116 fps; gameplay's frame
costs ~3x the menu's on the same clock, so the clock is the lever and the menu is the wrong scene to judge it by.

**Who sets the cap: horae applying com.oplus.battery's skin-temperature gear, and it follows temperature.** Read-only
(game-boost log, `/odm/etc/temperature_profile/sys_thermal_control_config_folding.xml`, LSPosed log, thermal zones):

- The caps seen are rows of the profile's `thermal_cpulevel` table (little, gold, prime max): level 3 = 1459/1920/1709,
  level 4 = 1459/1786/1594, level 5 = 1459/1651/1363 MHz. Nothing else writes scaling_max_freq (the boost keeps
  horae's cap, game-boost.sh `thermal_owner` = horaeCb); no cooling device, no uclamp/cpuset limit on the game
  (cgroup `/`, its threads in /dev/cpuctl/powos-game with uclamp.min 75).
- The table in use is the **game table** (category_4): the oplus-hook logged `gameClass: com.powos.app appType 4
  (steam_app_274190 boosted)` at 13:27:05, the moment the caps changed from common_config's level 4 to level 3 - so the
  app IS recognised as a game while the boost holds; it is not a balanced/default profile. category_4 maps gear 7 ->
  level 3, gears 8-9 -> level 4 (gear 8 also caps fps at 55, gear 9+ at 50), gear 10 -> level 5, gear 11+ -> 6.
- The gear follows skin temperature over the run (game-boost log + a 5 s sampler of skin-msm-therm / shell_front):

| time | skin-msm-therm | shell_front | gold / prime cap | level (category_4 gear) |
|---|---|---|---|---|
| 13:24-13:25 (game just started) | - | - | 2592-2803 / 3187 | none (gear <= 6) |
| 13:27-13:30 (the live capture) | 38.2-38.5 | - | 1920-1786 / 1709-1594 | 3-4 (gear 7-8) |
| 13:35 | 40.5 | 42.9 | 1786 / 1594 | 4 (gear 8-9) |
| 13:38 | 41.8 | 44.6 | 1786 / 1594 | 4 |
| 13:38:56 - 13:40 | 42.4 | - | 1651 / 1363 | 5 (gear 10) |

So the cap is thermal and gets tighter the longer one plays (2.8/3.2 GHz cold -> 1.65/1.36 GHz after ~15 min). The
profile's mode offsets (`game_high_perf_mode_item -1`, `racing_mode_item -10`; `system high_performance_mode_on=0`)
are the vendor's own user-facing performance modes - not touched (vendor limits stay the vendor's; the user can pick
"High performance mode" in Battery settings). Android's ADPF/PerformanceHint or GameManager can't lift it either:
both act below scaling_max_freq, which is horae's. **The legitimate lever is heat: every watt PowOS and Steam burn
while a game is in front moves the gear.**

**Our own and Steam's load during play** (10 s per-thread sample at 13:33, the game in a level, `/proc/*/task/*/stat`):

| load | % of a core | what | change |
|---|---|---|---|
| Steam webhelper, main renderer (pid started with Steam, 537 MB) | Compositor 22.9 + ThreadPool 5.0 + IO 2.9 + main 2.1 | Steam's one UI renderer: the main window is unmapped (closed to tray), but at the game's launch Steam opened the in-game overlay's popup (`steamui_html.txt` 13:22:48 `PopupHTMLWindow ... handle:65536`), and the user's Steam has the performance-monitor corner on (`localconfig.vdf` `InGameOverlayShowFPSCorner 1`, `DetailLevel 4`) | none yet - the overlay draws **nothing** in the game: an x11grab of the game window at 13:37 (in a level) has no FPS corner, i.e. Steam renders an overlay that never reaches the screen. Next: A/B the game launched without gameoverlayrenderer (Steam's per-game "Enable the Steam Overlay" off) - expect ~35-40 % of a core less, mostly on the gold cluster |
| steamwebhelper gpu-process | VizCompositorTh 7.8 + IO 2.3 | the same overlay's frames | same |
| steam CSteamController | 10.2 | Steam Input polling the gamepad | none: the game's input path |
| game-boost.sh holder (our `sh` 5.8-12.9 %) | 7.0 | the boost's own 1 s loop: ~14 forks/s for the cpufreq limits (cat, boost_min) and every 5 s a full /proc environ scan (~1000 processes) + a `cat` and a `grep` per game thread (146 threads) | **fixed** (game-boost.sh): limits read with `read`, hw max / boost step cached once, ticks via `read`, known threads in a variable, the full process scan only until the game is seen and then every 30 s (the known pids' liveness in between). Test `test/tier1/test-game-boost-holder.sh` (fake cpufreq tree: lift, re-assert, restore, no `$(cat` in the per-second path). Cap lines now carry the skin temperature (`thermal cap ... by horaeCb, skin 41.8 C - kept`) so the next run shows the gear curve without a sampler |
| the other `sh` (8.2 %, pid gone by 13:32) | - | short-lived: the live capture's own samplers (bf-prof / bf-present loops) | none (instrument) |

Not changed, but worth an A/B next: under horae the boost raises each big policy's **min** to horae's cap, so the gold
cluster (cpu3-6: Unity workers at ~7 % each, nothing pegged) sits at its capped top clock all the time - voltage and
heat the main thread (on cpu7) doesn't use; uclamp.min 75 on the game's threads already asks schedutil for the clock
when they run. Try: under a thermal controller lift the min on the prime policy only.

**Gameplay scene for the benchmark** (bf-pacing.sh `play`, new): base, then `bf-play.sh` takes the game from the title
into a level - keys `BF_PLAY_KEYS` (default six Returns: any-key title -> Start -> Campaign -> slot -> mission) sent
with xdotool to the activated game window, 3 s apart, a 1/4-size grab before and after each key into the mode's folder
(`play-<n>.png`: the proof the run is in a level, and what to tune the keys from), 10 s in the level, then the same
30 s measurement and layers line. The key sequence is a first guess - the first run's grabs say where it stopped.
Queue after the merge: `queue.sh add --screen inner broforce-fps-low-cpu-bound-under-fex tools/phone/verify/bf-pacing.sh play`
(and `bf-pacing.sh base` for the menu next to it). Pass for a change = its `layers play:` line + `prof play:` clocks/caps
and skin, 0 dashes (bf-checker), against the same scene before.

## Heat: placement and our own load in real play (2026-11-06, agent play-heat)

Live capture 11-06 14:25 of the user's play (`bf-prof`, 30 s): game **29.6 fps**, skin 43.6 C, caps policy0 1017/2016,
policy3 1401/2803, policy7 1363/3187 (horae's gear on category_4, as above), GPU 57 % busy at 370 of 475 MHz
(thermal_pwrlevel 3), panel 60 Hz. The main thread `Broforce_beta.e` 75 % **on cpu4 (gold), Cpus_allowed 0-7** - at
13:20 it was on cpu7. Then UnityGfxDeviceW 26, surfaceflinger 14, com.powos.app main 11.4 + RenderThread 5,
an `sh` 10.5 (on cpu7), kwin 9.9, CSteamController 8.7, powos-padd 7.5, wineserver 6.9, InputDispatcher 6.6 %.
Heat is the limit (the gear follows skin temperature), so each item below is less heat or better placement; nothing
of thermal-engine, horae's caps, vendor limits or SELinux is touched.

| item | cause found | change |
|---|---|---|
| main thread on a gold core, mask 0-7 | (a) game-boost.sh pinned it once and never looked again; the kernel rewrites a thread's mask when its cpuset's cpus change (a cpu paused/brought back, the cpuset rewritten), and 0-7 = the root cpuset's own mask, i.e. reset, not ours (adopt gives every game thread 3-6). (b) The hot-thread pick compared the new candidate's 5 s delta with the pinned thread's **lifetime total** (`od` from the cumulative ticks file), so the first pick - at launch, a loading thread - kept cpu7 for good | holder checks the main thread's `Cpus_allowed_list` every 5 s with a builtin read; on a reset it logs `main thread N on cpus X (its mask was reset)`, re-pins it to the prime core and re-masks every known thread off it (forks only on a reset; the restore line counts `placement resets`). Both deltas over the same 5 s. `status` prints `main <tid> allowed <cpus> last cpu <n>`, and bf-prof.sh now records that (`boost ...` lines) plus the cpu cgroup, so the next capture shows placement directly |
| `sh` 10.5 % on cpu7 | the boost holder (13:43 cut to builtins) or the capture's samplers - unpinned either way | the holder pins itself to the little cluster (lowest policy) at start: its loop never shares the prime/gold cores with the game |
| gold cluster held at its capped top clock | under horae the boost raised every big policy's min to horae's cap: cpu3-6 (render/dxvk/workers, none pegged) idled at the top voltage | under a thermal controller only the main thread's policy (prime) holds its min up; the rest clock on demand (their uclamp.min 75 asks schedutil when they run). `BOOST_MIN_ALL=1` = the old behaviour, for the A/B |
| powos-padd 7.5 % + CSteamController 8.7 % | already select()-driven, but it repeated the last state at **250 Hz for a second after any change** - with the overlay's sticks/d-pad in use that is always, so 250 identical Deck reports a second, each one read and processed by Steam Input. The Deck gyro/accel fields are always 0 (the overlay's gyro module drives the mouse/right stick, not the Deck motion fields) | every change still goes out at once (`apply`); the timer is a 30 Hz keepalive, 250 Hz only while the Deck motion fields are live (`period`). Test `test/tier1/test-powos-padd-rate.py`. Expect padd ~1 % and CSteamController down with it |
| com.powos.app main 11.4 % + RenderThread 5 % | not sampled (phone offline for this run; home's page is already paused under a full-screen game, GQ1). With unbuffered touch dispatch every touch sample reaches the overlay, and `onPlayTouch` invalidated the whole pad view on **every** event - a finger held on a button or the d-pad (Broforce's controls) moves ~120+/s without changing anything on screen. InputDispatcher 6.6 % is the same stream on the system side | `GamepadOverlay.redraws`: down/up always redraw, a move only when it changed the pad's state or moved a stick's knob (mouse regions redraw from their own callbacks). Test `GamepadOverlayRedrawTest`. Still to confirm with a stack sample (`simpleperf record -p <app pid> -t <main tid>` during play) that this was the 11 % |
| Steam overlay | its webhelper popup renders ~35-40 % of a core and draws nothing in the game | `unity-screen` (Broforce's launch option) drops gameoverlayrenderer from the game's LD_PRELOAD and unsets its Vulkan layer; `POWOS_STEAM_OVERLAY=1` keeps it. Per game; Steam's global settings (the FPS corner) untouched. Takes effect after `unity-screen --install 274190` re-copies the wrapper (Steam closed). Whether Steam still opens the popup without the renderer injected is the A/B's question |

**Not measured yet** (phone offline over WireGuard from 14:40 for this whole run, so no before/after on device). Queue
after the ship, same scene each: `bf-pacing.sh play` with (1) this build, then (2) `POWOS_STEAM_OVERLAY=1` in the
launch for the overlay A/B and (3) `BOOST_MIN_ALL=1` for the gold-min A/B; report per run the `layers play:` fps, the
`prof play:` caps/clocks, skin start/end, `boost main ... allowed 7 last cpu 7`, padd/CSteamController/com.powos.app
%, and 0 dashes. Pass: main thread on cpu7 for the whole run, padd < 2 %, and a lower skin slope at the same fps.

## How to re-measure

`tools/phone/adb.sh shell "su -c 'sh -s'" < design-qa/bf-fps-20261103/sample.sh` (30 s, read-only; divide the
per-thread column by 100) or `tools/phone/verify/bf-prof.sh`. Pass = main thread on cpu7 at >= 2.8 GHz and KWin
`frames:` lines >= 45 fps.
