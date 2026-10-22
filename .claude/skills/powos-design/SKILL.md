---
name: powos-design
description: How the PowOS phone shell's design is built and checked - the design language, the glass material, the shade/notifications and control center internals, the headless render + contrast harness, and the pitfalls already hit. Load before any visual change or design QA on shell/.
---

# PowOS shell design: what's known

## The material (docs/DESIGN-LANGUAGE.md is the spec)
- One material: `.tile` = `--glass-fill` (= `--text-fill`, the reference: PowOS AI's page at 912a284+3b9b5a3) over
  `--glass-veil`, `--lift` (top edge + shadow, no ring). Inside a surface only `--soft-fill`. Sheets `.tile.sheet`, the
  one text field `.tile.pill` (home search = AI compose, shell.css `.pill`). No borders, no dividers, no page dims.
- Secondary text: `--color-muted` = the theme fg at `--muted-text` (88%), set in app.tsx applyTheme - never the
  theme's own grey (measured 1.5-3.7:1). Labels on the wallpaper: `--label-shadow`.
- Home's blur is the native compositor (ui/nativeglass.ts regions, native-blur's). The in-page model (the page drawing
  the wallpaper + CSS backdrop-filter) was reverted: system.glass gave no picture on OxygenOS (screenshot file 0 bytes,
  mirror black). Don't retry it without a phone screencap the manager approves.
- Assist (mode=assist) is the exception: the screen 1:1, its panel solid, no glass.

## Frost (PowOS AI, its pull-up panel, the control center: shell.css "frost v2", theme.css --frost-*)
- One material: the compositor's blur per surface (nativeglass.ts reads `--glass-blur-native` per element; 360 on
  these, 140 elsewhere; the shade window's radius is the page's: `powos.shade.blur(dp)` in shade.tsx), a cool tint
  (`--frost-base`/`--frost-fill`) at the reference strength. Over the OTHER tone of wallpaper it flips to that tone
  (light glass + `--frost-ink` text) - never a heavier fill (an 84% fill read as "brown slab" and was rejected).
- No text halos (read as highlighter on a light wallpaper). Labels on raw wallpaper = small frost pills with
  `--lift-edge`. Inside the frost, secondary text is the ink itself, not a see-through grey.
- Over pure black the blur is black: keep the glass visible with the sheen + lit edge (`--frost-sheen`).

## Shade (ui/shade.tsx, notifications.tsx NotificationPanel)
- One panel by default: control center on top, notifications under it, one `.notif-list` scroll; Settings > Style >
  "separate notifications & controls" (`separatePanels`) restores the split; shade.tsx maps the host's "control" pull.
- Open: short `--drop` (15vh) + cascade (`.cascade`, `--i` row index; CC rows first). Grouping `grouped()`; stacks.

## Control center (ui/control.tsx; v3 = `Controls`, classic = `Categories`, flag `ccV3` key "ccLayout")
- v3: ONE ordered list of toggles (`list`): first six = the first pull's row, a further pull (ccexpand.ts, rubber band
  then commit, `ccExpanded`) only reveals the rest below - the row must not move (gate asserts it). No categories.
- Order: curated (QUICK, then the rest) unless `ownOrder()`: a v3 edit (`v3: true` in controls.layout) or a classic
  arrangement with a net move. Only drags write controls.layout; never reset it without the user saying so.
- Long press = the toggle's own page (cancelled once the finger moves); rearranging = edit mode via the header pencil
  (`ccEditing`), then a long press lifts (ui/reorder.ts, `onlyEditing`). Accent only on toggles that are on.
- ui/reorder.ts (shared, widgets expert reviews): hit-test on container-relative laid-out boxes (FLIP cancelled first),
  live order in a ref, cancel drops the lift. Home's grid.tsx is the widgets expert's - don't edit it.
- Gate `cc-reorder` (gate.mjs) waits on states, never time; prove with `CC_THROTTLE=6` x20.

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
- Gate base = the installed APK's own shell + the phone's overrides + your files (handbook Shipping); READY_MS=30000
  when the Mac is loaded. shell.css/theme.css are shared: push only origin's tip versions.
- Device checks: `tools/phone/verify/queue.sh add <board-task> <script>` and end the turn (never wait on the phone).
  Read-only CDP (`tools/phone/cdp.sh eval shade '<js>'`) for state; screencaps only in a queued window. Folded vs
  unfolded: read the size from `dumpsys window displays` (cur=WxH). Injected swipes must never launch apps (a page
  swipe at 60% height opened Calculator unfolded); a drag starting on a toggle used to open its settings.
- Verify lock (~/.cache/powos-verify.lock): take it only after the window is free, only for the injected part; never
  delete one you don't hold. adb.sh pull needs an existing destination dir.
- Review images: `tools/phone/review-image.sh FILE...` (-> /home/powos/design-qa/); mocks only for new screens.
- Push notes are user-visible (shade + AI feed): plain words, never "x". Gate under load: READY_MS=60000.
