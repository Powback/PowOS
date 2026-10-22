---
name: powos-widgets
description: Use when making, fixing, reviewing or shipping a PowOS home widget - OWL (.owl) widgets, PowOS app widgets (islands, e.g. Lights), shell panels - or the widget preview tool, its fit checks and mock data, or a widget control fighting home's page swipe.
---

Three kinds of widget, one home grid (docs/AGENT-HANDBOOK.md, Widgets):
- Shell panels (shell/ui, ids panel.*), OWL widgets (.owl: evaluated by the Kotlin engine, drawn by shell/ui/owl.tsx
  from the trees it sends), PowOS app islands (an app's ui/widgets/*.tsx, props { host, app, cells }).

## The preview: see every widget at every size before shipping
    shell/dev/preview.sh [--only REGEX] [--app DIR]... [--owl FILE|DIR]... [--no-defaults] [--live] [--out D]
                         [--wallpaper F] [--themes "gruvbox nord"] [--fast]
    powos app preview <app dir | file.owl | widget id>     # wrapper (lib/apps/powos-app cmd_preview)
- Every size from the manifest's minSize to 4x4, cover screen and inner screen, two themes: one contact sheet per
  widget (DIR/<id>.png, default ~/.cache/powos-preview/out) + report.json. Exit 1 on a NEW problem; the known ones are
  in shell/dev/preview/baseline.json (PREVIEW_BASELINE=0 fails them too). The gate runs it with --fast.
- Checks (sheet.tsx check(EMPTY=0.12, COVER=0.25)): clipped text, a row cut in half, a side >12% empty, content <25%
  of the tile (calibrated on the manager's review), a tile that scrolls (allowed: a pan-x strip, a pan-y list in
  whole rows with y snap), a slider inside a sideways scroller, a sideways drag (touch-action none/pan-y) without
  role=slider / data-owns-gesture, a hard border (no lines: design language), and a widget's screen() on both screens.
- Mock data: shell/dev/preview/data/<widget id>.json - an OWL widget's sources by name ({"seq": [...]} feeds several
  updates so history() fills), an app's {rows, net}. Add one for every new widget.
- OWL runs off the phone via `owl trees` (targets/android/app/owl CLI, Trees.kt: a port of WidgetTree.kt - keep in
  step); owl.jar builds in android-app-dev-android-builder (`./gradlew -q --offline --configure-on-demand
  :owl:owlJar`, volume powos-android-gradle; locked while an APK builds, the old jar is used). `java -jar owl.jar check f.owl`.
- The nerd-font mount: shell/fonts/nerd_symbols.ttf is a symlink out of shell/ into targets/android/.../res/font;
  preview.sh mounts that folder at the same path in the Chromium container, else OWL icons render as empty boxes
  the checks can't see. Keep that mount if you touch browser().
- Look at the PNG yourself (sips -Z 1600 to view) before calling anything done.

## Making a widget fill its tile (the template: lib/apps/templates/widget/ui/widgets/main.tsx)
- The box is a size container; type in em of a font that follows the tile: fontSize clamp(13px, 6cqmin, 22px).
- The list takes the height left (flex 1, minHeight 0); rows share it (flex 1 0 2em, max 3.2em); more rows scroll
  up/down in whole rows (overflowY auto, scroll-snap y mandatory, touch-action pan-y). Never guess rows from cells:
  measure the real area (ResizeObserver) if you must compute.
- No lines: fields and chips are a soft fill (color-mix currentColor 8%). Never a sideways strip of controls.
- Cards that share the height (the Agents panel, shell/ui/agents.tsx): measure only the container (ResizeObserver),
  then fit each card's lines IN RENDER from that box - the font is monospace, so wrapping is counting (wrapped(),
  fitLines()). Measuring inside each card in a layout effect went stale when a signal changed its text (the cut
  "coder" card). Soft-filled cards count as ink for the coverage check; an empty state is one card, not blank glass.
  Variants with other mock data: preview.mjs widgets with `agents: [...]` (panel.agents-idle / -empty).
- OWL layout is Compose's: an unsized Text/Grid/Canvas/chart or a Row of weights takes the column's width; a Row's
  fixed-width items don't spread without `fill: width`; size text from tileWidth/tileHeight, never a fixed cap.

## Gesture ownership (shell/ui/gesture.ts homeGestures)
Home's page swipe, drawer and shade are TOUCH events on .home: a control's pointerdown stopPropagation does NOT stop
them. A drag that starts on `.letter-bar, input[type=range], [role=slider], [data-owns-gesture], ...` (the `own`
selector) is left alone. So: any widget slider/drag control is role=slider (with aria-valuenow) or carries
data-owns-gesture, plus touch-action pan-y on it. The native edge handles (EdgeGestures.kt) are a thin right-edge
strip only - not the cause when a drag in a tile fails.

## Lights (local.lights, phone: /home/powos/Projects/lights; Hue via host.net, key = app secret "hue")
- Widget: rooms as pills (Pill: role=slider; tap = toggle, sideways drag = dim, onDim sent at most every 300 ms and
  on release -> setGroup -> PUT clip/v2/resource/grouped_light/<id>). Columns from the width (~110 px a pill), whole
  rows; one room = a full-tile panel, radius min(pillH/2, 18). The page's first card "On the home widget" picks which
  rooms the widget shows (opt-in prefs).
- Work on any phone app (repo scripts only - ~/.cache scratch is pruned after 3 days, so a pulled copy is
  disposable; pull again rather than trusting an old one):
      tools/phone/app-src.sh pull lights [DIR]          # sources -> DIR (default ~/.cache/powos-apps/lights)
      shell/dev/preview/build-app-ui.sh DIR             # widgets + pages -> DIR/out/ui (docker esbuild, no module)
      shell/dev/preview.sh --no-defaults --app DIR --only '^local\.lights'
      tools/phone/app-src.sh push lights DIR --note "what changed" ui/widgets/main.tsx [more files]
  push keeps each file's owner, runs `powos app ui .` as the user, prints local vs phone md5, and refuses a file
  the phone changed since the pull. The repo's own apps (apps/*) build with apps/build.sh, install with apps/install.sh.
- NEVER drag a real room to test. Test with a mock room in the preview (data/local.lights.json) or CDP with the
  reducer/onDim stubbed. A test once left the user's real room light changed. Setting a
  value back (only with the user's say): call the pill's own handlers (element.l.pointerdownfalse / pointermovefalse /
  pointerupfalse with a fake event) - no input reaches the screen, but the light does change.

## Phone pitfalls
- adb push DIR into an existing DIR nests it (dir/dir): rm -rf the target first, or push to /data/local/tmp/<new>.
  Then su cp + chown (u0_a359 for app files) + `restorecon -F`, and md5sum against the source.
- .owl files on the phone: files/widgets/*.owl (= ~/.config/omalauncher/widgets), hot-reloaded.
- Shell files: shell/push.sh --vpn --note "..." ui/x.ts refuses anything not origin's version; the phone's
  overrides are in /data/data/com.powos.app/files/shell - diff them against origin before pushing.
- After a Colima restart powos-vadb may be stopped: `docker start powos-vadb`, then tools/phone/adb.sh connect
  10.13.13.7:5555.
- CDP: tools/phone/cdp.sh eval "" '<js>' (home); read-only probes (sizes, aria-valuenow, .page-track transform).
  Dynamic import of shell modules from eval fails; use the DOM. Check tools/phone/idle.sh before any synthetic
  input (idle>=120, Awake); idle.sh --wait instead of loops.

## Islands: network failures, retry, the detail sheet (2026-10-22)
- host.net.error(e, status) -> NetError {kind offline|timeout|auth|other, message (calm), detail (raw, log only)};
  host.net.fetch already throws NetError. Never put e.message on a tile (raw IPs wrapped and cut). Old PowOS apps lack
  it: islands keep a local fallback (Lights hue.ts failOf, marked HACK).
- host.net.useRetry(load, failing): backoff 5 s -> 5 min, at once on online / connection change / page shown; returns
  retry() for a tap. Shared CSS: .island-offline (one muted line, wraps between words, never clips), .alone (fills the
  tile, the app icon in .island-offline-icon greyed above), .island-stale (last state greyed; cache it in localStorage).
- A hidden home releases the island's stdb connection (stdb.ts useVisible): never gate an island's whole UI on
  db status - Lights showed "Lights …" forever. Gate only what needs the db (pairing).
- host.DetailSheet (apps/sheet.ts, drawn by ui/widgetsheet.tsx, mounted in home.tsx and the preview): render it in the
  island with children; it portals them into a .tile.sheet.pop popover anchored to the element, live with the
  island's state. Tap outside / swipe down / Back -> onClose (unmount it). Height capped between status bar and
  home's foot (.bar-pill/.dock), opens upward when low, body scrolls. Long-press: hold 450 ms in the control's own
  pointerdown (it stopPropagation()s, so home's edit mode never starts), then the release does nothing; wrap
  setPointerCapture in try (synthetic pointers throw). Coloured ranges: Range track + data-track (shell.css thumb).
- Lights popup = every room (pill + switch), tap a room for temp/colour/scenes/lights (ui/lib/detail.tsx RoomDetail).

## Preview variants and checks added
- Island variants: data/<app>~<variant>.json (preview.mjs); data may carry net[].error (fetch rejects like the native
  layer), storage {} (localStorage seed; each page gets an in-memory localStorage), press + pressCell (a held press,
  then pointercancel - never a tap; the opened sheet is checked: on screen, last row visible or scrollable).
  Existing: local.lights~offline, ~offline-stale, ~detail (12 rooms). OWL variants: <id>~extreme.json (-13°, 100%).
- Fill checks skip .island-offline.alone and .ag-idle-line (sparse by request); clipping still applies.
- Monospace sizing: budget 0.62 em/char (phone font ~0.575, preview 0.5), line height 1.4.

## Home grid: merges, relayout
- grid.tsx joins: a side covered WHOLE by neighbours extends half a gutter (--jX 1); a partially touched side stays at
  its normal inset; seams() adds .tile.seam pieces - a bridge filling the gutter along the shared span and a fillet
  (mask-cut quarter circle) at the inner corner, skipped where a third face sits. Seams are in faces() paths (page
  glass, group shadow) and tint like faces (.page .seam). Gate: joins-folded/-unfolded (steam 6x3 over fetch 3x3);
  shots.mjs "partial join" = not merged / off its row line / seam over a face.
- Relayout: measure() never runs while document.hidden and compares cellW (column count) too; Pages useMeasured and
  hosts/wide.ts recheck on visibilitychange (+2 frames, +400 ms), pageshow, orientationchange, resize, ResizeObserver.
  Gate: relayout-landscape/-fold/-unfold. The mock can't reproduce the phone's stuck-wide state: verify on the device.
- Gate cases go in dev/gate.mjs as small top-level helpers (whenReady, relayout...) - the complexity lint (60 lines,
  cognitive 10) covers dev/*.mjs too; prune baselines (dev/lint-complexity.sh --prune, targets/android/lint-complexity.sh --prune).

## Tools
- shot.sh mounts the icon font and passes SHOTS_STRICT; idle.sh --wait re-holds a dropped adb connection;
  app-src.sh push records the phone's md5s (a second push of the same file works). Device checks: queue them
  (tools/phone/verify/queue.sh add <task> <script>) and end the turn. Screencap ids: cover 4630946316123810436,
  inner 4630946704981769859 (a black frame = that display is off).
