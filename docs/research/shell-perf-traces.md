# Shell perf traces: why the user's traces led nowhere, what they carry now, how to read one

The user, 2026-11-07 00:2x: "can we improve the fps tracing profiling thing with the react scan stuff so that you can
actually get a proper trace? i sent it like 10 times and nothing improves, reactscan catches it fine" and "focus on
performance atm". Board task: *Perf traces the user sends must show what react-scan shows (renders, slow commits) - fix
the offenders*.

## Where a sent trace lands

- The user taps the status bar's fps meter (record), then taps again (stop): `shell/ui/fpsmeter.tsx` collects the
  bar's frames, asks home (`shell/ui/perfrec.ts`) and every surface page (`shell/ui/renderfollow.ts`) for their
  parts over `perf.publish`, and saves the whole JSON through `perf.save` (`ShellBridge.kt`).
- File: on the phone, `/data/user/0/com.powos.app/files/run/powos-ai-shared/perf-<epoch ms>.json` (the guest sees
  `/run/powos-app/powos-ai-shared/`), the last 20 kept. A user's trace (not `source: "verify"`) is mailed to the
  coordinator (`powos comms send coordinator`, priority high) with the summary inline, and posted to PowOS AI.
- Since this change also `perf-<epoch ms>.trace.json` next to it: the WebViews' Chrome trace (`native.chromeTrace`
  names it), the last 6 kept.
- Read them read-only: `tools/phone/adb.sh shell "su -c 'ls -la /data/user/0/*/files/run/powos-ai-shared/ | grep perf-'"`,
  then `... cat <file>` into a scratch dir on the Mac.

## Why the traces didn't lead to fixes (the 20 on the phone, 10-31 .. 11-06)

Read in full: perf-1793970527979 and perf-1793970543446 (11-06, page swipes: p5 24-30 fps, 13 and 53 janks),
perf-1793808327607, -743189695, -735444160 (11-03/04).

1. **The long frames named Preact, not our code.** The worst frames' top script was always
   `event-listener DIV.ontouchend vendor/preact.js 72ms forced 64ms`. Preact delegates every `on*` prop through one
   listener (`eventProxy`), so LoAF's script attribution can only say "preact.js". No component, no handler, no stack.
   (HP4 found the culprit by hand, 2d40ba55, a day later.)
2. **No JS stacks at all.** LoAF has the script entry point only; the trace had no sampling profiler, so "forced 64 ms"
   never said which read forced the layout.
3. **The renders section pointed at the cheap problem.** It listed needless renders (Icon 208 of 212, PillSend/Send 94
   of 95 ...) - exactly what react-scan's outlines show the user - but their time was 3 ms in total, while the frames
   were 70-145 ms. Agents fixed or chased renders and the jank stayed; nothing said "this frame's time was NOT renders".
4. **Frames with no JS were unexplained.** Half the worst frames had `script 0, render 2` with `dur 137`: the page did
   nothing; the main thread waited (FrameMetrics phase `delay` 130 ms, Choreographer frames 35-37 ms on the UI thread,
   no stack). Without a verdict, these read like missing data.
5. **The jank was before the tap.** The recording started at the record tap (+300 ms settle). The user taps record
   *because* something just janked; that frame was never in it, and reproducing it on demand is hit and miss.
6. Minor: the handler's renders and the commit list were capped at the first 600/3000 (oldest kept), so a long
   recording lost its end.

## What a trace carries now (home's detail v2)

- `home.preRollMs` + negative times: while the meter is on, home is *armed* - inputs, state transitions, LoAF, event
  timing and the JS profiler run into rings of the last 8 s (`PRE_MS`); the record tap re-times them onto the
  recording's clock. The render scan's commits and handler calls keep their last 8 s too when the rs overlay was on.
- `home.js` (`shell/ui/jsprofile.ts`): the JS Self-Profiling API (`new Profiler`, 10 ms samples; the page is served
  with `Document-Policy: js-profiling` by `ShellHost.kt`/`WebTrace.shellHeaders` and the gate). `selfTop`: functions
  with the most self time; `frames[]`: per long frame its sampled stacks, leaf first, `fn (file:line) < caller < ...`,
  file names mapped from es-module-shims' blob: URLs.
- Handler attribution (`shell/ui/renderscan.ts`): while scanning, every `on*` function on a DOM element is wrapped and
  timed under its owner component: `Pager.onTouchEnd 43ms`. `renders.handlers` = per handler calls / total / max;
  `renders.handlerCalls` = the calls of 1 ms+, newest kept.
- `home.frames[]` (`perfrec.ts frameVerdicts`), the part to read first: per long frame (50 ms+, longest first)
  `verdict`, `script`, `forced`, `renderStep`, `styleLayout`, the top `scripts`, the `handlers` that ran in it, the
  `components` that rendered + `renderMs`, and the JS `stacks`.
- `native.chromeTrace` (`WebTrace.kt`): a Chrome trace of the recording from Android's TracingController -
  devtools.timeline (+frame, +stack), v8.cpu_profiler, blink.user_timing, cc/viz/gpu - every WebView of the app.
  Open it in https://ui.perfetto.dev or DevTools' Performance panel (Load profile).
- The summary (what the mail and PowOS AI get inline) carries `home.longFrames` = the first 6 verdict rows, `jsSelfTop`,
  `preRollMs`, `renders.handlers`, `native.chromeTrace`.

Cost: meter off = nothing (no hooks, no observers, no profiler; `perf-trace` gate scene checks it). Meter on = the
armed rings (passive listeners, two PerformanceObservers) and the sampling profiler, rolled every 10 s in an idle
callback (a new Profiler costs ~20 ms of main thread in the gate's Chromium). Recording = the render scan's hooks, the
profiler, and the Chrome trace (its V8 sampler costs a few % - the fps measured while recording is a little lower).

## How to read a sent trace (the recipe)

1. Pull it (above). `python3 -I -c 'import json;d=json.load(open("perf-X.json"));print(json.dumps(d["summary"],indent=1))'`.
2. `summary.fps` / `jank` / `worstFrames`: is there a problem, where (ms from the settle point; negative = pre-roll).
3. `home.frames` (full list in `d["home"]["frames"]`), per frame by `verdict`:
   - `js: forced layout` - a layout read after a write in the code of `handlers` / `stacks`. The leaf of the heaviest
     stack is the read (offsetWidth, getBoundingClientRect, getComputedStyle). Fix: read from a ResizeObserver or
     before the writes; never read size in a touchmove (see `shell/dev/page-swipe-check.js` countReads).
   - `js` - the script itself: the `stacks` say which function; `handlers` say which component's handler;
     `components`/`renderMs` say whether rendering was the cost (renderMs near the frame's script = renders; small =
     the handler's own work).
   - `render` - the frame's style/layout/paint step: a big DOM or style change (class toggles on large subtrees, many
     layers). Open the Chrome trace on that frame (Layout / Paint / UpdateLayerTree events, their nodes).
   - `not-js` - the page did little: the main thread waited. Read `summary.native` (MainStallWatch: UI-thread blocks,
     FrameMetrics phase per slow frame) and the Chrome trace's compositor / GPU / raster tracks. Renders are NOT the cause.
4. Only then the render scan: `renders.needlessTop` / `byTime` (`name~` = a prop rebuilt equal: memo with
   `sameContent`, or keep the object stable at its source; `onX` changed = a new inline function each render). These
   are what react-scan's overlay flashes; fix them, but they rarely explain a 100 ms frame.
5. Write the finding with numbers (frame, verdict, function) into the task, fix at the cause, and prove it with a gate
   scene (`perf-trace`, `needless-renders`, `page-swipe-perf`, `drawer-drag-renders` are the models).

## Offenders fixed in this change (gate, `needless-renders`, home 821x883, same five rounds of updates)

| | renders | needless |
|---|---|---|
| before | 406 | 164 |
| after | 242 | 22 (PillSend 10 of them) |

Memo'd (renders only on a content change): `Icon` (44 of 50 needless here; 208 of 212 in perf-1793970543446),
`Send` (PillSend stays: it reads dictation state no prop carries), `LiveBar`, `ThinBar`, `WorkRowLive`, `WorkingNow`, `NeedsAttention`, `RecentlyDone`,
`NeedStack`, `UpNext`, `SevChip` (PowOS AI's status page rebuilds its lists equal each render; `ui/memo.ts sameContent`).
The 11-06 traces' big frames (touchend 72 ms forced 64 ms) were the page swipe's forced layout, fixed by HP4
(2d40ba55, gate `page-swipe-perf`) after those traces; there is no user trace since (newest on the phone: 11-06 14:09).

## Open

- The `not-js` frames (UI thread 35-37 ms per Choreographer frame while swiping, FrameMetrics `delay` 130 ms) need a
  trace with the Chrome trace in it: the next user recording after this ships. Then: which compositor/raster/GPU task.
- The shade's notification `Card`/`Actions` render needlessly (`n~`: the list is rebuilt equal by the host event);
  keep item identity in `notifications.tsx`'s list update, or memo by content.
- PowOS AI's `StatusPage` derives its lists every render; computed signals would remove the rebuild at the source.
