---
name: powos-shell
description: Use before any visual change on the PowOS phone shell - design language/glass material, shade/control center, the app drawer (drag, A-Z scrub, recents, dock, icons), OWL and app-island widgets plus the preview tool, edge gestures/Quick Tools/overlay hosts, and the WebView bridge's security checks.
---

## Quick recipe
- Files: `shell/theme.css`/`shell/ui/shell.css` (tokens, frost/CC/shade), `shell/ui/{shade,control,pending,drawer,
  gesture,owl,bridge,quicktools,pull}.tsx`/`.ts`, `shell/apps/native.ts`, native: `targets/android/app/.../shell/
  {GlassBlur,Frost,ShellHost}.kt`, `.../system/{EdgeGestures,OverlayHost,QuickToolsHost,PullHost,GestureMonitor}.kt`.
- Build/render: `shell/dev/shot.sh OUTDIR 'REGEX' [SHELL_DIR] [WALLPAPER]` (targeted render + contrast report.json);
  whole sweep: `shell/dev/gate.sh --tree --shots DIR --wallpaper FILE` (tsc + headless boot + shots + style lint);
  widget preview: `shell/dev/preview.sh [--only REGEX] [--app DIR]... [--owl FILE|DIR]...`.
- Check, emu first then phone: `tools/phone/verify/queue.sh add <task> cc-toprow.sh|shade-panel.sh|edge.sh|
  az-scrub.sh|icon-hues.sh|...` (most design/drawer/widgets/gesture checks are emu+phone); bridge:
  `tools/phone/bridge-check.sh [page]`; read-only CDP (`tools/phone/cdp.sh eval <page> '<js>'`) for live computed
  styles - never inject into a live page.
- Land/ship: `tools/agents/land.sh "msg" -- <paths> --ship "plain words for the user"`.
- Friction: `tools/agents/friction add --area <design|drawer|widgets|gestures|bridge-security> --kind <...> "<title>" --repro "<cmd>"`.
- Gate debugging: puppeteer lives only in the gate image zenika/alpine-chrome:with-puppeteer; read its source with `docker run --rm --entrypoint sh zenika/alpine-chrome:with-puppeteer -c 'cat /usr/src/app/node_modules/puppeteer-core/lib/cjs/puppeteer/<path>'` (find the path with `find / -path '*puppeteer-core/lib*' -name Browser.js`).
- Don't set NODE_OPTIONS=--async-stack-traces for the gate: it breaks tsc and complexity. A failed startup step already names itself ([case: step]) since 1f18ecc2.

## design


## Quick recipe
- Files: `shell/theme.css`/`shell/ui/shell.css` (tokens, frost/CC/shade), `shell/ui/{shade,control,pending}.tsx`,
  `docs/DESIGN-LANGUAGE.md` (spec), native blur: `targets/android/app/.../shell/{GlassBlur,Frost}.kt`.
- Build/render: `shell/dev/shot.sh OUTDIR 'REGEX' [SHELL_DIR] [WALLPAPER]` (targeted render + contrast report.json);
  whole sweep: `shell/dev/gate.sh --tree --shots DIR --wallpaper FILE` (tsc + headless boot + shots + style lint).
- Check, emu first then phone: `tools/phone/verify/queue.sh add <task> cc-toprow.sh` / `shade-panel.sh` /
  `shade-overpull.sh` (most design checks are emu+phone); read-only CDP for live computed styles.
- Land/ship: `tools/agents/land.sh "msg" -- <paths> --ship "plain words for the user"`.
- Friction: `tools/agents/friction add --area design --kind <...> "<title>" --repro "<cmd>"`.

# PowOS shell design: what's known

## The material (docs/DESIGN-LANGUAGE.md is the spec)
- One material: `.tile` = `--glass-fill` (= `--text-fill`, the reference: PowOS AI's page at 912a284+3b9b5a3) over
  `--glass-veil`, `--lift` (top edge + shadow, no ring). Inside a surface only `--soft-fill`. Sheets `.tile.sheet`, the
  one text field `.tile.pill` (home search = AI compose, shell.css `.pill`). No borders, no dividers, no page dims.
- The pill's empty face is a prompt glyph `>`, not words (bar.tsx Pill `.prompt`, shown while value and placeholder are
  both empty; muted, var(--font) 3px over --text-item, zero-wide + -gap so the text starts where it sat; focused it
  blinks in place of the hidden caret). Callers name the field with aria-label ("Search", "Ask PowOS AI"); a
  placeholder is only a status ("listening…", an error) and replaces the glyph. Home pill, search widget (Bar proxy),
  AI compose, assist compose all get it from Pill - never per caller.
- Secondary text: `--color-muted` = the theme fg at `--muted-text` (88%), set in app.tsx applyTheme - never the
  theme's own grey (measured 1.5-3.7:1). Labels on the wallpaper: `--label-shadow`.
- Home's blur is the native compositor (ui/nativeglass.ts regions, native-blur's). The in-page model (the page drawing
  the wallpaper + CSS backdrop-filter) was reverted: system.glass gave no picture on OxygenOS (screenshot file 0 bytes,
  mirror black). Don't retry it without a phone screencap the manager approves.
- Edge to edge: home's window is fillxfill and the page is the full screen (innerHeight*dpr = the display), so the
  wallpaper is behind the bars. What covered it was the decor's own bar views (Theme.Material: black
  navigationBarBackground, 45 px folded / 0 unfolded; statusBarBackground 126 px) drawn OVER the WebView; ShellActivity
  sets both bar colours transparent + contrast off. Diagnose with `dumpsys activity top` (grep BarBackground: V = drawn).
  Device check: tools/phone/verify/nav-strip.sh cover|inner (bottom-rows pixel check). Its first cover "PASS"
  (2026-10-23 00:15) was a screencap of Magisk, not home: open the PNG, never trust a pixel PASS alone; the check now
  fails unless mCurrentFocus is HomeShell.
- Scrollbars: the phone's WebView ignores `scrollbar-width` (CSS.supports false); theme.css hides
  `::-webkit-scrollbar` globally and the WebView's View scrollbars are off (ShellHost).
- Assist (mode=assist) is the exception: the screen 1:1, its panel solid, no glass.
- Scrolling under chrome fades, never cuts (2026-10-24): shell.css `--scroll-fade-t/-b`, one scroll-driven mask on
  .drawer-list/.chat/.ai-panel/.ai-scroll/.notif-list; nativeglass.ts ends a fading clip's blur half-way into the fade.
  A scroll-driven animation is "running" for good: anything waiting for "no running animations" must filter
  `a.timeline === document.timeline` (nativeglass `moving()`, the gate's still()), else it never rests. Gate scroll-fade.

## Pending states (ui/pending.tsx) - the default for anything that takes a moment

A user-triggered change that shows nothing for more than ~100ms is a bug (2026-10-24). One shared building block
covers both halves of that rule:

- **Optimistic** (most actions: a toggle, a move, a rename, an install click): `optimistic(apply, commit, rollback)`.
  `apply()` runs at once - the UI already shows the result, as if it had already worked. `commit()` does the real
  thing in the background; a rejection calls `rollback(err)` (undo in place, a short reason, often a Retry) and still
  propagates. Used in app-api's `apps/app-api/ui/lib/add.tsx` ("Add to my apps" reads as added at once, reverts on a
  failed write) - that app can't import shell/ui (its own esbuild bundle), so it carries its own tiny copy; a shell-side
  use imports `optimistic` directly.
- **Placeholder/progress** (something that doesn't exist yet - a new app's build, a new widget's first data; an
  optimistic guess at content that isn't there would be wrong, not fast): `PendingState` (id, kind, title, status
  running/done/failed, steps, a log tail, an error) + `ProgressRing`/`ProgressBar`/`StepList`/`LogTail` to draw it,
  `PendingIconBadge` (an icon with a ring at its corner - the drawer's app-being-built cell) and `SkeletonWidgetTile`
  (a home placeholder at the real tile size: skeleton rows, a spinner, a progress bar). `PendingDetailSheet` opens
  the being-built view anchored to the tile (apps/sheet.ts's one popover - tap outside/swipe down/Back closes it),
  with Retry/Discard once it's failed.
- Fed live, never polled: app creation from PowOS AI's chat steps (`ui/appbuild.tsx`'s `pendingApp`, read by both the
  drawer placeholder and the being-built card, so they can't disagree about done); widget creation from
  powos-registry's `creation`/`creation_step`/`creation_log` tables (`apps/registry.ts` watchCreations/creationRows,
  written by `lib/apps/powos-compose` as it runs) through `ui/creationwidgets.tsx`'s client-side overlay (a reserved
  cell, never through the host's own layout, so nothing is lost if the build never finishes - itemsOn in grid.tsx
  merges it in exactly like searchwidget.tsx's footSearch already does).
- Swap in place, no flash: the placeholder and the real thing are two branches of ONE derived value (same signals,
  same render pass) - never two independently-arriving states that could both be visible, or neither, for a frame.
- Tokens only: `--color-accent` for the ring/bar fill, `--soft-fill` for the track and skeleton rows, `--color-red`
  for failed. Motion is calm and BOUNDED to the time something is actually building - an indeterminate ring/bar
  spins only while its component is mounted (a finite build), never a forever animation on a settled tile (the same
  reason `.app-icon.loading`'s pulse caps itself at ~10s: a spinning compositor layer costs battery at idle).

## Frost (PowOS AI, its pull-up panel, the control center: shell.css "frost v2", theme.css --frost-*)
- One material: the compositor's blur per surface (nativeglass.ts reads `--glass-blur-native` per element; 360 on
  these, 140 elsewhere; the shade window's radius is the page's: `powos.shade.blur(dp)` in shade.tsx), a cool tint
  (`--frost-base`/`--frost-fill`) at the reference strength. Over the OTHER tone of wallpaper it flips to that tone
  (light glass + `--frost-ink` text) - never a heavier fill (an 84% fill read as "brown slab" and was rejected).
- No text halos (read as highlighter on a light wallpaper). Labels on raw wallpaper = small frost pills with
  `--lift-edge`. Inside the frost, secondary text is the ink itself, not a see-through grey.
- Over pure black the blur is black: keep the glass visible with the sheen + lit edge (`--frost-sheen`).
- Icon plate (`--icon-plate`, theme.css; the squircle behind irregular Linux icons): built from --color-surface +
  accent it read as BROWN in gruvbox (warm surface #3c3836) - rejected. Now `--frost-base` 85% + `--frost-swap-cool`
  (opaque, a step towards the other tone so dark glyphs like Konsole show): oklab chroma ~0.01 in gruvbox, kanagawa
  and flexoki-light. Any neutral fill: derive from --frost-*, never from --color-surface (warm in warm themes).
  Resolved on :root, so the per-surface frost swaps in shell.css don't move it. Check: render `icons-mixed` with
  SHOTS_THEME per theme + SHOTS_PROBE reading the `.app-icon-face.plate` background.
- PowOS apps' pages (`.app-screen.tile.sheet`, appscreen.tsx) and the library's cards (`.lib-card.tile`) wear it too:
  add a surface by listing it in the four frost selector lists in shell.css (vars, dark-over-dark base, background,
  other-tone flip) - never a new fill. The plain `.tile.sheet` reference was the "brown slab": over a wallpaper of the
  other tone `--glass-dim` 68% makes it 100% tint = opaque. The page background block is `html.glass-native` only, so
  the picture-glass fallback keeps its frosted picture. Opt-out: manifest `page.background: "own"` drops `.tile` (no
  compositor region under a page that paints its own ground, e.g. Sketch's canvas; Sketch is opaque anyway).
- Lights/Shopping pages paint no root ground (the shell's is what shows); Sketch's page is `position: fixed` #121216,
  its chrome inline in the app - the shell can't restyle it. Floating-window chrome is Kotlin only (WindowFrame.kt), in frost v2 via system/Frost.kt (theme.css's formula
  ported: change the frost tokens -> change Frost.kt too).
- Scene `app-page` (shots.mjs) opens local.lights over home (empty headless: no registry) - the material check.
  Test wallpapers: make light/dark JPGs with `uv run --with pillow python` (no PIL on the Mac); an exported tree for
  /a renders needs shell/fonts/nerd_symbols.ttf linked (git archive drops it, shot.sh then exits silently).

## Shade (ui/shade.tsx, notifications.tsx NotificationPanel)
- One panel by default: control center on top, notifications under it, one `.notif-list` scroll; Settings > Style >
  "separate notifications & controls" (`separatePanels`) restores the split; shade.tsx maps the host's "control" pull.
- Unfolded (`wideShade`, innerWidth >= 700, notifications.tsx): `.panel-body.together.two` = two `.notif-list` columns,
  `.notif-col` (notifications) left, `.cc-col` (ControlCenter) right, each its own scroll, one frost panel. shade.tsx
  keeps the host's "shade.panel" side in `panel` there: `data-from` delays the other column's cascade (`--i0`). Folded:
  the stacked list. Gate shade-folded / shade-unfolded (shadeLayout in gate.mjs).
- Open: short `--drop` (15vh) + cascade (`.cascade`, `--i` row index; CC rows first). Grouping `grouped()`; stacks.
  The further pull (ccExpanded) unfolds every stack too; a tap then folds one (`expanded` holds the exceptions, reset on
  each change). The phone checks' stop/resume control sits in v3's Tools (ui/tests.ts, bridge verify.stop, gate
  overpullTests): shown only while the runner runs/waits/is paused and the host answers verify.stop's dry probe.
- The one panel's EDGE follows too (shell.css `--cc-lift` block): the panel translates up by (1-q)*--ph + --cc-lift,
  its body back down by the same, overflow-y clip; frost, edge and grip move, content doesn't. Gate shade-overpull
  asserts edge/grip/no empty slab; device: tools/phone/verify/shade-panel.sh (recording + SF blur-region coverage).

## Control center (ui/control.tsx; v3 = `Controls`, classic = `Categories`, flag `ccV3` key "ccLayout")
- v3: ONE ordered list (`list`): first six = the first pull's row; a further pull (ccexpand.ts) reveals the rest
  below, the row never moves. It lays the rest out once (`.cc3-grid.cc-peek`; never bare `.peek`, the banner's fixed
  class), puts what's under `.cc` back up by its height, then per frame only those translates + `--cc-k` on the grid
  (inherits:false, cells inherit by name) + the panel's `--cc-lift` (its growth G - shown, measured once per pull).
- Order: curated (QUICK, then the rest) unless `ownOrder()`: a v3 edit (`v3: true` in controls.layout) or a classic
  arrangement with a net move. Only drags write controls.layout; never reset it without the user saying so.
- Long press = the toggle's own page (cancelled once the finger moves); rearranging = edit mode via the header pencil
  (`ccEditing`), then a long press lifts (ui/reorder.ts, `onlyEditing`). Accent only on toggles that are on.
- ui/reorder.ts (shared; the widgets expert reviews it and owns home's grid.tsx): hit-test on container-relative laid-out boxes (FLIP cancelled first),
  live order in a ref, cancel drops the lift. Gate `cc-reorder` waits on states (prove: `CC_THROTTLE=6` x20).
- On the device: `tools/phone/verify/cc-toprow.sh` (queue it) - v3, no headings, the row's boxes equal before/after
  the further pull. The saved order: /data/data/com.powos.app/files/shell-data/controls.layout.json (read only).

## Render, check, ship
- Targeted renders: `shell/dev/shot.sh OUTDIR 'REGEX' [SHELL_DIR] [WALLPAPER]` (scenes at the top of shots.mjs;
  SHOTS_SCALE=2 for readable crops, SHOTS_PROBE='<js>' to print page state, SHOTS_GLASS=native|page). Output PNGs +
  report.json (each text's contrast vs the rendered pixels). The phone's own wallpaper for renders:
  `su -c cat /data/system/users/0/wallpaper_screenshot.png` when it isn't empty. Whole sweep: `shell/dev/gate.sh --tree --shots DIR
  --wallpaper FILE`. Contact sheet: shell/dev/sheet.mjs (/a before, /b after).
- Renders in another theme need its mock widget trees: `shell/dev/sample-trees.sh <theme>` (shots refuse a theme
  without them; gruvbox, kanagawa, flexoki-light exist). A light test wallpaper exposes contrast the dark one hides.
- Contrast tokens: --color-muted (fg at --muted-text 90%), --accent-text, --label-shadow/--on-wallpaper (turned round
  on html[data-wallpaper] of the other tone, glass.ts), widgets' --glass-dim 42% + muted = fg inside, owl.tsx maps a
  theme's grey by any of its names. Fix a failure at the token, never per text.
- Headless isn't the device: after the push, read the live element's computed display/rects over CDP (read-only:
  never inject or render into the live page) - a drawer strip once passed headless and broke on the device.
- Style lint (in the gate): raw colours, coloured borders, shadows outside tokens fail; exceptions in style-allow.txt.
- Gate base = the installed APK's own shell + the phone's overrides + your files (handbook Shipping); READY_MS=60000
  when the Mac is loaded. shell.css/theme.css are shared: push only origin's tip versions.
- Device checks: `tools/phone/verify/queue.sh add <board-task> <script>` and end the turn (never wait on the phone).
  Read-only CDP (`tools/phone/cdp.sh eval shade '<js>'`) for state; screencaps only in a queued window. Folded vs
  unfolded: read the size from `dumpsys window displays` (cur=WxH). Injected swipes must never launch apps (a page
  swipe at 60% height opened Calculator unfolded); a drag starting on a toggle used to open its settings.
- Verify lock: only after the window is free, only for the injected part; never delete one you don't hold.
- Review images: `tools/phone/review-image.sh FILE...` (/home/powos/design-qa/); mocks only for new screens. Push
  notes are user-visible (shade + AI feed): plain words, never "x".

## Native blur (compositor) - Kotlin side

Facts as of 2026-10-22 (OnePlus Open, OxygenOS 16). Code: targets/android/app/.../shell/GlassBlur.kt,
WindowBlur.kt, WallpaperBackdrop.kt, LiquidGlass.kt; page side shell/ui/nativeglass.ts.
- What works here: SurfaceFlinger blur REGIONS (`Transaction.setBlurRegions` on a window's ViewRootImpl SurfaceControl,
  hidden API). They blur every layer BELOW that window (wallpaper, other windows, apps), never the window's own pixels.
  A window's plain background blur radius did nothing visible here; don't rely on it.
- Region layout: OxygenOS reads 31 floats per region (AOSP 10 + blur colour + OPlus params). A wrong length aborts the
  app in JNI (home crash-looped once). Never build the array by hand: GlassBlur.Codec fills a
  BackgroundBlurDrawable's FIELDS by reflection and calls BlurRegion(drawable).toFloatArray(); checked once
  (valid()) before use; failure -> b.state 0, CSS fallback.
- Pitfall: never call the drawable's setters (setBlurRadius/setAlpha/setCornerRadius). They register it with the
  window's own blur aggregator, which then re-sends it every frame and OVERWRITES your regions (the shade had no blur;
  a test rect showed on another window's layer).
- One region list per layer: setBlurRegions replaces it. Home merges its tiles' regions + the switcher's whole-window
  region in one call (GlassBlur.wholeWindow); other windows use GlassBlur.wholeWindowOf (shade, switcher activity).
- Radius: SF's blur is ~0.15-0.3 of the radius given. Home tiles: --glass-blur-native (140 CSS px). Shade: 360 dp
  default (ShadeHost SHADE_BLUR_DP), page-tunable with powos.shade.blur(dp) 0..600. No saturation/brightness: tint in CSS.
- A window just shown has no valid surface yet: WindowBlur retries on the next frames (don't cache as done). A region
  is the window's rect at send time: WindowBlur keys it by radius AND size and resends on a resize (a GONE window
  shown again, the banner strip grown into the shade, kept a strip of blur). ShadeHost eases the blur on settle.
- Respect Android's switch: WindowManager.isCrossWindowBlurEnabled (battery saver) -> no blur; never forced.
- Page protocol (native port): b.hello -> b.state 1|0; b.r <dpr> <n> x y w h tl tr br bl alpha radius...; regions sent
  per frame only while something moves (touch, transition, resize of a surface), nothing at rest (perf-checked).
- Wallpaper picture (/_wallpaper, system.glass): WallpaperBackdrop.still - the wallpaper's mirror
  (IWindowManager.mirrorWallpaperSurface + captureLayers WITH a source crop, else BAD_VALUE -22) comes back BLACK on this
  build, so it falls back to captureDisplay excluding home's window (only while home is in front), bars painted over.
  OxygenOS's wallpaper_screenshot.png can be 0 bytes. READ_FRAME_BUFFER comes from the recents role.
- Liquid refraction (LiquidGlass.kt): OFF by default (user: "looks weird"); returns only after a design sign-off.
- Check on device: open the shade from the page (`powos.shade.open()` via CDP, idle window), then
  `dumpsys SurfaceFlinger` - the layer shows `blurRegions.size()=N` and `{radius=..u, ... rect=[...]}`; screencap
  with `-d <id>` for the display in use (unfolded = the 2268-wide one) and pull inside powos-vadb (tools/phone/adb.sh
  loses pulls to paths that don't exist yet). Logcat tags: PowosGlassBlur, PowosBackdrop, PowosWallpaper.

## Latest hand-off
- 2026-10-24, shell-desk-fade (1d61a0c0, pushed; ship requested while the service was PAUSED - not on the phone yet):
  wide launcher above the bar (start menu, bar stays tappable); scroll edge fades (drawer, AI panes, shade, chat);
  over-pull unfolds notification stacks; "tests" stop/resume control in v3 Tools (ui/tests.ts, bridge verify.stop -
  needs the new APK, hidden until its dry probe answers).
- Gate: wideLauncherBar (wide-home), scroll-fade (404x560 so the mock list scrolls), stacks in overpullExpand/Fold,
  overpullTests. Stillness helpers must ignore scroll-timeline animations (see Scrollbars note above).
- Open: no device check yet - queue one per change after the ship (wide drawer + bar, edge fades in drawer and PowOS
  AI, over-pull stacks, tests control after the APK). No board task was claimed (board unreachable at the time).
- Unreviewed choices: tests control hidden while the runner is idle/silent (unless paused); v3 only, not classic.

## drawer


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
- Stage 2 (ui/overpull.ts, board launcher-pull-further-up-search-keyboard): the "open" drag past the open place
  (finger d = -dy - travel/GAIN) or, drawer open + apps kind, up at the list's end / off the list (mode "over",
  claimOnOpen) lifts .launcher-inner on a rubber band (one paused WAAPI anim, max 48px, no style writes); past
  max(120, 0.25*innerHeight) px (read once per pull: the keyboard shrinks innerHeight) a 10 ms vibrate AND, finger still
  down, foot textarea focus() then powos.keyboard.show() (ShellBridge -> showSoftInput); back 24 px below it before the
  release: keyboard.hide() + blur() (stage 1). Released armed = drawer open, keyboard stays. The left-half (AI corner) "open" also over-pulls: on the
  wide home the AI panel hides the bar (visibility: hidden = unfocusable), so raiseSearch falls back to .ai-compose and
  shows the keyboard only when a field really has focus (keyboard up + nothing focused, e2e round 3, 2026-10-23). Short of it: stage 1, no keyboard. Headless probe:
  synthetic TouchEvents on .home via SHOTS_PROBE (~/.cache file, see verify/pullup-stage2.sh for the device check).
- Device gestures: a held pull is ONE adb call per burst (`input motionevent DOWN..; MOVE..`) from an EMPTY spot read
  over CDP - a DOWN on the dock held across adb calls (~1 s each) is an icon long press, not a drag (pullup-stage2,
  2026-10-23). Never inject a DOWN on a tile/icon and wait.
- A pull that "doesn't open" on the device: first check where it started. Inside a floating window (windows.list
  bounds, ui/desktops.ts inWindow) it is the app's by design; left half with pull-up corners on = PowOS AI's panel.
  CDP elementFromPoint can't see Android windows. List end in a check: tap the A-Z bar's last letter, not flings (a
  fling starting at the end IS the over-pull: search + keyboard).
- Drawer: A-Z `.grid.az` in `.drawer-list` (padding-right --letter-bar). RecentRow (`.drawer-recents`) is OFF by
  default: `drawerRecents = stored("drawer.recents")`, "on" shows it; Settings > style > home > "recent apps in the
  drawer". The check is inside RecentRow (Drawer itself is at the cyclomatic limit).
- A-Z scrub highlight (drawer.tsx highlight()): per LETTER change (not pointermove) `.grid.az[data-scrub]` + the
  letter's cells `[data-lit]` (range first.get(l)..next letter's first); shell.css dims others to 0.4, lit get
  scale 1.05 + translate -2px, 180 ms transitions; release clears. Data attributes on purpose: nativeglass/glass
  MutationObservers watch only style/class, and Preact doesn't own them. Shots scene "drawer-scrub" (synthetic
  pointerdown at M; setPointerCapture stubbed - it throws for a fake pointer); device: tools/phone/verify/az-scrub.sh
  (input motionevent DOWN/UP on M, probe + screencap while held).
- Pill: empty height = `--pill-height` 40px (theme.css; on screen 44 with borders), grows only with typed lines up to 3
  (grow.tsx: empty = one row at any width, re-measured on width change - a narrow-measured empty pill stuck at 3 rows,
  2026-10-22). `.bar-pill` bottom = `--pill-foot` 6px, same as `.ai-compose`. The gate's "pill" run asserts it (foot,
  compose, search widget 6x1/6x2/2x1, after narrow->wide). Widths: wide home's cap is the desktop agent's.
- Dock's recent apps (home.tsx Dock 2nd page `.dock-page.dock-recent`): `.dock .dock-recent .app` flex 0 0
  calc((100cqw - 28px)/6), `.dock-pages` container-type inline-size. NOT 100vw: WebView's vw was 688 on the 404 cover.
  Check: shell/dev/perf/dock-scroll.sh (one free window: swipe, scrollLeft, widths, screencap).

## Wide bar (unfolded, home.tsx .home.wide from hosts/wide.ts wideHome)
- .home is a grid: stage over a one-row foot (strip-height): Dock (pinned only, no recents page) | .bar (pill column
  --wide-pill clamp(220px, 30%, 360px), pill centred in the row: --pill-mid) | DockTray (recents, a .dock.paged row).
  Slots --slot min(60px, (100cqw - 28px)/6); the pinned .dock-page is as long as its icons (dockdrop slotAt measures it).
- Drawer above it like a start menu (the user, 2026-10-24): frame and window end at the stage's foot (the bar's top);
  the whole bar stays in place, shown and tappable (no slide, no fade). PowOS AI's wide panel still covers the foot.
  Gate wide-home wideLauncherBar.
- The search widget on the grid (.search-parked) parks the bar's pill (opacity 0 at rest) but it KEEPS the bar's middle
  slot: measure the bar with `.home.wide > .bar .bar-pill`, never the first `.bar-pill` (that's the widget's tile).
- Pinned dock never fades (the user): `.dock.paged:not(.dock-tray)` runs dock-fade-pinned (right fade 0 at rest,
  grows only scrolling into the recents); the wide DockTray keeps dock-fade. Gate dock-no-fade.

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

## Uniform icons (board "Uniform app icons")
- ui/iconshape.ts measures each icon URL ONCE in idle time (96px canvas: alpha>24 box, solid share): "fill" (about
  square, >=88% solid: adaptive, full-bleed, rounded square) fills the face; "plate" (Konsole, Foot, Dolphin, round
  legacy icons) is fitted to GLYPH 0.76 on `--icon-plate`. Kept by URL in memory + localStorage `powos.icons.shape`
  (URLs name pixels, never stale), so known icons lay out in the first frame. AppIcon: `.app-icon > .app-icon-face
  (.placed/.plate, squircle, overflow hidden) > img` with inline left/top/width/height; tinted copies reuse the measure.
  `.app-icon::after` (running bar) stays outside the clip. Failed/cross-origin: shown as is.
- Kotlin: ui/IconMask.kt drawShapedIcon draws adaptive icons' own layers in the same 22% rounded square (not the
  system mask), AndroidApps uses it - so Android icons arrive already in the one shape.
- Sizes per context: --icon (grid/drawer), --strip-icon (dock/strip), 58% of a tile/folder cell, library 2x2.

## Running bar (board running-indicator)
- AppCell (dock, dock recents, drawer, drawer recents, recent widget) sets `data-run` from ui/running.ts (`running`
  signal: app key -> "running" | "frozen", `powos.apps.running?.()` once + "apps.running" events, re-asked on
  apps.changed). shell.css: `.app[data-run] .app-icon::after` 10x3 accent bar under the icon, a 1px ring of
  --color-background (the accent's own ground; the style lint allows `0 0 0 Npx var(--color-*)` rings, not new tokens; --on-wallpaper-halo failed light themes at 1.3:1); frozen 0.4.
  Floating windows (`.dock .app.windowed`) share the bar (the old foreground dot is gone). Home grid icons: none.
- Sources (no polling): RunningApps.kt (system/): FreeformTasks.listen -> getRunningTasks packages (live activity, any
  windowing mode incl. freeform; a recents-only entry after force-stop is not running; own package left out). The
  listener needs HiddenApi's "Landroid/app/ITaskStackListener" exemption (Stub.asInterface is hidden; without it the
  map stayed at the start-up read: no event ever came). Logcat "PowosFreeform: task stack listener on" = registered;
  the main buffer rotates in seconds (OplusTouch spam), so grep right after a restart.
  FileObserver on files/run/running/apps.json = powos-sleep-gui's `publish_running` ({"classes": {cls: state}},
  written on change from report/freeze/thaw/reset). ShellBridge `running()` maps: "a:<key>" by package, "l:<id>" by
  LinuxApp.matches or steam_app_<appid> -> an entry whose Exec has rungameid/<appid>.
- Logcat tag PowosRunning (RunningApps): "task listener on|MISSING" at the app's start, "tasks: <pkgs>" on every
  change - grep it to tell a silent listener (no "tasks:" line after a launch) from an event lost on the way to the
  page (line there, cells unmarked). PowosFreeform's "task stack listener on" is logged by WindowFrames' listener too.
- The device check stops Calculator FIRST: the 01:43 PASS (2026-10-23) found it open, so it only re-read the
  start-up map and never exercised an event. Its FAIL says which link broke (host map via apps.running vs cells).
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

## App menu window actions (parked 2026-10-23, window features frozen)
- Done, gate-passing, NOT on the shared branch: origin branch `agent/dock-window-menu` (one commit). AppMenu
  (ui/apps.tsx windowItems) puts close, minimise/restore, and with 2+ windows each window first for a running app;
  desktops.ts windowsOf/closeApp (tasks.remove of its windows/tasks; l: keys try the new "apps.close" bridge call
  first: ShellBridge.closeApp runs `powos game <appid> stop` or Steam's Wake + -shutdown). Gate: appMenuCheck.
- To resume: rebase that branch, gate, push, ship (needs an APK for apps.close; old APKs reject it and the page
  falls back to removing tasks), then queue the phone check on board task long-press-a-running-app-in-dock-recents-close-a.

## widgets


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

## App API (local.app-api: apps/app-api, board app-api-app-view-toggle-app-apis)
- A page-only PowOS app over a LOCAL service: tools/app-api/appcap_serve.py on 127.0.0.1:3411 (system-tier service
  lib/apps/services/app-api.json, unit units/phone/app-api.json), reached with host.net.fetch - manifest "net":
  ["127.0.0.1"] (ShellNet's "lan" does NOT cover loopback). The service adds no logic: views = appcap_render.py,
  calls = appcap_run.py --consumer app (the one safety path), toggles = the spec's `enabled` flags in
  ~/.local/state/powos/app-api/specs (seeded once from examples/). Sends: read only; writes dry run; spend never.
- Going live needs three separate steps, none of them the ship service (it ships only shell + APK):
  apps/install.sh app-api (the UI), rooted.sh deploy (stages tools/app-api -> /usr/lib/powos/app-api), and a
  system-tier restart (`rooted.sh system stop` + `on`): the supervisor reads services/ only at start, and
  lock_ports (POWOS_PORTS) runs only then. That restart bounces SpacetimeDB: it needs the user's yes.
- App-page styling: inline styles in theme tokens (--soft-fill, --color-accent/--accent-text, --color-muted, --font),
  no root ground (the shell's frost shows), switches = role=switch buttons. lib/apps/templates/page uses 1px borders:
  don't copy them.
- Headless look: the built page module + preact from shell/node_modules + a mock host.net, in
  zenika/alpine-chrome:with-puppeteer (mount the script INTO /usr/src/app so it finds puppeteer). Device check:
  tools/phone/verify/app-api.sh (5 Hue actions + list_rooms dry run; never sends to the bridge).
- apps/*/ui is covered by the pre-push complexity lint (shell/dev/lint-complexity.sh --apps): split tab switches and
  `??` chains (each counts toward cyclomatic 10).

## gestures


## The input path (one input monitor, consumers in order)
- GestureMonitor.kt: InputManager.monitorGestureInput (MONITOR_INPUT via the recents role). On each finger DOWN the
  consumers are asked in order (PowosRecentsService.startGestures): **CornerPull(NavGesture) -> EdgeGestures ->
  ShadeHost.pull**. The first whose onDown says true follows the gesture; TAKE pilfers (windows + other monitors get a
  cancel). `takesOnDown` (EdgeGestures) pilfers at the FIRST event after the down - never inside the DOWN's own
  delivery: pilfered there, the dispatcher sent the monitor a second DOWN and none of the moves (Quick Tools dead,
  "edge: down" logged twice; InputDispatcher: "pilfer points from a channel without any on-going pointer streams").
- Order matters: ShadeHost.pull accepts any finger on home's body while homePull is on, so the bar's strip (nav,
  corners) and the edge handles must come first.
- SystemUI's EdgeBackGestureHandler ("[Gesture Monitor] edge-swipe", OPlus "NoBackGesture" logs) is also a spy;
  whoever pilfers first wins. The edge handles pilfer at the first move, before its threshold, so Back never wins inside the handle; above/below the handle nothing is touched. Pilfering on down costs the
  app the taps in that 18 dp strip (the same trade-off Good Lock makes).

## Edge gestures
- EdgeGestureClassifier.kt (pure, EdgeGestureClassifierTest): the direction is decided after `trigger` px of travel
  (sensitivity high 18 / normal 28 / low 44 dp): straight <= 30 deg, up/down <= 75 deg, steeper = along the edge (none).
  Long = held still (6 dp) 300 ms after deciding; the host polls `hold()` every 50 ms, because a resting finger sends no moves.
- EdgeConfig.kt <-> screens.tsx GesturesScreen: the page store `edgeGestures` = files/shell-data/edgeGestures.json
  (FileObserver reloads it). Keys short|long.straight|up|down. Actions: quicktools back home recents previous
  notifications control assistant drawer playpause none app:<pkg>. Defaults: right on, lower half (0.5..1, clamped
  above the nav strip), straight=back, up=quicktools, down=notifications; left off (all short = back).
- Off when: keyguard/bouncer/dozing/lock face, either shade open, Quick Tools open, IME visible (SYSUI bit 18 on this
  phone - read from SystemUI's getSystemUiStateString via dexdump).
- Back = ISystemUiProxy.onBackEvent(null) (HACK row; SystemUI sends down+up itself). Assistant =
  PowosVoiceInteractionService.show() (showSession). Drawer = home intent with EXTRA_HOME_PANEL -> "home.panel".
- Handles: TYPE_NAVIGATION_BAR_PANEL (2024) non-touchable strip windows "PowOS edge handle left|right".

## Window hosts (OverlayHost.kt base: TYPE_STATUS_BAR_SUB_PANEL 2017, full screen, kept warm GONE)
- show() visible not touchable -> armOpen() touchable+focused only after PageWatchdog.probe answers (a dead page must
  never leave an invisible touch-eating window) -> armShut(), and the page says closed (else hide after 1.5 s).
  Home/recents/screen-off (ACTION_CLOSE_SYSTEM_DIALOGS) dismiss.
- QuickToolsHost: mode=quicktools (ui/quicktools.tsx: control.tsx's Tile/Slider, onShut hook). Events "qt.drag"
  {side,y(css px),q}, "qt.settle" {open}; page calls powos.overlay.closed(). Blur = native region under the card only
  (nativeglass.ts OVER_WALLPAPER includes "quicktools"; glass.ts TINT_ONLY too).
- PullHost: mode=pull (design-QA's ui/pull.tsx). "pull.begin" {kind apps|ai}, "pull.drag" {p}, "pull.end" {open},
  "pull.hide"; page calls powos.pull.closed()/launched(); Back -> "system.back". Blur: WindowBlur({root}).set(p).
  CornerPull: outer 22% of the bottom strip, over an app only, claimed once up > slop and > 1.2x sideways (nav gets a
  cancel); switch files/shell-data/pullOverApps.json ("off").
- ShadeHost (mode=shade, ui/shade.tsx + notifications.tsx/control.tsx): the ONLY notification panel/control center.
  From the status bar (right half = control) or, while `homePull`, anywhere on home's body (notifications), claimed
  only if dragged down within 250 ms of the down (a long press's drag stays home's). Home's page sends
  shade.homePull(on) from home.tsx (nothing open, page >= 0); it resolves true when the host's monitor takes it, false
  -> gesture.ts asks shade.open on a swipe down. openPanel(control) opens it without a pull (edge actions).

## Pitfalls already paid for
- A kept-warm overlay page reloaded while hidden (an install, a shell push) only boots once its window shows: armOpen
  uses PageWatchdog.probeShown (3 s grace for "not rendered"), or the first pull after an install closed at once.
- Kotlin pushes: `tools/phone/compile-check.sh && git push` - its exit code, never a grep of its output (0b3a702
  broke origin's build that way).
- A shell file pushed/overridden without what it imports breaks every page (17:09, 2026-10-21: home.tsx imported a
  gesture.ts export only a later commit added; every page failed after the install). Commit related shell files
  together; ship-apk now gates HEAD's own shell before building. gesture.ts is shared with the drawer and widgets.
- Kotlin: `return Log.w(...)` in a Unit function is a type error; ShellActivity's companion is private (top-level
  EXTRA_HOME_PANEL). OxygenOS framework shapes: check with dexdump first (handbook).
- The gate's assist page can time out once (flaky); rerun before blaming your change.

## Test
- Unit: gradle `:app:testDebugUnitTest --tests "*EdgeGestureClassifierTest*"` (in the android builder image).
- Shell: `shell/dev/gate.sh --tree`; renders: `SHOTS_ONLY='quicktools|gestures' shell/dev/gate.sh --tree --shots DIR`,
  review images via tools/phone/review-image.sh before shipping.
- Device checks take the verify lock only AFTER the free window (handbook 5a): `. tools/phone/verify/window-lock.sh;
  window_lock <name>` - never hold it through a wait (it blocks every ship-apk install). `verify/fold.sh` forces the
  other screen (cmd device_state, always reset); `verify/overlay-reload.sh` the push-then-pull reload check.
- Device: `tools/phone/verify/edge.sh [home|edge|corner|all]` (one AWAKE_ONLY idle wait, WAIT_S; goes home and checks
  it's in front; window states snapshotted mid-gesture via motionevents; recordings as root into $OUT), logcat tags PowosEdge,
  PowosCornerPull, PowosOverlay, PowosShade, PowosGestures; `dumpsys window windows | grep 'PowOS '` for the windows.

## Lock, overlays and reloads (facts)
- Never over a locked phone: `DeviceLock.locked(ctx)` (lock face up or KeyguardManager.isKeyguardLocked) gates the edge
  handles, Quick Tools, the shade pull and the pull-up panels. SystemUI's state bits are NOT enough: the PowOS lock face
  makes the keyguard OCCLUDED, not SHOWING. Handles re-check on SCREEN_OFF/ON/USER_PRESENT.
- Shell push reloads of hidden overlay pages are the host's (`OverlayReload`, `ShellHost.filesGate`): reload at alpha 0
  while hidden, defer while shown, poll with a hard 8 s deadline (an evaluateJavascript during navigation never answers).
- The shade pull maps the finger as the page does (`PanelPull`: q = dy*1.5/--drop, open > 0.15 or a flick); ShadeHost
  reads the page's `--drop` once per height.
- Home has NO notification panel of its own: home.tsx sends `shade.homePull(on)`; the host's monitor takes a down-drag
  on home within 250 ms of the finger-down.

## Keyboard for PowOS (Linux) text fields - task keyboard-follows-powos-text-fields
- Wayland: KWin patches 0010/0012 (targets/android/pkgs/kwin) send OUTPUT_TYPE_KEYBOARD on text-input v2/v3 focus ->
  engine SystemIME.setSystemKeyboardVisible; typed text returns as INPUT_TYPE_TEXT_INPUT. KWin logs
  "Android keyboard shown/hidden - <why>" on its stderr.
- X11 (Xwayland: no text-input; KWin 6.7 has no IM path for X11 clients): unit x11-ime-bridge. ibus-daemon --xim
  --panel=disable; GTK on X11 picks IBus's module by itself (GTK4: wayland prio 100 > ibus 50 > simple, so Wayland
  GTK stays on text-input); session/powos-ime-bridge is IBus's panel: FocusIn(ctx) -> KWin patch 0016 D-Bus
  `org.kde.KWin /org/powos/Keyboard org.powos.Keyboard.SetX11TextFocus(b)` (shown only while the keyboard focus is
  Xwayland's; logged "x11 focus/blur"). InputContext_1 = IBus's fake context (= nothing focused); blur debounced 150 ms.
  Typed text returns as key events (InputMethod::commitString without text-input). Log $XDG_RUNTIME_DIR/powos-ime-bridge.log.
- Env (session/plasma/powos-ime.sh -> plasma-workspace/env/ibus.sh + profile.d/60-powos-ime.sh): XMODIFIERS,
  IBUS_ADDRESS_FILE (IBus otherwise names its address file after WAYLAND_DISPLAY/DISPLAY, which differ per launcher).
  Never GTK_IM_MODULE/QT_IM_MODULE (takes Wayland apps off text-input). The image's env/ibus.sh was a shell error.
- Rootfs: phone-rules.conf keeps ibus (engines provided-away); KWin ships via rooted.sh deploy (newest out/pkgs kwin).
- Open: Steam's CEF only reaches IBus if its webhelper loads GTK's IM (unverified on the phone); a keyboard dismissed by
  Back doesn't return on a re-tap of the same X11 field (no new FocusIn).
- Open Linux apps for a check as the launcher does: `am start -n com.powos.app/dev.omalauncher.shell.ShellActivity --es
  exec '<cmd>'` (debug builds); never type into the user's tmux sessions.

## Device checks (all queued, never waited on)
- `tools/phone/verify/queue.sh add <board-task> <script> [args]` then end the turn; result lands on the board.
- Scripts: edge.sh [home|home-short|edge|shade|corner|locked|all], edge-more.sh (Back both edges, landscape, left edge;
  restores rotation + edge config), overlay-reload.sh (push then pull), fold.sh (forces the other screen via
  `cmd device_state state 0|3`, always reset), keyboard.sh. All take the verify lock only after a free window
  (window-lock.sh), honour LOCK_HELD=1.
- Test swipes: keep Quick Tools' in-and-up near 40 degrees on every screen shape (a flatter one is straight in = Back).
  The lock face is a swipe up (no PIN); screenrecord only as root into /data/local/tmp; pull into an existing dir.

## bridge-security


## Threat model
- WebView.addJavascriptInterface injects the object into EVERY frame of the page (iframes included, sandboxed
  ones too - checked on the phone: an opaque-origin presentation frame had PowosHost) and the Java side cannot
  tell who called. The host API can fetch with the user's secrets, launch/uninstall apps, change settings - so any
  script in any iframe owned the phone. That is why the objects are no longer JS interfaces.
- Now: androidx.webkit `WebViewCompat.addWebMessageListener(web, name, rules, listener)` in ShellHost.kt. The
  WebView injects only into frames matching `rules`, and the listener gets the sender's origin + isMainFrame.

## Allowed
- `ShellOrigin.rules(devUrl)`: `https://shell.powos` (never hits the network; ShellHost serves every request) plus
  the dev server's origin when a dev URL is set. If the WebView rejects the rule set, ShellHost falls back to the
  shell origin only (logged "origin rules ... refused").
- `ShellOrigin.allowed(origin, isMainFrame, rules)`: top frame AND exact origin in rules. Nothing else.

## Refused (and logged, tag PowosShell: "<name>: refused a message from an iframe|the top frame at <origin>")
- any iframe, even same-origin srcdoc/about:blank (they inherit the parent's origin, so origin alone can't tell);
- "null"/opaque origins (sandboxed frames, data: URLs), empty/missing origin, any other origin.
- Answers always go to the top frame (ShellBridge.respond), so a subframe never needs the bridge.

## Page side
- shell/bridge.ts and shell/apps/native.ts talk via `window.PowosHost.postMessage(...)`; index.html's boot guard
  handles PowosBoot and an older APK. The desktop's call() is unchanged. PowOS app UIs (./_app/<id>/) are modules
  in the top frame, so Lights/Shopping/Sketch keep their bridge; anything in an iframe is bridge-less by design.

## Tests
- JVM: `cd targets/android/app && ./gradlew :app:testDebugUnitTest --tests dev.omalauncher.shell.ShellOriginTest`
- Live: `tools/phone/bridge-check.sh [page]` (home by default; lock, shade, assist...). Over CDP it adds 0x0 probe
  iframes (srcdoc, about:blank, sandboxed, data:) that each try one harmless apps.list call. Exit 0 = top frame
  has the bridge and no probe could use it; 1 = leak or no bridge; 2 = couldn't run. It hangs while the phone
  dozes (WebView paused) - run only with screen Awake and idle>=120 (tools/phone/idle.sh); never wake the phone.
- After any ship: `tools/phone/adb.sh shell "logcat -d -v time | grep 'refused a message'"` should be empty in
  normal use; a hit from the top frame at https://shell.powos means the check broke the shell itself.
