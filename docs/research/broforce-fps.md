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

## How to re-measure

`tools/phone/adb.sh shell "su -c 'sh -s'" < design-qa/bf-fps-20261103/sample.sh` (30 s, read-only; divide the
per-thread column by 100) or `tools/phone/verify/bf-prof.sh`. Pass = main thread on cpu7 at >= 2.8 GHz and KWin
`frames:` lines >= 45 fps.
