# The desktop shell: the phone's shell/ on Plasma

> **Resumed by the user, 2026-10-26:** PC desktop development and Plasma-on-Android integration are both in scope.
> The separate Plasma host (powos-shell) remains disabled on the phone until explicitly enabled. Android's unfolded
> home and Plasma keep the independent window ownership described in `docs/DESKTOP-NATIVE.md`.
>
> **UI direction, 2026-10-26:** the user wants the web version only, including the top status bar, title bars and
> window controls. The host-owned bars described below are the current implementation, not the requested end state.
> Their migration to shared web UI is still pending.


Goal: one codebase for a widget or a PowOS app on the phone and on the desktop. The desktop runs the same `shell/`
(theme tokens, glass, widgets, PowOS apps' islands, PowOS AI's chat, the pet) as a native Plasma surface, not a
browser tab. It is added to Plasma and can be switched off; it replaces nothing. The research behind it, and the
longer road (replacing plasmashell), is `docs/DESKTOP-WEB-SHELL.md`.

## Host: powos-shell (Qt 6 + QtWebEngine + LayerShellQt)

`sources/powos-shell/` is a small C++ process. Each role is a `QWebEngineView` that LayerShellQt turns into a
`zwlr_layer_shell_v1` surface, one per screen. It serves `shell/` on `powos://shell/`, with the user's overrides in
`~/.config/powos/shell/` (hot reload).

- **Why QtWebEngine**: it is Chromium, the engine family of the phone's WebView, so the CSS and JS render the same
  in both places. It is also Qt, so LayerShellQt, KF6, QWebChannel and KWindowEffects come with it. WebKitGTK would
  be a second engine to test against. Measured on the phone (2026-10-21): QtWebEngine 6.11 runs fine against
  Qt 6.12, with ~250 MB RSS for the host, 230 MB for the renderer and ~145 MB for the zygotes, the GPU in-process.
- **home** role (the default): index.html?mode=desktop on the **bottom** layer, anchored to every edge, exclusive
  zone 0. It sits over plasmashell's desktop window and its wallpaper, under every window, inside Plasma's panel.
  KWin puts the *background* layer in the same stacking layer as plasmashell's desktop window, so a background
  surface could end up under it. Its scope is `dock`, which KWin treats as a special window: it is not in the task
  list, it is not made into an Android task on the phone, and KWin blurs behind it. The keyboard goes to it only
  when you click into it.
- **panel** role (phase 0, not started by default): a bar that replaces Plasma's panel, for later.
- **Switch**: `powos-desktop-shell start|stop|status` (installed next to the binary). When it stops, Plasma's desktop
  is back as it was. On the phone: `sources/powos-shell/dev/phone.sh build|start|stop|status|shot NAME`.

## One bridge, two hosts

The page talks to `powos.*` (types.ts `Bridge`) over the transport the phone already uses: `PowosHost.call(id,
method, argsJson)`, answered through `window.__powosHost.resolve/reject/emit`. On the desktop that runs over
QWebChannel. Glass also runs over the phone's native port (`PowosNative` with a MessagePort, `apps/native.ts`). The
Android bridge is untouched. bridge.ts picks `desktop(native(host))` when `PowosHost.name === "powos"`.

| area | desktop host | where |
|---|---|---|
| apps.list / launch | `.desktop` files over KSycoca; `KIO::ApplicationLauncherJob` (app scope, xdg-activation) | C++ |
| usage.recent | the apps launched from home, kept in the store | page (hosts/desktop.ts) |
| home.* (layout) | the same layout code as the browser mock, kept in the store (`desktop-home`) | page (hosts/layout.ts) |
| store.get / set | `~/.local/share/powos/shell-data/<name>.json`: the same names and contents as the phone | C++ |
| theme.get / theme.changed | Omarchy's `~/.local/state/omarchy/current/theme/colors.toml`, mapped the way the phone maps it, watched | C++ |
| ai.chat / send / ai.changed | `powos manager --once-stdin --json-events`, one turn per ask, streamed into the chat items | C++ |
| glass (`b.hello`, `b.r`) | KWin blur behind the rects the page reports (`KWindowEffects::enableBlurBehind`, which KWin 6.7 serves as `ext_background_effect_v1`; its capability arrives ~0.5 s late, so a "no" is asked again, a `HACK:`) | C++ |
| host.net (islands' devices: `n.req` fetch/events/mdns/secret/forget) | QtNetwork as ShellNet.kt: the manifest's `net` scope, LAN certificates pinned on first use, secrets kept in `~/.local/share/powos/net` (0600), mDNS through avahi-browse. Its secrets are the desktop's own (a Hue key captured on the phone's Android side isn't here) | C++ |
| islands (SpacetimeDB) | the page's own WebSocket to `ws://127.0.0.1:3410`; apps' UIs on `powos://shell/_app/<id>/` | page + C++ |
| windows.* | TasksModel (the panel's) | C++ |
| `_font/symbols` | the terminals' Nerd Font symbols, through fontconfig | C++ |
| keyboard, widget screens, speech | no-ops for now: the desktop has a hardware keyboard and no OWL engine; dictation comes in round 2 | page |

## Shared and host-specific

- **Shared, unchanged**: theme.css, shell.css, glass (nativeglass.ts: the page reports its surfaces, and the
  compositor blurs the wallpaper under them; SurfaceFlinger on the phone, KWin on the desktop), the grid (pointer
  and touch, resize from the corner), PowOS apps' islands, the pill, the launcher and the chat (one conversation),
  the pet.
- **Desktop-only, small**: `ui/desktop.tsx` (home's parts without the dock, the side pages, the switcher and the
  shade, because Plasma keeps its own), `ui/desktop.css` (the pill and the launcher as a centred column, no mic,
  and a darker fill under the launcher's text: tint + 42%, measured to reach 4.5:1), and `hosts/desktop.ts`.
- **Not on the desktop yet**: OWL widgets. They need the OWL engine's Kotlin Multiplatform JS port
  (`shell/DESIGN.md`). Until then the desktop's catalogue is the shell's own panels plus the PowOS apps' islands.
  Android's widgets will not come to the desktop.

## Perf and checks

- Desktop browser visual review, 2026-10-26: the recent-app row clipped its first icons off the left edge when no
  apps were pinned. `desktop.css` now sizes that row to its content with a viewport minimum and safe centering.
  Screenshots at 558x1198 and 1280x800 show all six recent icons centered and visible. Type checking and the two
  desktop startup tests pass. The isolated renderer has no SpacetimeDB service, so Lights and Shopping show connection
  errors; these renders do not validate their live integration or the pending web status/window bars.
- Emulator review, 2026-10-26: page switching previously ignored the final touch/mouse release coordinates when
  WebView coalesced moves. `gesture.ts` now uses that position before settling; the `desktops` browser regression
  fails against the previous implementation for both input types. Android also cancelled the DOM swipe when an
  incoming task took window focus, even though native touch delivery continued. `HomeWebView` defers that focus-loss
  notification until release or cancellation; `float-desktops.sh` requires a real `touchend`, so an accidental flick
  on cancellation cannot count as a pass. Device checks cover desktop ownership and
  restart persistence (`float-desktops.sh`), touch isolation (`float-touch.sh`), live resizing (`window-chrome.sh`),
  and notification expansion (`shade-overpull.sh`). The touch-isolation and shade checks now account for the emulator's
  lack of OnePlus hinge states and the wide shade's side-by-side layout, respectively.
- Emulator setup repairs `/system/xbin` traversal on old snapshots and applies the existing caption overlay through
  adb root. The app's own root helper remains unreliable on this non-Magisk image; `run-as ... su` succeeding is not
  proof of app-process root access. Captures after the overlay show one title bar. This does not validate the rooted
  Linux/Plasma session or replace native PC testing. The PC shell's browser gate, type checking and startup tests pass.
- To check unlanded emulator setup changes, run queued checks with `QUEUE_NO_TREE=1 EMU_COMMIT=$(git rev-parse HEAD) tools/phone/verify/queue.sh run-emu`; the default runner uses origin's setup scripts even when a local APK commit is selected.
- `cd shell && npm run test:desktop` (Node 22.18+) checks the native host's asynchronous startup without a device:
  early resizes must preserve the saved layout, and early launches must preserve recent-app history.
- 0 frames at rest, the same rule as the phone. Measured on the phone over 60 s once settled: host 3 ticks,
  renderer 0, zygotes 0, no running animations, glass measured only at start. Check it with
  `powos-desktop-shell status` (CPU ticks per process) and `dev/phone.sh cdp`.
- `shell/dev/gate.sh` boots `mode=desktop` with the rest (its idle check included). `gate.sh --shots DIR` renders
  `desktop`, `desktop-launcher` and `desktop-chat` at the phone's Plasma size (558x1198) and at 1280x800.
- Captures on the phone: `dev/phone.sh page NAME` is Chromium's render of the page (no compositor), and
  `dev/phone.sh shot NAME` is KWin's own (spectacle). While the "PowOS" activity is not in front, the session is
  frozen and KWin's capture shows its last painted frame, not the desktop as it is now.

## Round 2

A global hotkey (KGlobalAccel, Meta+Space), dictation (the GPU box's STT), the phone's theme copied into the rooted
session (the Android app writes Omarchy's `current/theme` there as it does for proot), a desktop-sized widget picker,
the agents' mail into the page, x86 Plasma (the same build, `image-build.sh`), and autostart as a user unit with
`powos-desktop-shell` as its switch.
