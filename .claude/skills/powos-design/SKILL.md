---
name: powos-design
description: How the PowOS phone shell's design is built and checked - the design language, the glass material, the shade/notifications and control center internals, the headless render + contrast harness, and the pitfalls already hit. Load before any visual change or design QA on shell/.
---

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
- Open: short `--drop` (15vh) + cascade (`.cascade`, `--i` row index; CC rows first). Grouping `grouped()`; stacks.
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
