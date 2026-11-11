# Web windows: the fix plan

Status: **plan, 2026-11-10. Nothing here is built or measured yet.** Tick a box in the commit that lands the step.
Design background: `docs/WEB_WINDOWS.md`. Measurements: `docs/research/window-bench.md`.

The user, 2026-11-10: "I want to finish up the window management and remove all the window bugs at least before
progressing", and "it already mostly works".

## Why this plan

The remaining window bugs are mostly not rendering bugs. A full read of the window code (2026-11-10: `WebWindows.kt`,
`shell/ui/webwindows.tsx`, `WebWindowSource.java`, `WindowTasks.java`, `FrameSync.kt`) found seven causes. Each phase
below removes one.

| # | cause | where | what it produces |
|---|---|---|---|
| C1 | Four lists say which windows exist, kept in agreement by timers | `webwindows.tsx:113` `webWins`, `WebWindows.kt:93` `wins`, `WebWindowSource.java:84` `ids`, `WindowTasks.java:79` `tasks` | "exists in KWin but never surfaced", ghost frames, windows left as bare tasks |
| C2 | Tiles, tabs and page membership live only in page memory | `webwindows.tsx:579` | every page reload (the render watchdog's `web.reload()`, `WebWindows.kt:419`) puts all windows floating on one page |
| C3 | A window's state is about 16 independent flags; full screen has two writers | `WebWindows.kt:624` `Win`, `:4492` `FULL_RESTATE_MS` | full-screen races, close/minimise regressions |
| C4 | One worker thread (`io`) carries touch injection, display resizes, task polling, mirror retries and a SurfaceFlinger dump | `WebWindows.kt:95`, `:1721`, `:1781` | hitches at the start of drags and resizes (hypothesis: the dump runs 300 ms after every raise) |
| C5 | Frame prediction measures every window twice a frame | `webwindows.tsx:2746` `sampleAhead` | late page frames during slides get later (phone 11-07: 341 predictions sent, 4 applied) |
| C6 | The page decides who owns a touch, after an async round trip | `webwindows.tsx:3557`, `WebWindows.kt:2586` (HACK) | a fast tap on a Linux window is lost; Android touches are re-injected one bridge call per event |
| C7 | One on/off switch needs root, but only Android windows need root | `WebWindows.kt:4788`, `webwindows.tsx:147` | no Linux web windows on an unrooted phone |

Unverified parts are marked **hypothesis**. Measure before and after (user rule: don't assume, measure).

## Rules for every step

- [ ] One step, one commit, one check. No step is a rewrite; every existing feature keeps working.
- [ ] Before landing: `shell/dev/gate.sh --tree`, the JVM tests of the touched classes, `tools/agents/tier1.sh`.
- [ ] Every fixed bug gets a check that fails without the fix (a control run proves the check can fail).
- [ ] New `HACK:` markers get their row in `docs/REMOTE-POWOS.md` §4 in the same commit; removed ones lose it.
- [ ] No new window features until the exit bar passes.

## Exit bar (what "done" means)

- [ ] Every `tools/phone/verify/ww-*.sh` check and `window-bench.sh` passes three runs in a row on the OnePlus.
- [ ] The lifecycle and input checks also pass on the emulator lane.
- [ ] Zero open tasks in the board's "Windows" section.
- [ ] One week of the user's daily use with no new window bug reported.
- [ ] The old overlay and floating-task paths are removed (phase 7).

---

## Phase 0: make checking possible

The board shows window checks failing by timeout or waiting days for a free phone window. Fix that first.

- [x] 0.1 List every `ww-*.sh` and window check with its lane (`emu`, `phone`, `emu+phone`) in its `# lanes:` header.
  Done 11-10: `ww-drag-lag.sh`, `game-window.sh` (phone) and `window-dock.sh` (emu phone) had none; the table is in
  `docs/AGENT-HANDBOOK.md` "The emulator lane" (window-check rows). Libraries (`ww-lib.sh`, `wwc-lib.sh`,
  `window-lock.sh`) carry no marker, as the handbook's rule says.
- [ ] 0.2 Move lifecycle and input checks to the emulator lane: `ww-opens`, `ww-close-min`, `ww-clamp`, `ww-stop`,
  `ww-popup-x11`. Linux web windows already draw there (CPU copy path, `docs/research/nonroot-parity.md` 11-04).
  **Blocked 11-10, needs the owner's OK for disk:** the lane's AVD has no Linux session. Probed on its snapshot
  (`emu.sh start`, origin d2bce2f6): no `/data/powos/root`, no `kwin_wayland`, and `/data` is 5.8 GB with 4.7 GB free,
  so the rootfs (6+ GB unpacked) can't be installed there. The 11-04 proof ran a hand-set-up session that the
  snapshot never kept (every start is the snapshot of 10-24). The five checks keep `# lanes: phone` until then.
  Proposal: `emu.sh create` with a 16 GB data partition, the base image and Kate/Dolphin installed through the normal
  non-root first run, then the snapshot `powos-ready` taken with the session up (the AVD grows from ~14 GB to about
  26 GB; the Mac has 74 GB free, `emu.sh` refuses below 25 GB). Then flip the five headers to `# lanes: emu phone` and
  prove each with one `queue.sh add --dev emu` PASS. The lane's lock was also hardened (pid 1 / junk is never a
  holder) and its tier-1 test no longer writes the real `~/.cache` lock.
- [x] 0.3 Keep on the phone only what needs it: `ww-resize`, `ww-glue`, `ww-drag-lag`, `window-bench`, games.
  Done 11-10: these four say `# lanes: phone` (frame timing, missed vsyncs, perfetto, real touch speed), games are
  refused on the emulator by `queue.sh`'s HW_ONLY; the handbook row marks them phone-only for good.
- [ ] 0.4 Agree fixed phone test blocks with the user (the phone is the daily driver), and run the phone checks there.
  **Proposal (11-10, for the owner to accept or change; nothing is switched on yet):**
  - **Nightly block, 02:00-05:00.** The phone lies unfolded on its charger. The runner takes only that block for the
    window checks (`ww-resize`, `ww-glue`, `window-bench` parts 1-4, the `ww-*` lifecycle checks until 0.2's emulator
    lane carries them): about 16 checks of at most 300 s, so at most 80 min a run and two full runs a night (the exit
    bar's three passes in a row take two nights).
  - **One daytime block of 20 min**, at a time the owner picks (for example 13:00), for a fix that needs a verdict the
    same day. Outside both blocks the queue keeps its current rule (2+ idle minutes), for everything else.
  - **What the owner does:** leave the phone unfolded on the charger at night. The runner wakes it and turns the
    screen off again after (`window-lock.sh`'s `wl_wake`/`wl_sleep`, as now); Do Not Disturb for the block is new.
  - **To build when accepted:** a `--block night|day` option for `queue.sh add` (a job waits for its block), and the
    block hours in one setting on the phone (Settings > Developer), so the owner can move them without an agent.
  - **Alternative:** a second OnePlus Open as a test device (open decision below). Then no blocks are needed.
- [ ] 0.5 Baseline run, recorded in `docs/research/window-bench.md`: pass/fail per check, `pf=` and `lag=` from the host's
  `w.f` log, missed vsyncs per resize from `ww-resize.sh`, the perfetto verdict from `resize-trace.py` (still owed).
  - 11-10 corner/edge resize (`ww-resize.sh`, jobs 20261110-010936 and 20261108-193450, KWin 3.77): 18-36 missed
    shell vsyncs a drag. Not the main thread: home's main thread only waits (`postAndWait` = `draw-VRI` up to 50-60 ms);
    the time is WebView's GPU work on home's RenderThread (`WebViewFunctor::drawGl` 20-62 ms frames while the finger
    moves, 2-5 ms after it lifts) and SurfaceFlinger GPU-compositing every frame (56/56, RenderEngine up to 14 ms),
    with a Broforce left running beside it in every run (1.0-2.5 cores of CPU and its GPU work). **Hypothesis:** the
    per-move rewrite of `.page-under`'s full-screen CSS mask (`resizeLive` -> `writeMask`) re-rasters a 2268x2440 mask
    and its render surface each frame. The check now traces the `webview` atrace category (Chromium's slices inside
    drawGl) and names other busy processes on the FAIL line ("load:"), so the next run decides it; fix after that.
    The check also ends inside its budget (`WWR_DEADLINE_S`, 250 s: a gesture it can't finish is a "FAIL budget" line)
    and its record pass works again (ffmpeg 9 dropped `-vsync`: "record: no frames" on every run).
  - 11-10 06:39 trace (dolphin edge out, webview category): the 16 drawGl frames over 15 ms spent 484 of 543 ms with
    home's RenderThread asleep (3.4 ms a frame running); WebView's in-process GPU thread (`Chrome_InProcGpuThread`) ran
    513 ms in them (~32 ms CPU a frame), Blink's `CrRendererMain` ~17 ms a frame. The `webview` atrace category gave
    no slice inside drawGl, so the trace now adds the `track_event` source (cc/viz/gpu/blink/skia) to name the raster.
    Fix RJ1 (`holeBox`): a live-resized window's hole steps outward by 48 px, so the full-screen masks change once per
    48 px of drag, not every move; `resizeEnd` writes the exact mask. "ahead" (0.6 %) is not addressed yet.
    Check speed: a gesture took ~90-107 s (0602's file times: two adb.sh pushes ~6 s each, two 7-9 MB pulls ~10 s each
    at 2 MB/s, attribution after the KWin wait, a 30 Mbit/s mp4 pulled). Now the config goes once over stdin, traces
    come back gzip'd over exec-out (~3 MB), attribution overlaps the wait, and each gesture logs a "time:" line.
  - The "ww-popup-probe.py popup" lines in ww-glue were `tail -3` of KWin's whole log (ww-popup-x11's 06:28 run; the
    probe had quit): ww-glue now reads only its own run's lines; ww-popup-x11 removes its root-owned files as root.
  - 11-10 08:40-08:51 (RJ1 live, kate/dolphin/calc, no game): drawGl p50 2.7-4.3 ms, p90 9-11 ms, 2-8 frames a way over
    12 ms (RenderThread in `WaitSyncToken` on the GPU thread's tile raster, ~2 RasterTasks a frame); the missed vsyncs
    are mostly "held" (30-35 a way): SF verdict surfaceflinger-gpu, 86/87 display frames GPU-composited, RenderEngine
    ~5 ms a frame (max 11.5). dumpsys: every layer from the wallpaper through home and the bars is
    `forceClientComposition=true clientType=BLUR` - home's blur regions force SF to GPU-compose the whole stack each
    frame. RJ1 (stepped holes) was taken out: the mask was never shown to cost the time (no clean pre-RJ1 trace: all
    had Broforce beside them) and it cost a visible strip. RJ2 (`nativeglass.ts dragPause`, HACK registered): no blur
    regions while a resize drag moves, so HWC composes in hardware; the glass is unblurred for the drag.
    The 08:4x runs were killed at 300 s: a bare `wait` for the attribution also waited for the logcat reader. Now
    `wait` names its pids, a watchdog stops the check at 275 s (window-bench's pattern) and the EXIT trap closes its
    windows (and any new window of its apps' keys) in one page call on every path.
  - 11-10 09:34-09:38 (RJ2 live): unchanged - 87/88 .. 137/138 display frames GPU-composited. RJ2 did run: blur draws in
    SF's RenderEngine fell from 2.9 to 1.9 regions a frame over the drag (kate edge out, 0840 vs 0934), RenderEngine
    4.8 -> 4.1 ms a frame. The blur owner left is the verify runner's own pill (`PowOS verify status`, VerifyRun.kt,
    glass on over home's page): it alone forces every layer CLIENT, so no window check ever measured device
    composition. Fix: the pill drops its glass while any web window is up (`WebWindows.anyShown`, test
    VerifyPillGlassTest). RJ2 stays for one A/B: `WWR_GLASS_PAUSE=0` keeps home's regions through the drag; the
    record pass logs "mid-drag: blur owners ...; HWC layers CLIENT n, DEVICE m". If on vs off shows no DEVICE gain, RJ2
    goes.
  - 11-10 10:07 (kate, pill and RJ2 on): "blur owners: none; HWC layers CLIENT 11, DEVICE 15" - that count took both
    displays; the idle outer display's stale table alone has 8 CLIENT, so ~3 on the main one (the window's container
    layers carry a corner radius: `cornerRadius` in WebWindows.place). RJ3 (`dragSquare`, HACK registered): square
    corners while RS1's `resizing` is set; A/B `WWR_DRAG_ROUND=1`. The probe (`sf-comp.awk`) now reads the main
    display only and names each CLIENT layer with its forced reason and "rounded"; the full mid-drag dump is saved.
  - 11-10 23:21 (kate corner, SF dump taken during the confirmed drag, `ww-resize-1110-2321`): RJ3 square corners gave
    nothing (timed 232558: 69 missed vsyncs, 45% janky; round 232612: 62, 35%). CLIENT on the main display: wallpaper
    (OEM live wallpaper, ROT_270), Termux (the user's window, ROT_270), `powos-ww-54-linux`, and `powos-ww-65-fill`
    (ROT_270, source crop 0x0). The fill was a 1x1 buffer drawn through Surface(SurfaceControl).lockCanvas: a CPU
    canvas never applies the transform hint, so on the rotated-mounted panel (framebufferSpace ROTATION_270) SF gave
    HWC the buffer with the display's inverse, and the container's crop of a 1 px buffer scaled 8192x was ~0.12 px =
    a 0x0 crop. Fix: the fill is a color layer (`WebWindows.newFill`, hidden setEffectLayer + setColor: no buffer,
    HWC SOLID_COLOR). RJ3 removed (code, HACK row, the probe's WWR_DRAG_ROUND; the validator now requires the
    radius through the drag). window-bench's leak count now counts pool-taken displays (`powos-ww-spare-<n>` keeps
    its name; WW_LAYERS, SparePoolTest.aStormKeepsExactlyOneUntakenSpare).
  - 11-11 00:15/00:17 (APK 2226293a, `ww-resize-1111-0015` dump, `-0017` traces): the fill is a color layer now
    (SOLID_COLOR, no BBQ) but CLIENT with clientType=ROUNDEDCORNER: it inherits the container's cornerRadius (33.1)
    like the app layer (`powos-ww-8-linux` CLIENT, BLUR|ROUNDEDCORNER). The HWC table's ROT_270 / 0x0 crop for a
    bufferless layer are only defaults. Moving it out from under the rounded container would show square
    fill-colored corners, the same thing RJ3 showed, and it only removes 0.07 ms a frame. Measured (in / out ways): SF
    drawLayersInternal p50 2.1/1.9 ms, p90 4.9/5.1 (CPU). Per frame: linux layer 0.49/0.67 ms, home 0.33/0.26, wallpaper
    (OEM, always CLIENT) 0.16/0.17, fill 0.07/0.07 ms; SF GPU Deadline Missed on 18/116 and 15/129 display frames.
    Home RenderThread: DrawFrame p50 5.9/6.7 ms, p90 14.6/12.2 ms (120 Hz budget 8.3 ms). WebViewFunctor::drawGl p50
    2.7/3.9, p90 12.7/10.6, max 106/69 ms. 98/101 and 113/114 home frames were late. Next target: the shell's frame
    (drawGl p90 and its 70-106 ms spikes), not composition. Our layers are about a quarter of the SF frame's CPU cost,
    and that frame still runs on the GPU for the wallpaper.
  - 11-11 page frame over the drag (`ww-resize-1111-0017` in, 1728 ms): the 106 ms drawGl is RenderThread in
    WaitSyncToken (80.7 ms) behind Chrome_InProcGpuThread's RendererRasterWorker (28.4 ms, DoEndRasterCHROMIUM::Flush
    21.5 ms). Tile raster by cc layer: 566 `.page-under` 124 tiles (21.6 MB), 567 `.page-windows` 97 tiles (4182x2115),
    577/578 `.ww-outline` 29. The per-move mask writes (`resizeLive` -> `writeMask(.page-under)`, `cutAll`) and the
    resized `.ww-shadow` box repaint and re-raster those whole layers on every move. GPU thread: 433 ms of GpuChannel
    work over the drag. Renderer main thread: BeginMainFrame 826 ms over 284 frames; rAF callbacks 187 ms
    (max 13.6 ms); NotifyResizeObservers 119 ms; paint 118 ms; commit 83 ms; style and layout about 60 ms. Forced
    layouts in rAF are cheap (778, 6.7 ms in total).
    Load the check itself caused: logd 1275 ms + logcat 729 ms of CPU over the drag. The phone had 7 orphaned
    `logcat -v time -s PowosWebWindows:I ...` readers from ww-resize.sh (the host killed only its adb). Fixed: the
    reader's device pid is killed in restore(), and timeout 330 bounds it (test-resize-state). Also there are 2 orphaned
    `logcat ... PowosShade:V ...` readers from another check.
    Next: keep the per-move raster off `.page-under` and `.page-windows`. Give the mask and the shadow their own small
    composited layers (a hole that follows by transform, a 9-slice shadow), so a move re-rasters no full-page layer.
  - 11-11 RS6 (shell): during a resize drag the dragged window's shadow is a 9-slice of itself
    (`webwindows.tsx sliceShadow`: 8 composited pieces, moved and stretched by transform, whole again at the end).
    While any window on the page is being resized, every frame and shadow there is its own layer
    (`.page-windows:has(.ww-resizing)`). Gate ww-resize-cost RS6 (LayerTree.layerPainted over 2x60 moves). Before:
    `.page-under` 120x at 93% of the page, `.page-windows` 120x at 56%. After: `.page-windows` 0. The dragged frame
    repaints only its own layer (120x at 33%); the 9-slice pieces paint once at the drag's start. Still left: the lower
    windows' frames and shadows, 360x each at up to 26% (their mask holes follow the dragged window), and
    `.page-under` 120x at 93% (its mask; printed, not failed - HACK in the gate).
  - 11-11 RS6b: `.page-under` has two cc layers. Its content painted 0x over the moves; only its mask layer (+4 px,
    solid fills) repaints, 0.11 ms a tile and ~1 tile a frame on the phone (layer 566: 13.9 ms of raster over 1.7 s).
    The content layer 565 rastered 3-4 tiles. A hole that follows by transform can't be done with a CSS mask: it would
    need a second copy of the page's content, or the app layer above home's surface for the drag (host side). Not
    worth that cost. Shadows now keep their blur in a composited child while a window is resized (shell.css RS6), so
    the lower windows' shadows repaint only their mask layer (360x at 26%; it was the blur itself). The gate
    exemption HACK is gone: RS6 tells mask layers (an element's second layer) from content, and fails when page-wide
    content repaints after a drag's first moves. Control: without the composited frames, `.page-windows` 120x -> FAIL.
    Still repainting: the lower frames' own content, 360x at 16% (the frame's mask change invalidates it).
  - 11-11 LH1 (host + shell): during a resize drag the top window's app layer is lifted ABOVE home's buffer (home's
    bounds layer at `LIFT_LAYER` = FULL_LAYER - 1, under popups and full screen; `WebWindows.lift`), so no page hole has
    to follow it: its hole leaves `.page-under`'s and the lower windows' masks once at the drag's start and the exact
    masks are written once at its end (`webwindows.tsx liftStart/liftEnd/liftTick`). The page says it in the "w.f"
    <resizing> word (2 = resizing + lifted, 3 = lifted only); each switch overlaps by LIFT_FRAMES page frames (lifted
    with the hole still cut: same pixels), so a late apply never shows the page over the app (a marked HACK, a frame count; real
    fix a host ack). While lifted the bar is drawn solid (no hole under its unblurred glass) and the size label sits in
    the bar (DOM over the body is under the app). The resize fill is cropped to the body (lifted, it painted over the
    bar's bottom radius band). Option (b), a hole layer moved by transform, is not possible with a CSS mask (RS6b).
    Gate ww-resize-cost LH1 (lower frames, their shadows' masks, `.page-under`'s mask: at most 4 paints a pass):
    before (HEAD) `.page-under` (mask) 121x, lower frames 180x + their masks 180x, lower shadows' masks 180x -> FAIL;
    after 3x / 6x / 4x / 4x -> PASS. Owed: the phone's timed check (`ww-resize.sh`, kate corner).
- [x] 0.6 Each failing check on the board gets one line: real bug, check bug, or environment.
  Done 11-10: seven board tasks got a "0.6" step line; the table is in `docs/research/window-bench.md` "11-10
  baseline". None of the failures was a judged real bug: they were check bugs or the environment, most of them home's
  page not answering CDP calls in the runner's window.

Done when: every window check gives a verdict (PASS or a named FAIL) within its budget, on its lane.

## Phase 1: quick wins (small, independent)

- [x] 1.1 **SurfaceFlinger order check off by default.** `orderCheckSoon` (`WebWindows.kt:1721`) runs
  `dumpsys SurfaceFlinger`, through root when refused (`:1781`), 300 ms after every change of window order and every
  10 s with two or more windows. Gate it behind a debug property (for example `debug.powos.ww_order_check`), keep it in
  the verify scripts.
  - Check: `ww-drag-lag.sh` and `ww-resize.sh` before and after; no `dumpsys` child of the app during a drag.
  - Landed 11-10: `orderCheckSoon` returns unless `debug.powos.ww_order_check` is `1` (read in-process,
    `SystemProperties`); `window-bench.sh`'s switch phase turns it on for two raises and FAILs on a divergence line.
    JVM: `WebWindowsLayerOrderTest.offByDefault`. Phone before/after numbers: owed (queued after the ship).
- [x] 1.2 **Touch injection on its own thread.** `helper.touch` posts to `io` (`WebWindows.kt:4113`), behind task polling
  (`reconcileNow`, `:423`), mirror retries (`:1505`) and resizes. Give input a dedicated `HandlerThread`; keep ordering
  per window.
  - Check: a JVM test that a blocked `io` task does not delay a touch line; phone: touch-to-injection latency logged.
  - Landed 11-10: `Helper.touch` posts to its own `powos-ww-input` thread (display priority); the helper's pipe is
    shared under the Helper's lock; a down/up that waited > 8 ms for that thread logs "touch line waited N ms".
    JVM: `WebWindowsInputThreadTest` (control: fails with `touch` back on `io`). Phone latency: owed (queued).
- [x] 1.3 **Frame prediction off, then measure.** Set `geometryChannel.ahead` off (the host stops sending `w.ahead 1`).
  Compare `pf=`, rAF `dt` and missed vsyncs over `ww-glue.sh` with it on and off. Keep N1 (main-thread slides).
  - If off is equal or better: delete `sendAhead`/`sampleAhead` (`webwindows.tsx:2709-2755`) and `FrameSync.ahead`/
    `correct` (`FrameSync.kt`), and tick N2 as withdrawn in `docs/WEB_WINDOWS.md`.
  - Landed 11-10 (off): the host sends `w.ahead 1` only with `debug.powos.ww_ahead=1`; `ww-glue.sh` takes
    `WW_AHEAD=on|off` (the page's `__ww.aheadOn`, now readable) and reports home's rAF dt p50/p95 and missed vsyncs.
    JVM: `WebWindowsAheadTest.aheadIsOffByDefault`. The A/B (on vs off) is queued; the deletion waits for it.
- [x] 1.4 **One writer for full-screen layers.** `apply()` (`WebWindows.kt:1688`) restates every full-screen window's
  layer (`fullLayer`, idempotent) at the end of each geometry transaction, so the last write on every draw is right.
  Then remove the 250/1,000/3,000 ms restate timers (`restateFull`, `FULL_RESTATE_MS`).
  - Check: `WebWindowsFullScreenRaceTest` extended with "a placement queued before full screen lands after it".
  - Landed 11-10: `apply()` ends every geometry transaction with `fullLayer` of each full-screen window;
    `FULL_RESTATE_MS`/`restateNow` are gone. Kept on its own timers: the immersive status bar's re-hide
    (`IMMERSIVE_REHIDE_MS`, 250/1,000/3,000 ms) - a system bar state, not a layer write. JVM:
    `WebWindowsFullScreenRaceTest.aPlacementQueuedAfterTheFullScreenEndsWithIt` (control: fails without the rewrite).
- [x] 1.5 **Cheaper per-frame measure.** In `entry()` (`webwindows.tsx:2266`): read `--inset-top` and `--color-surface`
  once per tick, not per window (`mergeOf`, `fillOf`, `layoutSize`); call `document.getAnimations()` once per tick and
  share it between `glueFrame` and the ahead code.
  - Check: gate `ww-resize-cost` and `__ww.tickMs` p95 before and after.
  - Landed 11-10: `geometry()` reads the root's tokens once (`rootTokens`), `send()` walks `getAnimations()` once
    (`frameAnimations`). Gate `ww-idle-tick` now counts both (3 windows, N2 on): before 3 root style reads a measure and
    2 walks a send (control run FAILs), after 1 and 1. `ww-resize-cost` (gate box, 4 windows): tick p50/p90 0.3/0.5 ms
    before, 0.3/0.6 ms after - within the box's noise; the phone's `tickMs` is what counts (window-bench, queued).
- [ ] 1.6 **Measure composition with glass off** (hypothesis: the blur over windows forces GPU composition; older trace:
  360 of 361 frames GPU-composited with a window open). Record composition types from `dumpsys SurfaceFlinger` with 1, 3
  and 6 windows, glass on and off. Decide from the numbers whether blur pauses while a window moves or resizes.
  - 11-10: the A/B is `tools/phone/verify/ww-composition.sh` (glass switch: the page's `__glass.live.native(false)`,
    put back after; rest and bar-drag samples per window count). Queued; nothing applied. Verdict owed.

Done when: 1.1-1.5 landed with their before/after numbers in `window-bench.md`; 1.6 has a written verdict.

## Phase 2: one snapshot as the authority (C1, C2)

Goal: the host owns which windows exist and their state; the page owns layout. The page can be reloaded at any time
and lose nothing.

- [x] 2.1 **Write the contract** in `docs/WEB_WINDOWS.md`: one host snapshot (`webwindows.list`) with a generation
  number, one event `webwindows.changed <generation>`. Real-time events that stay: `webwindows.moveresize`,
  `webwindows.resend`, input.
  - 11-11: `docs/WEB_WINDOWS.md` "The host snapshot: the contract" - `webwindows.list(true)` = the object, the bare call
    keeps the array until 2.4.
- [x] 2.2 **Snapshot carries everything.** `list()` (`WebWindows.kt:146`) adds: pending Linux offers (`pendingLinux`,
  `:806`) with their key, label, `ownFrame` and `alts`; `failed`; and the page's layout record per window.
  - 11-11: `WebWindows.snapshot()` = `webwindows.list(true)`: `generation` (bumped by every state event but
    moveresize/resend, every open/drop, every offer made/taken), `windows` (list(), each Linux one with `failed` once
    its consumer gave up), `pendingLinux` [{kwin, key, label, ownFrame, alts}]. The bare `webwindows.list()` stays the
    array (page unchanged). The layout record field comes with its writer in 2.3; `webwindows.changed` is emitted from
    2.4 on. Check: `WebWindowsSnapshotTest` (control run with a wrong generation FAILs).
- [x] 2.3 **Layout record.** The page writes an opaque record per window (page, frame, restore, scale, tile slot, tab
  group) to the host on change (`webwindows.layout`), and one per page for tilings. The host stores and returns it,
  and persists it across an app restart (the store).
  - 11-11: `webwindows.layout(id, json)` / `webwindows.pageLayout(page, json)` (`WebWindows.LayoutRecords`): stored
    as written, never parsed, no generation bump; snapshot `windows[].layout` + `pages`; a window's record goes in
    `drop()`. Page: `WindowLayout` {page, frame, restore, untiled, scale, minimised, tile {layout, slot}, tab {ids,
    active}} + `PageLayout` {tiling, tabs}, written 400 ms after the last change, only what changed. Check:
    `WebWindowsLayoutTest` (control run with a wrong record FAILs). **Not done: persistence across an app restart** -
    window ids restart with the app (and KWin's with KWin), so a stored record has nothing stable to key on; do it
    with 2.8's session-scoped keys.
- [x] 2.4 **Page diffs the snapshot.** `rebuildFromHost` (`webwindows.tsx:585`) becomes the one sync: on load, on
  `webwindows.changed`, and on `native` reconnect. It adds, updates and removes; it restores tiles, tabs and pages
  from the layout records.
  - 11-11: host emits `webwindows.changed <generation>` (`WebWindows.ChangedSignal`: one per main-loop turn, after the
    bump's per-fact event; `alive` no longer bumps - it restated the ids every heartbeat). Page: `rebuildFromHost` reads
    `list(true)`, one sync at a time, older generations ignored; removes, adds (layout record's page/frame, then the
    page records' tilings + tab groups), applies host facts only where they changed since the previous snapshot (the
    per-fact handlers' own paths: a late event is a no-op), adopts lost `pendingLinux` offers. Contract:
    `docs/WEB_WINDOWS.md` "The page's sync". Checks: gate `webWindowSnapshotSync` (SY1: dropped minimise/live/close/
    open, late events, older generation, lost adopt, tiling restore; control with the `changed` listener off FAILs),
    JVM `WebWindowsChangedTest` (coalescing + generation; control with `changed()` not signalling FAILs).
    Not proven on the device yet; 2.7's reload scene is still to write.
- [ ] 2.5 **Retire the per-fact events** once 2.4 is proven: `webwindows.alive`, `.closed`, `.full`, `.state`, `.pip`,
  `.live`, `.frame`, `.failed`, `.adopt` (each becomes a field in the snapshot). One at a time, each with its gate.
- [ ] 2.6 **Retire the timers that covered lost events:** `CLAIM_MS` hide (`WebWindows.kt:4271`), `LINUX_ADOPT_MS`
  fallback to a task (`:4810`) becomes "no page for N s" only, `staleInPage` (`:2579`), IR1's stale-full check
  (`:2561`), the page's `BOUND` timer (`webwindows.tsx:369`).
- [ ] 2.7 **Watchdog reload is safe.** With 2.3-2.4 a `web.reload()` (`WebWindows.kt:419`) keeps every window's page,
  tile and tab. Gate scene: three windows tiled on page 2 plus a tab group, reload, same layout.
- [ ] 2.8 **Web windows are session-scoped.** `WebWindowSource.ids` is a bare id set, and KWin's ids restart at 1 with
  each KWin (`WindowTasks.java:49`). Key web windows by KWin session + id, as window tasks already are.

Checks: gate scenes `ww-reload-keeps-layout`, `ww-offer-during-reload` (an offer made while the page reloads becomes
a web window, not a task); `kwin-restart-windows.sh`; `WebWindowsReconcileTest` extended.

Done when: reloading home at any moment of a launch, a resize or a full screen leaves the same windows in the same
places, and the nine events and five timers above are gone.

## Phase 3: one state per window (C3)

- [ ] 3.1 **State type.** Replace the flags in `Win` (`full`, `linuxFull`, `fullAsked`, `fullHeld`, `immersive`, `pip`,
  `minimised`, `leftAt`, `landed`, `adopt`, `claimed`, `live`, `closed`, `followed`) with one sealed state plus its
  data: Opening, Live(floating), Minimised, MinimisedAsPip, FullAndroid, FullLinux(asked/confirmed/held, immersive),
  Pip, Closing.
- [x] 3.2 **Pure transition function** `(state, event) -> (state, effects)` in its own file, no Android imports.
  Events: page asks, KWin lines, task changes, display changes, timers that are real waits (for example the PiP leave).
  - 11-11: `WebWindowState.kt` (`WebWindowMachine.step`), not used by `WebWindows` yet (3.1's swap is next). Derived
    from today's flag writes (KDoc cites WebWindows.kt lines); reuses the companion's pure rules (`pipStep`, `followOf`,
    `orphaned`, `selfFullScreenNow`, `minimiseGoesPip`). Phases: Live, MinimisedAsPip (`leftAt`), Pip,
    FullAndroid(moving), FullLinux(asked, immersive), Closed; 3.1's names derived (`WinState.name`: Opening = Live not
    landed / adopting, Minimised = Live + minimised). `minimised` and `held` (`fullHeld`) stay booleans beside the
    phase because today they are orthogonal to it (see 3.3's suspects); data: landed, adopt, claimed, live, followed.
    Events - page: Minimise, Restore, FullScreen(kwinCan), ToWindow(kwinCan), Focus, Close, PageLoaded, Claimed, Drawn;
    tasks: Launched, AdoptDone, DisplayTasks, OrphanConfirmed, TaskGone, TaskSeen(at, mode, float), PipBack,
    FollowedBack, FullMoved, BackMoved, LeaveMoved, LeaveFront, LeftTaskSettled; KWin/timers: FullScreen(on, focused,
    open, coming), ConfirmTimeout (1.5 s), ClaimTimeout. Effects: an `Fx` enum + optional `on` (emits, moves, marks,
    cover/resize/place-back, status bar, timers, drop/remove). Not modelled: display changes (refillFull: a resize, not
    a state change); a minimise or bar full screen of an Android window racing a move already in flight (today both
    moves run).
- [x] 3.3 **Port the existing tests** onto it (`WebWindowsFullScreenRaceTest`, `...SelfFullScreenTest`,
  `...MinimisePipTest`, `...ReconcileTest`, `...HomeReturnTest`, `...ImmersiveTest`) and add one per bug on the board.
  - 11-11: `WebWindowStateTest.kt`, 7 classes / 31 tests (`WebWindowState{SelfFullScreen,MinimisePip,Reconcile,
    HomeReturn,Immersive,FullScreenRace,Reload}Test`); the old 29 stay untouched and pass. Control: `kwinOn` covering
    the screen regardless of `selfFullScreenNow` -> 3 FAIL (rc=1). HomeReturnTest's root-visibility rules
    (`rootShownFor`, `swipeShowsHome`) are home's, not a window's state: ported only its window side (a home-gesture
    minimise returns to its window). The source-pin checks (layer order, call sites) stay with the old tests.
    Not yet: one test per board bug. Faithful but SUSPECT (each pinned by a test, not fixed):
    1. a window minimised while its app is in PiP comes back from PiP still listed "minimised" (`pipLeave` keeps
       `minimised`);
    2. `restore` of a PiP window only clears the dock flag, the app stays in PiP (`restore` acts on `leftAt` only);
    3. a held full screen (`fullHeld`) survives a minimise and the bar's full screen; the next `focus` puts the
       minimised window full screen (only KWin's "0" or focus clears it);
    4. "Back to window" while an Android full screen's move is in flight emits full off, then the move lands and
       announces full on;
    5. `Follow.PIP` is unreachable in `follow` (`pipStep` takes every mode 2 first);
    6. a second `minimise` of a just-hidden (no-PiP) window starts `leaveNow` again.
  - 11-11 suspects decided (`WebWindowStateTest`, each comment says why):
    - 1 BUG, fixed: `pipLeave` clears `minimised` (`minimisedIs(w, false)`, as `backNow`); machine `pipOut` the same.
    - 2 INTENDED: PP1 never pulls a PiP back; its own expand (or card) brings the window back (then 1 clears minimised).
    - 3 INTENDED: held = the app still full screen in KWin; the page focuses only a shown window, so restore + press = full.
    - 5 KEPT dead code with a note: `followOf`'s PIP is a pinned rule, the branch = `pipEnter`, harmless.
    - 6 INTENDED: `leaveNow` re-checks PiP support (a log) or retries a failed move; never while a leave is under way.
- [ ] 3.4 **Derived predicates from the state only:** `listedState` (`:180`), `awayByChoice` (`:3859`), `gone` (`:594`),
  `taskDead` (`:443`), `staleFull` (`:2561`).
- [ ] 3.5 The snapshot (phase 2) sends the state's name; the page stops deriving it from separate flags.

Done when: no code outside the state file reads or writes the old flags, and every board bug has a transition test.

## Phase 4: native touch routing (C6)

- [ ] 4.1 **Occluders in the frame message.** The page adds to `w.f` the rectangles of whatever covers a body: windows
  above it (already computed for masks, `holes`/`bodiesOver`), open menus, popovers, the dock. Same frame id as the
  geometry.
- [ ] 4.2 **Host decides at DOWN.** `onTouch` (`WebWindows.kt:2419`) hit-tests the last applied bodies minus occluders
  and takes the whole gesture (returns true), as popups already do (`popupGesture`, `:2364`). Raise and focus go to the
  page as an event.
- [ ] 4.3 **Linux:** the real `MotionEvent` stream straight to KWin (`linuxInput`). Delete the replayed DOWN
  (`linuxClaim`'s HACK, `:2586`) and its registry row.
- [ ] 4.4 **Android:** the real `MotionEvent` (all pointers, history) to the helper's injector. Delete the page's
  per-event `webwindows.input` calls (`webwindows.tsx:3547-3600`) and the root `input` fallback (`injectRoot`).
- [ ] 4.5 **App-drag hand-back.** KWin's `moveresize` (`:3649`) cancels the native gesture and tells the page to take
  the rest of it; check the page still gets pointer events for that touch.
- [ ] 4.6 **Keyboard focus.** Re-check the `FLAG_ALT_FOCUSABLE_IM` toggle (`homeIme`, `:2876`): keep, or replace with
  the host knowing which window owns the gesture.

Checks: emulator `ww-touch.sh`: a 0 ms tap on a Linux window's button registers (today it is lost); a pinch in an
Android window; a tap on a menu over a body goes to the menu; no `webwindows.input` call in the bridge log. Phone:
touch-to-frame with the 240 fps method from `docs/WEB_WINDOWS.md` S3.

Done when: no JavaScript is in the path of a body touch, and `docs/WEB_WINDOWS.md` constraint Z4 is met for both kinds.

## Phase 5: recovery (home, app and KWin restarts)

- [ ] 5.1 **Home restart re-adopts.** Today `closeAll` hands Linux windows back as tasks (`WebWindows.kt:2908`) and
  they stay tasks until the app is tapped. When home's bridge comes up, sweep `WindowTasks.tasks` through
  `moveToWeb` (`WindowTasks.java:580`) for every non-full-screen window.
- [ ] 5.2 **App restart.** After an APK install, the same sweep runs once KWin's `session` line arrives.
- [ ] 5.3 **KWin restart or crash** (board: "a hung game crashes KWin and kills all Linux rendering"). The host marks
  every Linux window "not responding" at once on a lost control channel, and re-adopts by app key when the new KWin
  offers its windows, keeping each window's layout record.
- [ ] 5.4 **Consumer stop never blocks** (board: "stop takes 2.1 s"). Confirm with `ww-stop.sh` after af5ebd750.

Checks: `kwin-restart-windows.sh` (both restarts; Kate and Dolphin back as web windows in their tiles within 20 s),
`kwin-hung-client.sh`, a new `home-restart-windows.sh`.

## Phase 6: performance to the bar

Only after phases 1-4, so the numbers measure the real design.

- [ ] 6.1 Valid `ww-resize.sh` run with perfetto; `resize-trace.py` verdict written into `window-bench.md`.
- [ ] 6.2 Act on the verdict: if SurfaceFlinger GPU composition, apply 1.6's decision; if the page's main thread, cut
  the top `home.frames` verdicts (`docs/research/shell-perf-traces.md` recipe).
- [ ] 6.3 Resize (N4): gfxinfo janky frames 5 % or less over an edge drag; KWin commits about equal to drawn.
- [ ] 6.4 Page switch with a window: `pf0` 99 % or more, or a written reason why not.
- [ ] 6.5 Open: Android open-to-shown p90 under 700 ms, Linux open-to-first-frame p90 under 500 ms (window-bench).
- [ ] 6.6 Games (N5): a windowed Proton game's menu shows; fps x/120 unchanged by N1.

## Phase 7: retire the old paths

Each removal is its own commit with its check; folded Linux tasks keep working.

- [ ] 7.1 The owner confirms that web windows supersede `docs/DESKTOP-KWIN-NATIVE.md` phases 1-5 for windows (the open
  decision at the top of `docs/WEB_WINDOWS.md`).
- [ ] 7.2 Remove the overlay title bars and freeform dressing for the unfolded home (`WindowFrames`, `TaskSurfaces`,
  `PageSlide`/`TaskLeash` paths already stood down by `AppWindows.floating()`).
- [ ] 7.3 Remove floating Linux tasks unfolded: `PowosWindowActivity` stays for folded full-screen tasks and games only.
- [ ] 7.4 Remove the KWin patches only the floating-task path needed (list in `docs/DESKTOP-KWIN-NATIVE.md` §4), each
  with the folded check: Kate opens, types, closes.
- [ ] 7.5 Mark superseded docs with a banner and link here: `DESKTOP-KWIN-NATIVE.md`, the freeform sections of
  `DESKTOP-NATIVE.md`.

## Phase 8: split the files and the switch

- [ ] 8.1 `WebWindows.kt` by concern: state (phase 3), layers and geometry, input, Android source (displays, tasks,
  PiP), Linux source (consumer, full screen), the helper. No behaviour change; the tests are the proof.
- [ ] 8.2 `webwindows.tsx` by concern: model and sync, tiles, tabs, geometry tick, the element and its gestures.
- [ ] 8.3 **Separate the Linux switch from root (C7).** `WebWindows.on` (`:4788`) gates Android windows only; Linux web
  windows turn on wherever home can host a child surface. Check on the razr (unrooted): System Settings opens as a web
  window. This is the first step of the non-root stage.
- [ ] 8.4 Popups (N3): tick the parent box in `docs/WEB_WINDOWS.md` once `ww-popups.sh` passes on kwin 3.72+.
- [ ] 8.5 Switcher: a tiling as one card (open box in "A split pair is one app everywhere").

---

## Board bugs mapped to phases

| board task | phase |
|---|---|
| Linux app opens no window: exists in KWin but never surfaced as a layer | 2 (2.2, 2.6), 5.1 |
| REGRESSION: Linux window close + minimise stopped working | 0.6 (classify), 3, 5.1 |
| A window can land out of bounds | 0.6 (the check failed, not proven the bug), 2.3 |
| Linux web window stop takes 2.1 s | 5.4 |
| Linux app dropdown/popup menus don't show | 8.4 |
| A hung game crashes KWin and kills all Linux-app rendering | 5.3 |
| Windows: flawless and native, glued to pages, no races | 1.3, 1.4, 4, 6 |
| Window handling: benchmark + fix | 0, 6 |
| A game launched from inside Steam shows no placeholder | 2.2 (offers in the snapshot), 3 |

## Open decisions for the owner

- [ ] 7.1 above: web windows supersede the KWin-native plan for windows.
- [ ] Fixed test blocks on the OnePlus (0.4), or a second OnePlus Open as a test device.
- [ ] Blur while a window moves or resizes (after 1.6's numbers).

## Order and size

Phases 0 and 1 first (days). Then 2 and 3 together (they share the snapshot), then 4, then 5. Phase 6 measures. Phases
7 and 8 close. Sizes are not estimated here: phase 0.5's baseline decides them.
