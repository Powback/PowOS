---
name: powos-desktop
description: Use when building, fixing, testing or shipping the PowOS desktop shell - powos-shell (sources/powos-shell, the Qt/QtWebEngine/LayerShellQt host), its desktop bridge (shell/hosts/desktop.ts, layout.ts), the desktop home (mode=desktop, shell/ui/desktop.tsx/.css), on the phone's Plasma session or x86 Plasma.
---

**Paused by the user, 2026-10-22:** no work on the separate Plasma desktop (powos-shell); the desktop is the PowOS
home unfolded / widescreen. powos-desktop-shell is disabled on the phone; the code stays.

## The desktop now (2026-10-22)
- The desktop is the PowOS home unfolded/widescreen, with Android apps as floating windows. The windows side
  (taskbar, focus/minimise/close, Android windows, switcher) belongs to the switcher skill (powos-switcher).
- Wide home = shell/hosts/wide.ts, wrapped around the phone's bridge (bridge.ts) for home's page only (no ?mode=),
  at >= 700 CSS px (inner display 821, cover 404). Two host pages are shown side by side as one page of cols*2+1
  columns, with a free column between them so they never merge across the seam. Cells map both ways at the bridge
  (right page x+cols+1; a move goes back to the half its middle is over), widgets.page maps to the pair's left page
  (the host keeps a page's neighbours live), and fold/unfold emits home.changed. ShellHome.kt's GRID_COLUMNS (6) is
  one layout for both screens, so never persist wide cells.
- The wide pill (width min(560px, 100% - 2*edge)) and the centred dock are the @media (min-width: 700px) block at the
  end of ui/shell.css. The pill's height is the drawer skill's.
- Merging touching tiles: grid.tsx joins() joins only whole covered edges (widgets skill, fixed 2026-10-22). On
  mode=desktop joins() returns nothing.
- "Flat grey slabs" on the inner display are not missing blur: the user's wallpaper is pure black in its top third,
  behind the tiles, and a frost of black is black. Blur regions are sent (glass-native, __glass.live.counts).
- The monospace font is the theme's own --font, the same folded and unfolded. It is not a load failure.
- The ">" dock icon is Konsole's real icon. Chrome's and Camera's white plates are their Android icons.

## Plasma as an app + the web launcher's Linux backend (plan: docs/DESKTOP-WEB-SHELL.md, last section)
- Drawer "Plasma" = l:org.powos.plasma (session/plasma/org.powos.plasma.desktop, OnlyShowIn=X-PowOS so Kickoff hides
  it; the export accepts X-PowOS). Exec powos-plasma = PLASMA_COMMAND: Runtime.launch -> showDesktop() (MainActivity).
- Linux list: powos-apps-export (KService's rules over XDG dirs) -> run/powos-apps. powos-apps-watch (autostart;
  dbus-monitor on org.kde.KSycoca.notifyDatabaseChanged, kded6 -> kbuildsycoca6) reruns it; the app's FileObserver on
  icons/.icon-names (MOVED_TO, the export's last step) -> refreshApps(export=false). Unit android-apps. Launch: powos-open-task.
- Check: verify/plasma-app.sh (watcher idle, entry, emitted signal -> new export, apps.list, apps.launch -> MainActivity).

## Shot checks (shell/dev/shots.mjs, after each scene)
- Errors per shot: overlapping tiles (>1 px), partial joins, uneven gutters on mode=desktop, missing glyphs.
  SHOTS_STRICT=1 fails the run and gate.sh --shots. gate.sh mounts the real nerd_symbols.ttf. Output dirs under $HOME.

## Paused Plasma host: what's left on the phone
- Off: ~/.config/powos/desktop-shell.off (autostart start --auto then does nothing); unified sleep freezes its tree.
- Left data: shell-data/desktop-*, ~/.local/share/powos/net (Hue key copy; net-secret.sh remove), desktop-wallpaper.jpg
  and Omarchy current/theme from `dev/phone.sh wallpaper|theme` (HACK row dev/phone.sh; fix: the app writes them).
- dev/phone.sh render NAME WxH: off-screen second powos-shell (own profile, --disable-gpu), fresh frame when frozen.

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
- QtWebEngine draws classic scrollbars (the phone's WebView overlays its own): desktop.css hides them, scrolling stays.
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
  the desktop's own (~/.local/share/powos/net, 0600, key "<app>/<name>"). On the phone the Hue key was copied from
  the Android app's store with the user's say (2026-10-21), root-side and never printed:
      sources/powos-shell/dev/net-secret.sh copy local.lights hue      # -> "copied"
      sources/powos-shell/dev/net-secret.sh remove local.lights hue    # the way back -> "removed"
  Lights then loads its rooms and scenes. Never pair, switch, toggle or dim a light yourself; read state only.
- Shell files ship as usual: commit, rebase, push, `READY_MS=30000 shell/push.sh --vpn --note "..." <files>`; the
  desktop host's own copy of shell/ only changes with dev/phone.sh build.

## Next
Plasma backend slices 2-4 (Linux windows floating on home pages, Plasma notifications incl. KDE Connect in the shade,
clipboard). Paused host: hotkey, dictation, theme mirror, widget picker, x86 Plasma, input region, OWL widgets.
