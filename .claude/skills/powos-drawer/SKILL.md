---
name: powos-drawer
description: Load before changing or debugging the PowOS app drawer / launcher panel (shell/ui/drawer.tsx, gesture.ts drag, shell.css .launcher/.dock/.bar, the fade, recents row, A-Z bar, search pill spacing) or measuring its drag/scroll performance.
---

## Architecture (2026-10-21)
- Markup (home.tsx, same in pull.tsx): `.stage > .launcher[data-p] > (.launcher-frame.tile, .launcher-inner >
  .drawer-clip > Drawer | .ai-panel)`; `.home > .bar[data-p]` and `.home > .dock[data-p]` follow it too.
- Laid out ONCE at the open size: `.launcher` spans the stage top to the screen foot (bottom: -(48px + strip + foot);
  no bar: -(strip + foot); pull page: -(48px + foot)); `.launcher-inner` padding-bottom keeps the drawer above the pill.
  Nothing changes size during a drag: the dock slides down + fades (opacity 1 - min(1, 3p)), the bar slides down by
  --strip-height (not in pill-below or the pull page), home-content fades/scales.
- `--p` (0..1) is a registered, NON-inherited property; `--fade` too. Readers below a [data-p] element must inherit it
  by name (only `.cc-media::after` does). The launcher: translateY((1-p)*100%), opacity 1-(1-min(1,p/0.8))^3 (one
  ease-out for frost and content: 95% at half-way, whole by 80%).
- Drag (gesture.ts): `follow(p)` gives each [data-p] element one paused WAAPI animation (id "drawer") whose keyframes
  are its own computed transform/opacity at 41 values of --p (`tableOf`, cached per size/pill-below); the finger sets
  currentTime. Release: `settle(p, to)` re-times the table along cubic-bezier(0.1,0.8,0.2,1) over 180 ms, --p set to
  `to` underneath, animation cancelled at the end. Settle waits a microtask (drawerDrag=null and drawer= are two
  writes). Without a finger (tap/Back/launch) --p's CSS transition (180 ms) does it.
- Finger mapping: p = dy * GAIN(1.5) / launcher height. Open on flick >= 0.2 px/ms or p > 0.15; close keeps open
  above 0.67. Pull over apps: Kotlin sends pull.drag p (pull.tsx), same follow/settle path.
- Drawer: A-Z `.grid.az` in `.drawer-list` (padding-right = --letter-bar, so names clear the letters); RecentRow
  (`.drawer-recents`, one grid row, extra rows height 0) fixed under the list by the pill; LetterBar "#" = the recent
  row (no scroll). Pill: `.bar-pill` bottom = `--pill-foot` (theme.css), same token as PowOS AI's `.ai-compose`.
- Native blur: nativeglass.ts sends regions ("b.r") for `.tile`s; the frame is the panel's region (others inside
  .launcher skipped); region alpha = product of ancestor opacities. Host (GlassBlur.kt) has static regions + alpha
  only - no transform, no alpha animation - so a moving/fading frost is re-sent per frame.

## Pitfalls hit
- Inherited --p restyled every app cell and widget per frame (3.3 ms headless). Unregistered intermediates
  (`--fade: calc(...var(--p))`) inherit too - register them `inherits: false`.
- `:is()` can't hold pseudo-elements: `.cc-media::after` needs its own selector.
- Two rules setting `transition` on one element ([data-p] vs [data-q]) - the later wins, the other jumps.
- Layout-affecting --p readers (dock height, frame top/bottom, clip-path) - each frame relaid the stage. Keep to
  transform/opacity.
- A component reading `drawerDrag.value` in render re-renders per frame (pull.tsx did, with all of Drawer) - use a
  computed boolean.
- "Start half-way up" was tried and reverted by the user: full travel from the bottom, faster (GAIN), front-loaded fade.
- Frost at full alpha from frame 1 "popped": frost and content must share one fade.
- A stale shell.css from another tree once clobbered the drawer on the phone (one column; first blamed on the recents
  strip): push.sh now refuses files that aren't origin's (handbook Shipping). shell.css and gesture.ts are shared with
  design/switcher/widgets/gestures: rebase right before you push them, then verify on the device.
- Agents' CDP checks that set --p in the LIVE home opened the drawer on the user's screen: live CDP is read-only.
- The gate times out ("not ready") when the Mac is loaded: READY_MS=30000.

## Test / measure
- Renders: `READY_MS=30000 SHOTS_ONLY='^(drawer|home|pull-apps|pull-ai|ai|search-typing)$' shell/dev/gate.sh --tree
  --shots DIR`; mid-drag: SHOTS_PROBE that sets `(await importShim("./ui/gesture.ts")).drawerDrag.value = 0.35`.
- Headless perf/behaviour: `shell/dev/perf/run.sh <probe.js> [shell-dir] [scene]` - shots.mjs patched on the fly
  to print Chromium's metrics (LayoutCount, RecalcStyleCount, durations) around the probe, both screens. For a
  before/after, extract the old shell (`git archive <rev> shell | tar -x -C DIR`) and pass DIR/shell; run them back
  to back (the Mac's load skews timings, not counts). Probes in shell/dev/perf/: slow.js (60-frame slow drag),
  drag.js (per-frame forced style/layout), open.js (flick -> settled ms, from the drawn transform), scroll.js (blur
  region sets / mutations per drawer-scroll frame), check.js (open and close settle to rest, 0 animations left).
  Bisect a cost by injecting CSS or removing data-p at the top of a probe.
- Device (screen on, home visible, user idle - one `tools/phone/idle.sh --wait 120 1800` first):
  `shell/dev/perf/device.sh [slow2s.js]` - metrics 3 s at rest, then a 2 s slow drag + close (frames, dropped,
  worst, Chromium metrics; devperf.ts in powos-vadb). Read-only checks any time: `tools/phone/cdp.sh eval "" '<js>'`
  reading computed opacity/transform, `cdp.sh idle 3 ""`. Setting --p on [data-p] (transition none) to read values at
  a given p ONLY inside that free window and restored in the same call - it shows on the user's screen.
- Baselines: headless 60-frame slow drag, style recalc 260 ms -> 64 (layout 64 -> 0) -> 37 ms (WAAPI). No device
  drag numbers yet.
