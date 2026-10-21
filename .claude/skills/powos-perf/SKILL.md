---
name: powos-perf
description: Use when measuring or fixing PowOS phone performance - idle CPU, frames/paints at rest, nativeglass/blur cost, WebView traces, Linux session processes behind Android's home; the tools, what was found before, and the pitfalls.
---

# PowOS phone performance

Budget (the user, 2026-10-21): ~3% of one core idle on home, screen on; 0 frames, paints and rAF on every page at
rest. Keep the blur - make it cheap.

## Tools (repo tools/phone/)
- `idle.sh --wait 120 1800`: one call that returns when the phone is free. It also returns on screen OFF - for an
  idle-home sample you need `screen=Awake` and `idle>=120` (check again after it returns).
- `cpu.sh [secs] [top]`: per-process CPU from /proc (% of ONE core; the phone has 8: 800 = all busy). Read-only.
- `cdp.sh pages | eval <page> '<js>' | idle [secs] [page] | raster [secs]`: forwards the app's devtools socket
  (pid changes per install) and runs cdp.ts in powos-vadb's network. `idle`: per page compositor frames, paints,
  rAF, timers, layouts, running animations from one devtools.timeline trace (tracing is browser-wide: one tracer,
  events split by frame/layer tree). `raster`: busiest cc/viz/gpu/blink events per thread. All read-only.
- `idle-sample.sh [secs]`: refuses unless idle>=120 + Awake; cpu.sh + cdp idle + gfxinfo; logs one line to
  ~/.cache/powos-perf/idle.log.
- Per-thread: /proc/<pid>/task/*/stat (utime+stime, HZ=100). Java hot spots: `simpleperf record -t <tid> -g
  --duration 15` then `simpleperf report --children --sort symbol`.
- Finding what changes the DOM: a MutationObserver/rAF wrapper via `cdp.sh eval` - only inside a free idle window.
- Headless: `shell/dev/gate.sh --tree` runs the idle check (2 s after a 3 s settle: no rAF, no layer paint, no
  endless animation). On a busy Mac pages may need `READY_MS=20000`.
- Phone side: powos-supervisor's daily IdleSample -> /var/log/powos/idle-cpu.log (+ `powos-supervisor status`),
  a low-priority note when over 3%. Screen on = DRM `/sys/class/drm/card*-DSI-*/dpms` On (backlight files read 0).

## Found (2026-10-21)
- Endless CSS pulses (PowOS AI's working dots) = 60 frames/s and a SurfaceFlinger blur pass each: static dots now.
- nativeglass measured on any style write anywhere (widgets' numbers, the pet's transform): now only on what
  carries glass (a surface or its ancestors), plus ResizeObserver on surfaces; `__glass.live.counts` for sends/s.
- A widget whose value changes re-renders its tile: performance widget 2 s -> 5 s (budget: <= 1 update / 5 s).
- The warm assist WebView in a hidden session window counted itself visible: WebView.onPause in onHide.
- The app ran uninterpreted-JIT after every install (no profile, dexopt status=verify): install-app.sh installs
  with pm.dexopt.install=speed (HACK until a baseline profile).
- plasmashell behind Android's home: powos-panel-responsive polled it with evaluateScript every 3 s (now RandR
  events); plasmashell itself is frozen 15 s after PowOS goes off screen (powos-sleep-gui -> sleepd
  gui-desktop-freeze), thawed on screen, on D-Bus (the log names the caller), and 2 s every 5 min.
- powos-supervisor: full /proc scan every 10 s was its whole cost; now every 60 s.
- WireGuard CPU is traffic: the phone's own `claude` uploads to claude-auth (tens of MB), agents' adb calls; not
  keepalive.

## Pitfalls
- touch IRQs don't see injected input: also check Android's lastUserActivity (`dumpsys power`).
- A 2 s `top` catches periodic ticks and overstates them; sample 30-60 s.
- My own probes show up (a stuck `tr` loop hit 100%): kill them, keep phone-side loops bounded.
- An idle sample while another agent installs an APK or a page is broken is not a sample.
- Ship only pushed commits (ship-apk enforces it); commit, rebase, push, then ship.
