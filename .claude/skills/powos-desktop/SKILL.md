---
name: powos-desktop
description: Use when building, fixing, testing or shipping the PowOS desktop shell - powos-shell (sources/powos-shell, the Qt/QtWebEngine/LayerShellQt host), its desktop bridge (shell/hosts/desktop.ts, layout.ts), the desktop home (mode=desktop, shell/ui/desktop.tsx/.css), on the phone's Plasma session or x86 Plasma.
---

The plan, the bridge table and what's shared: docs/DESKTOP-SHELL.md. The phone's rules: docs/AGENT-HANDBOOK.md.

## How it fits
- powos-shell (C++/Qt 6): one QWebEngineView per role per screen, made a layer surface by LayerShellQt (src/view.*:
  ShellView; src/home.*: the home; src/panel.*: phase 0's bar, not started by default). Serves shell/ on
  powos://shell/ (base $POWOS_SHELL_DIR, overrides ~/.config/powos/shell, hot reload), _app/<id>/ from
  ~/.local/share/powos/apps/<id>/current/ui, _font/symbols through fontconfig, icons on powos://icon/.
- Home: bottom layer, every edge, exclusive zone 0, keyboard on demand, scope "dock" (KWin: a special window: not
  a task, not an Android task, blurred). The background layer shares KWin's desktop layer with plasmashell's window.
  POWOS_HOME_LAYER=background / POWOS_HOME_SCOPE=... try others.
- Bridge (src/bridge.cpp): the phone's contract, PowosHost.call(id, method, argsJson) over QWebChannel, plus the native
  port (PowosNative + MessagePort): b.hello -> b.state, b.r -> KWindowEffects::enableBlurBehind (KWin 6.7:
  ext_background_effect_v1; the capability arrives ~0.5 s late, so a "no" is re-asked - HACK). Natively: apps (KSycoca,
  ApplicationLauncherJob), windows (TasksModel), store (~/.local/share/powos/shell-data, the phone's names), theme
  (~/.local/state/omarchy/current/theme/colors.toml, mapped as ui/Theme.kt), ai (`powos manager --once-stdin
  --json-events`, items kept in store desktop-chat).
- In the page (shell/hosts/desktop.ts, picked when PowosHost.name === "powos"): home layout + recents over the store
  (hosts/layout.ts, shared with the mock), keyboard/speech/widget screens as no-ops.
- STDB: the page's own ws://127.0.0.1:3410 (shell/apps/stdb.ts), unchanged. One failed first connect per database at
  start, then connected: not a loop. The page's fetch() to STDB's HTTP fails from powos: (CORS): no evidence of anything.

## On the phone (KWin on the Anland backend, rooted session)
    sources/powos-shell/dev/phone.sh build          # this tree -> built on the phone (~20 s), /usr/lib/powos/desktop-shell
    sources/powos-shell/dev/phone.sh start|stop|status   # status: RSS + CPU ticks per process (host, zygotes, renderer)
    sources/powos-shell/dev/phone.sh cdp 'JS'       # evaluate in the desktop page (DevTools on 127.0.0.1:9333, dev runs only)
    sources/powos-shell/dev/phone.sh page NAME      # Chromium's render -> /home/powos/design-qa/desktop-NAME.png
    sources/powos-shell/dev/phone.sh shot NAME      # KWin's capture (spectacle)
- The phone's Qt is 6.12 with QtWebEngine 6.11, which works (measured). Install nothing: units/phone/powos-desktop-shell.json.
- While the "PowOS" activity isn't in front, the session is frozen: KWin sends no frame callbacks, a newly started
  surface never commits, and KWin's capture shows the last painted frame (Plasma's clock stuck, ghosts of closed
  windows: deleted=true in stackingOrder). Report it; never unfreeze it or bring the activity up yourself. Android's
  screencap of the activity then shows only the wallpaper (Plasma's own panel isn't in it either).
- KWin scripts for window facts (workspace.stackingOrder: caption, resourceClass, dock, deleted, frameGeometry); their
  print() lands in /run/powos-app/hyprland.log (KWin's stdout, read via tools/phone/user.sh). Never call
  org.kde.KWin showDebugConsole: it opens a window on the desktop.
- Rest cost, measured 2026-10-21 over 60 s settled: host 3 ticks, renderer 0, zygotes 0; ~250 + 230 + 145 MB RSS.

## Renders and checks
- shell/dev/gate.sh boots mode=desktop with the other pages, idle check included.
- `SHOTS_ONLY='^desktop' shell/dev/gate.sh --tree --shots DIR --wallpaper FILE`: desktop, desktop-launcher,
  desktop-chat at plasma (558x1198) and laptop (1280x800) sizes; report.json has contrast per text.
  Use the phone's real wallpaper too, not only the light fallback. The desktop scenes drop the launcher's transform
  and will-change, else the emulated backdrop blur never reaches the wallpaper (an unblurred render under-states
  contrast). SHOTS_PROBE='JS' prints a value per shot (e.g. 404s from performance entries). Islands show their fault
  tile headless (no STDB); real island data only from `dev/phone.sh page`.
  Headless-only errors: STDB refused (no STDB in the container), /_font/symbols 404 (the mock doesn't serve it).
- The launcher on the desktop has a deeper dim (tint + 42%, desktop.css), measured with the blur emulated: the
  reference fill left 54 of 67 labels under 4.5:1 over a light wallpaper. Contrast wins over the reference look;
  re-measure (both wallpapers, three themes) before changing it.
- host.net (src/net.cpp, apps/net.ts's n.req over the native port) mirrors ShellNet.kt. Its secrets and pins are
  the desktop's own (~/.local/share/powos/net): Lights shows "no secret hue" until it's paired here or the key is
  brought over (the user's call - never pair or switch a light yourself).
- Shell files ship as usual: commit, rebase, push, `READY_MS=30000 shell/push.sh --vpn --note "..." <files>`; the
  desktop host's own copy of shell/ only changes with dev/phone.sh build.

## Next
Global hotkey (KGlobalAccel), dictation (GPU box STT), the phone's theme mirrored into the rooted session (Android
app, Omarchy current/theme), a desktop widget picker, agents' mail into the page, x86 Plasma (image-build.sh), a user
unit for autostart with powos-desktop-shell as its switch, an input region so clicks off the tiles reach Plasma's desktop,
OWL widgets (weather, sysinfo) once the engine's JS port exists.
