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

- [ ] 0.1 List every `ww-*.sh` and window check with its lane (`emu`, `phone`, `emu+phone`) in its `# lanes:` header.
- [ ] 0.2 Move lifecycle and input checks to the emulator lane: `ww-opens`, `ww-close-min`, `ww-clamp`, `ww-stop`,
  `ww-popup-x11`. Linux web windows already draw there (CPU copy path, `docs/research/nonroot-parity.md` 11-04).
- [ ] 0.3 Keep on the phone only what needs it: `ww-resize`, `ww-glue`, `ww-drag-lag`, `window-bench`, games.
- [ ] 0.4 Agree fixed phone test blocks with the user (the phone is the daily driver), and run the phone checks there.
- [ ] 0.5 Baseline run, recorded in `docs/research/window-bench.md`: pass/fail per check, `pf=` and `lag=` from the host's
  `w.f` log, missed vsyncs per resize from `ww-resize.sh`, the perfetto verdict from `resize-trace.py` (still owed).
- [ ] 0.6 Each failing check on the board gets one line: real bug, check bug, or environment.

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
- [ ] 1.2 **Touch injection on its own thread.** `helper.touch` posts to `io` (`WebWindows.kt:4113`), behind task polling
  (`reconcileNow`, `:423`), mirror retries (`:1505`) and resizes. Give input a dedicated `HandlerThread`; keep ordering
  per window.
  - Check: a JVM test that a blocked `io` task does not delay a touch line; phone: touch-to-injection latency logged.
- [ ] 1.3 **Frame prediction off, then measure.** Set `geometryChannel.ahead` off (the host stops sending `w.ahead 1`).
  Compare `pf=`, rAF `dt` and missed vsyncs over `ww-glue.sh` with it on and off. Keep N1 (main-thread slides).
  - If off is equal or better: delete `sendAhead`/`sampleAhead` (`webwindows.tsx:2709-2755`) and `FrameSync.ahead`/
    `correct` (`FrameSync.kt`), and tick N2 as withdrawn in `docs/WEB_WINDOWS.md`.
- [ ] 1.4 **One writer for full-screen layers.** `apply()` (`WebWindows.kt:1688`) restates every full-screen window's
  layer (`fullLayer`, idempotent) at the end of each geometry transaction, so the last write on every draw is right.
  Then remove the 250/1,000/3,000 ms restate timers (`restateFull`, `FULL_RESTATE_MS`).
  - Check: `WebWindowsFullScreenRaceTest` extended with "a placement queued before full screen lands after it".
- [ ] 1.5 **Cheaper per-frame measure.** In `entry()` (`webwindows.tsx:2266`): read `--inset-top` and `--color-surface`
  once per tick, not per window (`mergeOf`, `fillOf`, `layoutSize`); call `document.getAnimations()` once per tick and
  share it between `glueFrame` and the ahead code.
  - Check: gate `ww-resize-cost` and `__ww.tickMs` p95 before and after.
- [ ] 1.6 **Measure composition with glass off** (hypothesis: the blur over windows forces GPU composition; older trace:
  360 of 361 frames GPU-composited with a window open). Record composition types from `dumpsys SurfaceFlinger` with 1, 3
  and 6 windows, glass on and off. Decide from the numbers whether blur pauses while a window moves or resizes.

Done when: 1.1-1.5 landed with their before/after numbers in `window-bench.md`; 1.6 has a written verdict.

## Phase 2: one snapshot as the authority (C1, C2)

Goal: the host owns which windows exist and their state; the page owns layout. The page can be reloaded at any time
and lose nothing.

- [ ] 2.1 **Write the contract** in `docs/WEB_WINDOWS.md`: one host snapshot (`webwindows.list`) with a generation
  number, one event `webwindows.changed <generation>`. Real-time events that stay: `webwindows.moveresize`,
  `webwindows.resend`, input.
- [ ] 2.2 **Snapshot carries everything.** `list()` (`WebWindows.kt:146`) adds: pending Linux offers (`pendingLinux`,
  `:806`) with their key, label, `ownFrame` and `alts`; `failed`; and the page's layout record per window.
- [ ] 2.3 **Layout record.** The page writes an opaque record per window (page, frame, restore, scale, tile slot, tab
  group) to the host on change (`webwindows.layout`), and one per page for tilings. The host stores and returns it,
  and persists it across an app restart (the store).
- [ ] 2.4 **Page diffs the snapshot.** `rebuildFromHost` (`webwindows.tsx:585`) becomes the one sync: on load, on
  `webwindows.changed`, and on `native` reconnect. It adds, updates and removes; it restores tiles, tabs and pages
  from the layout records.
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
- [ ] 3.2 **Pure transition function** `(state, event) -> (state, effects)` in its own file, no Android imports.
  Events: page asks, KWin lines, task changes, display changes, timers that are real waits (for example the PiP leave).
- [ ] 3.3 **Port the existing tests** onto it (`WebWindowsFullScreenRaceTest`, `...SelfFullScreenTest`,
  `...MinimisePipTest`, `...ReconcileTest`, `...HomeReturnTest`, `...ImmersiveTest`) and add one per bug on the board.
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
