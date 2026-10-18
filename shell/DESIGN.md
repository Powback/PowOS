# PowOS shell — the launcher as a web UI

One UI for the phone's launcher (Omalauncher) and, later, PowOS's desktop shell (replacing plasmashell), made of
plain files that change at runtime: edit a file — by hand or by an agent — and the shell reloads it in place. No
APK, no package, no build.

## Why

The Compose launcher is ~27k lines of Kotlin; every change is a Gradle build and an APK install. The goal is a fully
AI-customizable launcher and OS: everything visual and behavioural has to be editable data and code on the device.
A web UI is that already — and it runs on both targets, so the phone's launcher and PowOS's desktop become one
codebase.

## Stack: no build step

- **Preact + htm + @preact/signals**, as native ES modules through an import map (`vendor/`, vendored, nothing
  fetched at runtime). `htm` is JSX in tagged templates, so there's nothing to compile: a file saved is a file run.
- No bundler, no TypeScript compile. Types are JSDoc, checked in an editor if wanted; `bridge.d.ts` documents the
  host API.
- CSS is plain CSS with custom properties: the theme (Omarchy's colors.toml) is a set of `--color-*` variables.

Not Astro (a content-site framework: build step, server rendering — a launcher has neither), not Svelte/Solid/JSX
(each needs a compiler between an edit and the screen).

## Layout

```
shell/
  index.html          import map, theme stylesheet, mounts app.js
  app.js              the shell: home, the bar, the drawer, overlays
  bridge.js           window.powos (the host's), or a mock in a desktop browser
  bridge.d.ts         the host API, the one contract between UI and native
  hot.js              hot reload: modules and stylesheets swapped as files change
  theme.css           tokens (--color-*, --gap, --radius) + base styles
  ui/                 components: drawer, home grid, dock, recent strip, A-Z bar, ...
  vendor/             preact, htm, signals (pinned versions)
  data/               layout.json, pins, settings — the user's, written through the bridge
```

## The bridge: `window.powos`

Native code shrinks to a small, stable API (async calls + events), the same shape on both hosts:

| area | calls | events |
|---|---|---|
| apps | `apps.list()`, `apps.launch(key)`, `apps.icon(key)` (URL), `apps.info(key)`, `apps.uninstall(key)` | `apps.changed` |
| usage | `usage.recent(n)`, `usage.record(key)` | |
| store | `store.get(name)`, `store.set(name, json)` — the shell's own data files | |
| keyboard | `keyboard.show()`, `keyboard.hide()` | `keyboard.inset` (px, per frame) |
| system | `system.insets()`, `system.wallpaper()`, `system.openSettings(what)` | `system.insets` |
| terminal | `term.open(cmd?)` → pty id; `term.write(id, data)`, `term.resize(id, cols, rows)` | `term.data` (drawn by xterm.js) |
| windows | `windows.embed(id, rect)` — a native Linux window placed over the page at a rect the page reports | |
| widgets | everything OWL widgets call today (`WidgetServices`): battery, media, volume, notifications, alarm, torch, haptic, share, url, terminal, … | per-service |
| files | `files.watch()` — the hot-reload feed | `files.changed` |

The phone implements it with an Android `WebView` + `@JavascriptInterface` / `WebMessagePort`; PowOS with a small
native host (QtWebEngine or WPE in a layer-shell surface, under KWin). The page doesn't know which.

## OWL widgets: the store keeps working

The widget language stays the one source of truth: the `owl` module (pure Kotlin, ~3.5k lines; only java.time,
Base64 and Locale from the JDK) becomes Kotlin Multiplatform with a JS target behind small `expect`/`actual` shims.
Its JS build (`vendor/owl.js`, an ES module) parses and evaluates widgets in the page; a Preact renderer
(`ui/owl/`) draws their nodes (Text, Row, Column, Canvas, Terminal, Input, Slider, …) as `Render.kt` does in
Compose. Host services go through the bridge's `widgets` area. The marketplace, its CI (`owl check`) and every
published widget are unchanged.

This is the one compiled piece, and it's the engine, not the UI: users and agents edit widgets (OWL) and the shell
(JS/CSS), never the interpreter.

## Hot reload

The host watches `shell/` (and the user's override folder, see below) and sends `files.changed` with the path.
`hot.js` swaps a stylesheet in place, re-imports a changed module with a cache-busting query and re-renders from the
root (signals keep state, since they live in modules that didn't change); a change to `app.js` or `index.html`
reloads the page, restoring the open screen from `data/`.

Overrides: a user/agent copy of any file in `~/.config/powos/shell/` wins over the shipped one, so updates don't
clobber customizations and "reset" is deleting the override.

## Native seams that stay native

- Embedded Linux windows (foot, PowOS apps in tiles): native views over the page at rects it reports.
- The soft keyboard and its inset (the page lays out from the inset events).
- Gestures the system owns (back, home); everything else is the page's (pointer events).
- The Andromarchy engine, the PowOS session, Wayland — untouched.

## Phases

1. **Scaffold** (this): `shell/` with the stack, theme tokens, the mock bridge, hot reload; drawer (A-Z, dock,
   recent) and the bar, runnable in a desktop browser against the mock.
2. **Android host**: a `WebView` launcher activity behind a setting (the Compose launcher stays default until parity),
   serving `shell/` from app files, with the bridge's apps/usage/store/keyboard/system areas.
3. **Home**: the page grid, edit mode (move/resize/drag from the drawer), folders.
4. **OWL**: owl → Kotlin Multiplatform + JS; the Preact renderer; widget services over the bridge; the store screen.
5. **Terminal and windows**: xterm.js over the pty bridge; embedded Linux windows.
6. **Parity and switch**: settings, style/themes, agents, files; the WebView launcher becomes default; Compose UI
   removed.
7. **PowOS**: the same `shell/` as the desktop shell under KWin (layer-shell host), replacing plasmashell.

## Working on it

- **In a browser**, against the mock bridge: `cd shell && python3 -m http.server`, open it at phone size in the
  browser's device mode.
- **On the phone**: the app's "PowOS Shell (preview)" entry (`dev.omalauncher.shell.ShellActivity`). Edit live with
  `shell/push.sh <file>...` - it lands in the app's override folder (`files/shell`) and the shell hot-reloads it;
  `shell/push.sh --reset` drops the overrides. The WebView is debuggable: `adb forward tcp:9333
  localabstract:webview_devtools_remote_<pid>`, then Chrome's devtools (or Playwright `connectOverCDP`) on it.
- A LAN dev server instead of the shipped files: put its URL in the app's `files/shell-dev-url`.

Note: a WebView behind the lock screen doesn't navigate - a reload (and so a hot reload of a module) happens when
the screen is back on.

## Status

- Phase 1 done: the scaffold, runnable in a browser.
- Phase 2 done: `ShellActivity` + `ShellBridge` (apps, icons, usage, store, keyboard, insets, apps.changed,
  files.changed), verified on the phone over CDP: 49 apps, icons served, store round-trips, insets, the override
  folder served and watched. Not yet: Linux/PowOS apps in the list (the rooted session's apps come with phase 5).
- Phase 3 (home) mostly done: the same home as the Compose launcher through `home.*` (ShellHome.kt: its WidgetLayout
  cells and Shortcuts), laid out on its grid (as many rows as fit square cells, or as far down as tiles reach);
  pages with an empty one after the last; tap apps and folders; long-press lifts a tile and drags it (page turns at
  the sides), drop an app on an app or a folder to group them, select a widget to resize or remove it; drag an app
  out of the drawer onto home. Verified in a browser (mock) and over CDP on the phone (its real widgets and cells).
  Widgets show as named placeholders until phase 4 (OWL). Not yet: reordering inside an open folder, taking an app
  out of a folder.
