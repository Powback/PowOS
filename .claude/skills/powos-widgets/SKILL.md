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

## OWL Canvas and Image on the phone (2026-10-22, the fetch logo)
- A Canvas's box comes from its node (size/fill/weight/the Box around it), never from its bitmap: owl.tsx gives the
  canvas `contain: size`. paint() sets the bitmap to box x devicePixelRatio, so a box sized by its own bitmap grows by
  dpr at every ResizeObserver tick - invisible at dpr 1 (preview, gate), a 28 px bar down the tile drawn white on the
  phone (dpr 2.76) after a restart. Bitmaps are capped at 4096 px a side; no 2D context = canvas hidden.
- An Image that fails (/_wimg route or file gone) is hidden in its box (onError visibility hidden): layout kept,
  never the WebView's broken-image box. Preview check: "a broken image shows"; variant data/97-now-playing~broken-art.
  Also checked: "a canvas WxH past its tile".
- Shared screenshots the user sent PowOS AI: /data/data/com.powos.app/files/run/powos-ai-shared/screen-<ms>.jpg -
  the first thing to read for a reported visual bug (the 22:36 one showed the cover screen, not the inner one).

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
- Shell files: push to origin, then `tools/phone/ship.sh request --note "..."` (handbook Shipping); the phone's
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
  shots.mjs "partial join" = not merged / off its row line / seam over a face (a side counts as covered whole when
  its neighbours together cover it). Scene home-merged = the user's unfolded layout as a mock (only kind widget /
  known panels draw a face: an unknown panel name has none, its "group" is shadow only).
- Native glass (nativeglass.ts): a bridge's region overlaps both faces along its long sides; a fillet gets no region
  (rounded boxes only: a region blurred the whole square, an untinted corner).
- Wide home (hosts/wide.ts, unfolded >= 700 px): ONE page of 13 columns per pair of host pages (the user's [1, 3] = one
  page); tiles go anywhere on it. The host keeps only the folded layout; wide cells live in the store "home.wide"
  (key -> cell + hp, the host page then; hp changed folded = placed again). No wide cell: the side-by-side spot
  (x + 7 on the right), else the first free one. Moved/resized wide = store only (folded never moves); onto another
  wide page = the host moves it too. First wide run backs the host layout up to "home.wide.backup". Gate: wide-home.
- Edit mode: the foot's pill is a grid tile (searchwidget.tsx footSearch, key panel:search, lowest free row: whole
  row folded, middle 5 columns wide); placeItem() turns a move/resize of it into addPanel("search"). The dock stays;
  the edit sheet takes the pill's slot (wide: the bar's middle). Gate: edit-search-folded/-unfolded.
- Search widget on the grid (2026-10-23, P0): the foot's <Bar/> is ALWAYS rendered - the drawer's search. With
  panel:search on home it's parked (.home.search-parked: order after the dock, margin-top -48px = no room, opacity
  min(1, 3p), clip ends 52px-strip above the stage foot); the tile is <Bar proxy/> (readonly, tap = open + focus the
  foot's textarea). Without this the pulled-up launcher had no search at all (the 4th report). Never "remove": the
  tile's "put back in bar", "+ widget" > search bar, or a drop on the edit sheet (kept while the search is carried)
  = putBackInBar(); a drop on the dock row folded = back in the foot under the dock (footBelow "1"). gesture.ts
  tableOf keys on search-parked too. Gate: search-launcher-folded/-unfolded.
- "+ app" (editsheet.tsx AppPicker): drawer.tsx AppList (the drawer's A-Z list/results + letter bar, onTap instead of
  launch) + bar.tsx Pill with a local query (findApps = the drawer's ranking). A tap = placeNewCells(1,1) (page in
  view, first free cell; wide page too) + powos.home.add, serialized, home re-read before the next; stays open for
  more; an app already on home (page or folder) is left alone. Gate: add-app-folded/-unfolded (mock keeps its layout
  over a reload when localStorage "powos-shell:mock.keepHome" = "1", bridge.ts). Render: shots edit-add-app.
- Relayout: measure() never runs while document.hidden and compares cellW (column count) too; Pages useMeasured and
  hosts/wide.ts recheck on visibilitychange (+2 frames, +400 ms), pageshow, orientationchange, resize, ResizeObserver.
  Gate: relayout-landscape/-fold/-unfold. The mock can't reproduce the phone's stuck-wide state: verify on the device.
- Gate cases go in dev/gate.mjs as small top-level helpers (whenReady, relayout...) - the complexity lint (60 lines,
  cognitive 10) covers dev/*.mjs too; prune baselines (dev/lint-complexity.sh --prune, targets/android/lint-complexity.sh --prune).

## Picking tiles, folders, the app library (ui/homeselect.ts, ui/folders.tsx, ui/library.tsx)
- Picking (edit mode only): chosen = keys. A tap toggles (edit mode never launches); the marquee starts on EMPTY space
  only when the finger was held MARQUEE_DWELL (180 ms: sets gesture.ts held, so the page swipe abandons) or moved
  up/down first (edit mode has no vertical gesture). Sideways at once = page swipe. Leaving edit mode clears chosen.
- A long press on a picked tile carries the party (partyAim/partyCells): one delta for all, clamped to the grid, null
  on any overlap (all or none), placed one by one through placeItem (wide.ts keeps wide cells). Ghosts = .carried each.
- Folders are the host's (ShellHome.kt Shortcuts: group(), tidy() dissolves <2 apps, that app in the folder's cell);
  the mock (hosts/layout.ts) now does the same and returns the folder key. Taking an app out = powos.home.add (the host
  removes it from its folder): no APK call needed. Names: store "home.folders" (key -> name), shell-only.
- wide.ts: group() copies the target's wide cell to the new folder; add() of an app from a 2-app folder gives the app
  left the folder's wide cell (else both land on side-by-side spots).
- App library = the page AFTER pages (state.ts pageCount/onLibrary: page.value === pages.value.length); pages itself
  is unchanged so pages.value[page.value] is undefined there - aim()/partyAim/marquee guard it, `?? 1` callers go to
  page 1. Vertical on it is its own (scroll). Categories: App.category (Android int) / categories (.desktop), from
  ShellBridge apps() since the categories APK; else guessed (library.tsx GUESS). Every app shows once: user folders as
  they are, every other app by category.
- Library/folder icons (AppPress): touch-action pan-y in cards so the page scrolls; once lifted a touchmove
  preventDefault keeps the carry (else pointercancel). Popovers close on lift (onLift), the card stays mounted.
- Open folder = ui/folderview.tsx, mounted at Home level (grid.tsx Folders, beside Carried): position fixed inside the
  transformed .home-content left the status bar and dock unblurred. FLIP morph: .folder-bg (.tile, frost material via
  the AI-page frost selectors) scales from the tile's box, the first 4 icons fly from the tile's minis, inline styles
  cleared at rest (rest()); closing keeps the last sheet mounted until it shrank. Both ends wait on the transitions'
  own `finished` (transitionsEnded), never a timer: a MORPH_MS+40 timer fired before a late-started transition ended
  (a busy frame on open) - it cut the last frames (a snap, transitioncancel at ~220 of 240 ms with 6x CPU throttle)
  and left the frost fading, which failed library-* on a loaded gate. Focus: .folder-focus (fullscreen .tile,
  frost blur + dim) fades in; home's .page/.bar/.dock fade out via html:has(.folder-view.open) - the compositor never
  blurs the page's own tiles. folder signal holds a home folder key or "lib:<cat>"; gesture.ts ignores home swipes
  while it's set. Library cards: 2x2 AppIcon minis, a count, the card is the tap; dedupe by name; HELPERS -> System.
- Gate: home-select-*, home-folder-*, library-* (incl. folderMorph/folderCloseCheck; these wait on the state with a
  3 s bound, never a fixed sleep: under 2 gates at --cpu-shares 256 frames lag the clock, a page slide hadn't begun
  500 ms in. Reproduce a load-only failure with Emulation.setCPUThrottlingRate 6 on that page) (synthetic PointerEvents dispatched on .pages - window-only dispatch
  never reaches element handlers). Device: tools/phone/verify/home-select.sh (transient only: picks, library; no
  layout change); folder-clip.sh records a morph (BOARD_TASK=<id> attaches frames). Renders: shots edit-chosen, folder-open, library.

## Tools
- shot.sh mounts the icon font and passes SHOTS_STRICT; idle.sh --wait re-holds a dropped adb connection;
  app-src.sh push records the phone's md5s (a second push of the same file works). Device checks: queue them
  (tools/phone/verify/queue.sh add <task> <script>) and end the turn. Screencap ids: cover 4630946316123810436,
  inner 4630946704981769859 (a black frame = that display is off).

## Sketch (local.sketch: apps/sketch, phone /home/powos/Projects/sketch, db local-sketch)
- A drawing is vector data: `stroke` rows (x,y,width triples in the drawing's own space = the canvas's device px when
  it was started: drawing.width x height), each written as it ends via an outbox (ui/lib/outbox.ts, kept in
  localStorage while offline). Any resize resizes the backing store and repaints every stroke through a View fitted to
  the drawing's extent (ui/lib/ink.ts): never crop. `image` is only the gallery/widget picture (reducer thumb); an older
  raster drawing (key "") is adopted on its first new stroke: picture copied to `base`, drawn under the strokes.
- Before 0.2.0 the page kept only canvas pixels (getImageData/putImageData at 0,0 on resize): rotating clipped the
  drawing at the landscape height and the clipped raster was what got saved.
- Zoom 0.02x-100x (ink.ts MIN_S/MAX_S, canvas px per drawing unit). Mid-pinch the canvas only gets a CSS
  translate+scale of the last render (look.shown = the view its pixels are at); on lift a vector repaint. So pen.ts
  reads positions from the canvas's PARENT rect (`frame`), never the transformed canvas. Points are rounded to
  ~0.1 canvas px at the drawing scale (`quantum`). Segments off screen are skipped (each is its own path).
- A stroke's width is in drawing units: one drawn zoomed out is huge zoomed in (the user's "light void" on
  2026-10-23 was two such white strokes). An older drawing's `base` is drawn keyed (BG -> transparent): no edge;
  it's a raster, so it can't be crisp - only strokes are.
- Test: apps/sketch/test/rotate.sh (headless, mock db; crispness vs the 1x render scaled, background at extreme
  pans). Device: tools/phone/verify/sketch-rotate.sh, sketch-canvas.sh, sketch-zoom.sh (fresh test drawing, deleted
  after; window.__sketch is read-only). They open Sketch and make the test drawing through sketch-lib.sh only:
  sketch_fresh waits ON THE PHONE (one async eval) for the gallery, clicks "new drawing" and refuses to draw unless
  __sketch.key is none of the user's keys with 0 strokes; drop deletes only that key. Sleep-timed clicks once ran
  before Sketch mounted and the check drew on the user's only drawing (2026-10-23, stroke 11 of drawing 1).
  A null __sketch mid-check = every page reloaded (a shell push/install: home's "not ready" in `push.sh --vpn
  --errors` at that minute) -> alive() cleans up, exit 3, the queue reruns it; not a Sketch bug. Ship: apps/build.sh sketch (bundles pages + __POWOS_SCHEMA__ since
  2026-10-23), then `ADB="docker exec powos-vadb adb -s 10.13.13.7:5555" apps/install.sh sketch ui --note ...`.
