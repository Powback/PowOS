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

## Shade and notifications (shell/ui/notifications.tsx, notifications.css, shell.css .notif-*)
- Grouping `grouped()`: conversations (`conversation`) on top, then one stack per app (`group` key; PowOS's own by
  sender, deploy = "PowOS · updates"); host fields pkg/group/conversation (ShellBridge.notificationJson), typed locally
  (`GroupedNotification`) so it checks against an older APK. A stack: newest + "+N" + 2 peeking cards; tap unfolds in
  place (grid-template-rows 0fr->1fr), swipe folded = whole group. PowOS's own carry icons/powos.svg.
- Open: TOP-aligned, newest first (a bottom-aligned brief was corrected the same hour). Pulling OPEN only (`riding`,
  decided per pull, cleared 320 ms after settling): `.notif-items`/`.cc` translateY(min((1 - --q) * --ph, --free)) =
  list top min(sheet bottom - height, its resting top), continuous; --free/--ph measured by ResizeObserver, never per
  frame. Closing: no ride, it goes up with the sheet. The control center rides the same way.
- Home's in-page panel is being removed (the shade window everywhere): work in ?mode=shade.

## Control center (shell/ui/control.tsx)
- `GROUPS`: the user's curated eight (internet, connect, display, eye comfort, focus, battery, capture, tools); the
  first member is the tap; `LEFT_OUT` (lock, remote input, Link to Windows, OnePlus Share when Google's is there);
  anything unnamed falls into tools. Members: tile id, `app:<pkg>` for custom tiles, `a|b` = first present.
- A category opens inline (`Unfold` under its row), its members one sideways-scrolling snapping row (`.cc-subs`,
  excluded from the panel's sideways switch in gesture.ts via inStrip). Single members: no chevron.
- The live phone's tiles: read `powos.qs.state()` over CDP - the mock (bridge.ts) lacked the real custom tiles once and
  the review images were wrong; keep the mock in step with `settings get secure sysui_qs_tiles`.

## Render, check, ship
- Targeted renders: run the gate's container on shell/dev/shots.mjs with SHOTS_ONLY=<regex> (scenes listed at its
  top; SHOTS_SCALE=2 for readable crops, SHOTS_PROBE='<js>' to print page state, SHOTS_GLASS=native|page). Output PNGs
  + report.json (each text's contrast vs the rendered pixels). Whole sweep: `shell/dev/gate.sh --tree --shots DIR
  --wallpaper FILE`. Contact sheet: shell/dev/sheet.mjs (/a before, /b after).
- Headless isn't the device: verify layout on the phone over CDP (render the component offscreen in the live home
  WebView, read computed display/rects) - a drawer strip once passed headless and broke on the device.
- Style lint (in the gate): raw colours, coloured borders, shadows outside tokens fail; exceptions in style-allow.txt.
- Gate base = the installed APK's own shell + the phone's overrides + your files; READY_MS=15000 when the Mac is loaded.
- Phone: dual display, screencap needs `-d 4630946316123810436` (cover); idle.sh --wait for a window; review images to
  /home/powos/design-qa/ (chown 10359:10359) before each push.
