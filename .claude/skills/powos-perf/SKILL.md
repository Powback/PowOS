---
name: powos-perf
description: Use when measuring or fixing PowOS phone performance - idle CPU, frames/paints at rest, nativeglass/blur cost, WebView traces, Linux session processes behind Android's home; the tools, what was found before, and the pitfalls.
---

# PowOS phone performance

Budget (the user, 2026-10-21): ~3% of one core idle on home, screen on; 0 frames, paints and rAF on every page at
rest. Keep the blur - make it cheap.

## Tools (repo tools/phone/)
- `AWAKE_ONLY=1 idle.sh --wait 120 1800`: one call that returns when the screen is on and nobody touched it for 120 s
  (without AWAKE_ONLY it also returns on screen OFF - no use for an idle-home sample).
- `cpu.sh [secs] [top]`: per-process CPU from /proc (% of ONE core; the phone has 8: 800 = all busy). Read-only.
- `cdp.sh pages | eval <page> '<js>' | idle [secs] [page] | raster [secs]`: forwards the app's devtools socket
  (pid changes per install) and runs cdp.ts in powos-vadb's network. `idle`: per page compositor frames, paints,
  rAF, timers, layouts, running animations from one devtools.timeline trace (tracing is browser-wide: one tracer,
  events split by frame/layer tree). `raster`: busiest cc/viz/gpu/blink events per thread. All read-only.
- `idle-sample.sh [secs]`: refuses unless idle>=120 + Awake; cpu.sh + cdp idle + gfxinfo; logs one line to
  ~/.local/state/powos-perf/idle.log.
- Per-thread: /proc/<pid>/task/*/stat (utime+stime, HZ=100). Java hot spots: `simpleperf record -t <tid> -g
  --duration 15` then `simpleperf report --children --sort symbol`.
- `cdp.sh profile [secs] [page]`: V8 CPU profile, self/inclusive ms/s per function and per component (blob modules
  named by sourceURL). `cdp.sh net`: per-page WebSocket frames/requests. `cdp.sh idle` lists "askers" (who requested
  each rAF/timer/restyle, from the .stack trace category). All read-only. Heavy traces (raster) inflate the IO/mojo
  task counts themselves: judge "tasks/s" without tracing.
- Glass knobs (CDP, home): `__glass.live.counts` (measures/sends per s, resets on read), `.kicks` (what started the
  last measures), `.hold(true)` (measure but don't send), `.compute(false)` (drag frames measured, not computed).
- Drawer drag cost on the phone: `shell/dev/perf/drag-raster.sh [secs] ["label=css" | "label=js:ON|OFF"]`, PROFILE=1
  for per-function JS; takes the free window + verify lock itself, or LOCK_HELD=1 under `tools/phone/verify/queue.sh`.
  Don't wait for windows yourself: `tools/phone/verify/queue.sh add <board-task> <script> [args]` and end the turn.
- Finding what changes the DOM: a MutationObserver/rAF wrapper via `cdp.sh eval` - only inside a free idle window.
- Headless: `shell/dev/gate.sh --tree` runs the idle check (2 s after a 3 s settle: no rAF, no layer paint, no
  endless animation). On a busy Mac `READY_MS=30000`. Drawer drag probes: shell/dev/perf/ (powos-drawer skill).
- Deploying rooted-side files over the VPN (rooted.sh calls plain `adb`): `PATH="$PWD/tools/phone/bin:$PATH"
  targets/android/rooted/rooted.sh deploy --note "..."` (tools/phone/bin/adb wraps adb.sh). A restart of the
  supervisor/sleepd afterwards: kill their pids (/data/powos/root/run/...) and `sh /data/powos/powos-start.sh`.
- Phone side: powos-supervisor's daily IdleSample -> /var/log/powos/idle-cpu.log (+ `powos-supervisor status`),
  a low-priority note when over 3%. Screen on = DRM `/sys/class/drm/card*-DSI-*/dpms` On (backlight files read 0).

## Found (2026-10-21)
- Endless CSS pulses (PowOS AI's working dots) = 60 frames/s and a SurfaceFlinger blur pass each: static dots now.
- nativeglass measured on any style write anywhere (widgets' numbers, the pet's transform): now only on what
  carries glass (a surface or its ancestors), plus ResizeObserver on surfaces; `__glass.live.counts` for sends/s.
- A widget whose value changes re-renders its tile: performance widget 2 s -> 5 s (budget: <= 1 update / 5 s).
- The warm assist WebView in a hidden session window counted itself visible: WebView.onPause in onHide.
- The app ran interpreted after every install (no profile, dexopt status=verify): install-app.sh installs
  with pm.dexopt.install=speed (HACK until a baseline profile).
- plasmashell behind Android's home: powos-panel-responsive polled it with evaluateScript every 3 s (now RandR
  events); plasmashell itself is frozen 15 s after PowOS goes off screen (powos-sleep-gui -> sleepd
  gui-desktop-freeze), thawed on screen, on D-Bus (the log names the caller), and 2 s every 5 min.
- powos-supervisor: full /proc scan every 10 s was its whole cost; now every 60 s.
- WireGuard CPU is traffic: the phone's own `claude` uploads to claude-auth (tens of MB), agents' adb calls; not
  keepalive.

- Every touch on home ran the full glass measure per frame (58/s in use): touches now measure only during a drawer
  drag (tracks or .home.dragging). Drawer drags are computed from gesture.ts's "drawer" Web Animations' keyframes
  (one measure at the start), and innerWidth/innerHeight/devicePixelRatio are read on resize only (each read forced
  a style recalc mid-frame). Drag cost left: ~38 ms/s nativeglass (1/3 is the per-frame postMessage of regions) and
  the WebView's own drawing; holding region sends changed nothing measurable - no host-side fade needed.
- Baselines (2026-10-22): idle home app 4.3 + renderer 1.1-2.0 % of a core; drawer drag app ~105 / renderer ~97 /
  SF ~62 (total ~356). Re-measure on kernel changes.

## Delivery pipeline (Mac)
- APK: build-app.sh uses the warm builder (targets/android/tools/warm-builder.sh, container powos-gradle-warm, unit
  gradle-warm-mac): every worktree rsync'd into /work, Gradle daemon warm - 11-12 s end to end; falls back to the cold
  android-app-dev `make build` (~2-8 min; POWOS_COLD_BUILD=1). `PUBLISH=0 warm-builder.sh build <app dir>` = timing
  without touching output/. No BuildConfig in the app (a per-build versionCode in it recompiled javac every build):
  the stamp goes to the manifest via androidComponents; read the version at runtime (AppVersion.kt).
  targets/android/tools/profile-build.sh: Gradle --profile cold vs no-change inside the ship lock.
- Gate: pages share one transpile (gate.mjs, cached by hash in ~/.cache/powos-gate/tx; GATE_SHARED_TX=0 = old way).
- Mac load is mostly not ours (stickman train.py, the kernel builder's Rosetta clang LTO): leave the user's jobs.

## Pitfalls
- touch IRQs don't see injected input: also check Android's lastUserActivity (`dumpsys power`).
- A 2 s `top` catches periodic ticks and overstates them; sample 30-60 s.
- My own probes show up (a stuck `tr` loop hit 100%): kill them, keep phone-side loops bounded.
- An idle sample while another agent installs an APK or a page is broken is not a sample.
- A bash -c '...' script must not contain an apostrophe (even in a comment); `set -o pipefail` + `sed ... missing-file
  | head` exits non-zero - guard with `|| true`.
- `docker run --rm` per call costs ~1 s; prefer a long-lived container + `docker exec` for repeated work.
- Ship only pushed commits (ship-apk enforces it); commit, rebase, push, then ship.
- Cross-cutting causes (endless animations, nativeglass MutationObserver, inherited custom properties): handbook
  "Rendering cost". Each new one found goes there, not only here.
