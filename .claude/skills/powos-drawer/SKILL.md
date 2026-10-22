---
name: powos-drawer
description: Load before changing or debugging the PowOS app drawer / launcher panel (shell/ui/drawer.tsx, gesture.ts drag, shell.css .launcher/.dock/.bar, the fade, recents row, A-Z bar, search pill, dock's recent apps, themed app icons, the running bar under icons) or measuring its drag/scroll performance.
---

## Architecture (2026-10-22)
- Markup (home.tsx; pull.tsx the same): `.stage > .launcher-frame.tile[data-p]` (the frost, a sibling, to the screen
  foot) + `.launcher-clip[data-p] > .launcher[data-p] > .launcher-inner > .drawer-clip > Drawer | .ai-panel`;
  `.home > .bar[data-p]`, `.home > .dock[data-p]`, `.home-content[data-p]` follow too. desktop.tsx keeps the frost
  inside .launcher and its own desktop.css: don't touch it.
- Laid out ONCE at the open size; a drag changes only transforms/opacity. `--rise: 15vh` (registered <length>, on
  .home) is THE knob for where the open starts (user: 30vh, then "further up"; "start half-way" + full travel both
  tried and replaced). Frost + launcher: translateY((1-p)*--rise), opacity 1-(1-min(1,p/0.8))^3.
- `.launcher-clip` is the drawer's window, cut at the search pill's top (bottom: 4px - strip) with a 12px mask fade;
  it rides with the pill as the bar slides (clip translateY((p-1)*strip), launcher in it (1-p)*(rise+strip)) so no app
  row is ever under the pill. `.launcher-clip .launcher-inner` padding-bottom 16px = last row 16px clear of the pill.
  pill-below / pull / no-bar: static window. Check: `cdp.sh eval home "$(cat shell/dev/perf/geometry.js)"` (read-only).
- Dock slides down + fades (1 - min(1,3p)); bar slides by --strip-height (not pill-below/pull).
- `--p`, `--fade` registered NON-inherited; `.cc-media::after { --p: inherit }` is the only by-name reader.
- Drag (gesture.ts): module functions startGesture/moveGesture/endGesture (claim by place, `dragTo` switch, one settle
  per kind - under the complexity lint). `follow(p)`: each [data-p] element one paused WAAPI animation (id "drawer",
  keyframes = its computed transform/opacity at 41 --p values, `tableOf` cached); finger sets currentTime. `settle`
  re-times along cubic-bezier(0.1,0.8,0.2,1) 180 ms, then --p shows through. Settle waits a microtask (two writes).
  Tap/Back/launch: --p's CSS transition.
- Finger: p = dy*GAIN(1.5)/--rise px (gesture reads --rise). Open: flick >= 0.2 px/ms or p > 0.15. Close keeps it open
  above CLOSE_KEEP 0.5 (~45 px of finger). Pull over apps: Kotlin pull.drag p, same path.
- Drawer: A-Z `.grid.az` in `.drawer-list` (padding-right --letter-bar). RecentRow (`.drawer-recents`) is OFF by
  default: `drawerRecents = stored("drawer.recents")`, "on" shows it; Settings > style > home > "recent apps in the
  drawer". The check is inside RecentRow (Drawer itself is at the cyclomatic limit).
- Pill: empty height = `--pill-height` 40px (theme.css; on screen 44 with borders), grows only with typed lines up to 3
  (grow.tsx: empty = one row at any width, re-measured on width change - a narrow-measured empty pill stuck at 3 rows,
  2026-10-22). `.bar-pill` bottom = `--pill-foot` 6px, same as `.ai-compose`. The gate's "pill" run asserts it (foot,
  compose, search widget 6x1/6x2/2x1, after narrow->wide). Widths: wide home's cap is the desktop agent's.
- Dock's recent apps (home.tsx Dock 2nd page `.dock-page.dock-recent`): `.dock .dock-recent .app` flex 0 0
  calc((100cqw - 28px)/6), `.dock-pages` container-type inline-size. NOT 100vw: WebView's vw was 688 on the 404 cover.
  Check: shell/dev/perf/dock-scroll.sh (one free window: swipe, scrollLeft, widths, screencap).

## Themed icons (board theme-recolor-icons)
- Slice 1 (8f5c995): ui/icontint.ts. `iconTint = stored("icons.tint")`: "" (apps' own) | "mono". Settings > style >
  icons > "icon colours". AppIcon uses `tinted(src) ?? src`. Each icon redrawn ONCE in idle time on a canvas (<=192px):
  per pixel HSL(accent hue, sat clamp 0.35-0.8, L 0.12+0.76*luminance), blob object URL, cached per mode|accent|src,
  cleared on theme/mode change; `ready` signal bumps per batch of 8. Icons are same-origin (shell.powos/_icon/...),
  canvas-readable. Near-black icons stay near-black (luminance kept). Style lint: no `hsl(` identifiers.
- Slice 2 (ca8c99e): mode "hue" ("theme hues"; Segmented ["the apps'", "theme hues", "accent"] = "", hue, mono via
  screens.tsx TINTS). Palette = --color-accent, --color-red, --term-color1..6 (app.tsx sets term colours from the
  theme; only accent+red are --color-*). Palette hues with sat <= 0.15 dropped; 360-entry nearest-hue table; pixels
  with sat < 0.08 (greys) untouched; own s/l kept. Cache/clear key = mode|whole palette string.
- Next: per-theme default (a theme can ask for mono/hue: theme field -> iconTint default when unset).
- Check headless: SHOTS_PROBE `(async()=>{(await importShim("./ui/icontint.ts")).iconTint.value="hue"; await new
  Promise(r=>setTimeout(r,3000)); return document.querySelectorAll('img[src^="blob:"]').length})()` (42 in the
  mock), shots dir under $HOME and chmod 777 (Colima docker writes it; /tmp gave EACCES). Device:
  tools/phone/verify/icon-hues.sh (pushes if the phone serves the old module, then read-only probe + screencap).

## Running bar (board running-indicator)
- AppCell (dock, dock recents, drawer, drawer recents, recent widget) sets `data-run` from ui/running.ts (`running`
  signal: app key -> "running" | "frozen", `powos.apps.running?.()` once + "apps.running" events, re-asked on
  apps.changed). shell.css: `.app[data-run] .app-icon::after` 10x3 accent bar under the icon, a 1px ring of
  --color-background (the accent's own ground; the style lint allows `0 0 0 Npx var(--color-*)` rings, not new tokens; --on-wallpaper-halo failed light themes at 1.3:1); frozen 0.4.
  Floating windows (`.dock .app.windowed`) share the bar (the old foreground dot is gone). Home grid icons: none.
- Sources (no polling): RunningApps.kt (system/): FreeformTasks.listen -> Tasks.list packages (own package left out);
  FileObserver on files/run/running/apps.json = powos-sleep-gui's `publish_running` ({"classes": {cls: state}},
  written on change from report/freeze/thaw/reset). ShellBridge `running()` maps: "a:<key>" by package, "l:<id>" by
  LinuxApp.matches or steam_app_<appid> -> an entry whose Exec has rungameid/<appid>.
- Checks: gate scenes running-dock / running-drawer (mock: chrome, konsole, spotify, signal running; dolphin, steam
  frozen). Contrast bar vs its ring >= 5.9:1 (gruvbox, flexoki-light). Device: tools/phone/verify/running-dot.sh.
  sleep-gui on the phone: /data/powos/root/usr/lib/powos/apps/powos-sleep-gui (a session restart picks it up).

## Pitfalls hit
- Inherited --p (and unregistered intermediates like --fade) restyled every cell per frame: register inherits:false.
- `:is()` can't hold pseudo-elements. Two rules setting `transition` on one element: the later wins.
- Layout-affecting --p readers (dock height, frame top/bottom, clip-path) relaid the stage per frame.
- A render reading `drawerDrag.value` re-renders per frame: use a computed boolean. A `useEffect` deps array reading
  `drawerOpen.value` subscribes the component: Pages re-rendered every page's glass on each open/close (removed).
- Frost at full alpha from frame 1 "popped": frost and content share one fade.
- Same-specificity later rules win silently (`.dock .app { flex: 1 }` beat the recents width): read computed styles.
- Stale shell.css from another tree clobbered the drawer once: push.sh refuses non-origin files. Rebase right before.
- Live CDP is read-only; temporary UI (edit mode, open drawer, menus) may be closed with Back in a free window
  (drag-raster.sh does it). A check that sets anything must restore in a trap/finally.
- A `&&` chain after the gate doesn't stop on gate FAIL (grep exits 0): gate, look, THEN commit/push.
- The Mac loaded (~24): pages boot in ~45 s - gate with READY_MS=90000 (push.sh's retry honours it).

## Test / measure
- Renders: `READY_MS=90000 SHOTS_ONLY='^(drawer|home|pull-apps|search-typing)$' shell/dev/gate.sh --tree --shots DIR`;
  mid-drag: SHOTS_PROBE setting `(await importShim("./ui/gesture.ts")).drawerDrag.value = 0.45`.
- Headless: `shell/dev/perf/run.sh <probe> [shell-dir]` (Chromium metrics + layer paints). Probes: slow.js, drag.js,
  open.js, scroll.js, check.js (open/close settle), pages.js (page swipe), geometry.js. Before/after: `git archive
  <rev> shell | tar -x -C DIR`, pass DIR/shell, run back to back.
- Device: `PROFILE=1 shell/dev/perf/drag-raster.sh 12` (verify lock, one free window, Back-reset) - JS ms/s per
  function; TRACE=1 paints by page/node. device.sh + slow2s.js, dock-scroll.sh, geometry.js.
- Drag cost found: drawer itself ~2 ms/s script, 0 paints. Others: pet (now off by default) repainted the document
  ~65/s; a down swipe made the hidden shade repaint ~73/s; nativeglass measure ~30-107 ms/s. Device profile with the
  15vh mask: app 57 / renderer 74 / SF 26 (% of a core; was 105/97/62, pet still on then). Headless 60-frame slow
  drag style recalc 260 -> 37 ms, layout 64 -> 0.
