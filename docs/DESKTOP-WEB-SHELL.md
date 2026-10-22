# The web shell as the PowOS desktop shell

Status: research, 2026-10-19; **phase 0 built 2026-10-20** (`sources/powos-shell/`, `shell/ui/panel.tsx`; see "Phase 0:
what runs" at the end). This is phase 7 of `shell/DESIGN.md` ("the same `shell/` as the desktop shell under KWin,
replacing plasmashell"), worked out far enough to start.

Goal: the PowOS desktop's panel/taskbar, launcher, home with widgets, notifications, system tray, quick settings,
OSDs, lock-screen face and window overview are the web shell (`shell/`, Preact + TypeScript, hot-reloaded), the
same code the phone runs. They are *native*: real Wayland shell surfaces that KWin places, stacks and gives focus
to, the way plasmashell's are. They are not a browser window floating on top of Plasma.

The rule is the same as on the phone (`docs/NATIVE-SYSTEM-UI.md`): a thin native host holds the slot (its surface,
input, D-Bus names and privileges) and everything you see is `shell/`. If the host has to draw something, that
means a bridge call is missing. It does not mean we add a native view.

## TL;DR

- **Recommended: replace plasmashell with `powos-shell`.** This is a small C++/Qt 6 process. It hosts QtWebEngine
  pages in **LayerShellQt** (`zwlr_layer_shell_v1`) surfaces, one per role and per screen. It links KDE's own
  shell libraries (`libtaskmanager`, `libnotificationmanager`, KF6 Runner/Service/KIO, NetworkManagerQt, BluezQt,
  PulseAudioQt, libkscreen) and bridges them into the **same `PowosHost.call(id, method, argsJson)` contract the
  Android `ShellBridge.kt` already speaks**, so `bridge.ts` stays the same apart from its host name.
- **We keep the rest of Plasma:** KWin, kscreenlocker, powerdevil, kded (with its StatusNotifierWatcher), kglobalaccel,
  ksmserver, polkit-kde-agent, xdg-desktop-portal-kde, krunner's runners and System Settings. We replace only what
  lives *inside* plasmashell: the panel, desktop, wallpaper, notification server, OSD service, SNI host, launcher,
  and clipboard history (Klipper).
- **Engine: QtWebEngine.** It is Chromium, the same engine family as Android's WebView, so one codebase renders the
  same on both. It is also already Qt (LayerShellQt, KF6 and QWebChannel come for free), and it composites on the GPU.
- **One JS app, many surfaces.** The panel page opens the other roles with `window.open()`. The host's
  `QWebEnginePage::createWindow` puts each child page in its own layer surface. Every surface shares one renderer
  and one JS realm, so signals and state are shared, and Preact renders straight into each child's `document`.
- **Start it next to plasmashell (augment), then switch (replace).** The first step is one bottom panel layer
  surface that shows `shell/` with a live window list over `org_kde_plasma_window_management`. It runs beside a
  normal Plasma session, with plasmashell's own panel removed. That takes about 1 week. Full replacement with
  fallback to plasmashell takes about **3-4 months** for one developer, not counting the OWL→JS port that
  `shell/DESIGN.md` already plans.

## 1. Architecture options

### (a) Our own shell process: Qt host + web views in layer-shell surfaces ← recommended

`powos-shell` replaces `plasmashell` in the session. Each role is a `QWebEngineView` (or one `QQuickWindow` with a
`WebEngineView`). Before the window is shown, `LayerShellQt::Window::get(window)` is called and given a layer
(background/bottom/top/overlay), anchors, an exclusive zone, keyboard interactivity (none/exclusive/on_demand), a
scope (namespace) and a screen. KWin has implemented layer-shell since 5.20, and Plasma 6's own panels and OSDs
are Wayland shell surfaces of the same kind.

Why this option:

- It owns every role plasmashell owns, with the same native standing. KWin applies the panel's exclusive zone to
  maximized windows. Its stacking puts background below windows and overlays above them. It gives keyboard focus
  to the launcher.
- It is the phone's architecture: a native host that owns slots, plus one web codebase. The bridge transport is
  even the same (section 3).
- The libraries Plasma's own applets use are installed, and we can link them: `TaskManager::TasksModel`,
  `NotificationManager::Server`, `KRunner::RunnerManager` and the rest. We don't reimplement the window list,
  notification spec, job tracking or search. We put a web UI on top of the same models.
- The failure domain is our own process. A crash in it doesn't take down KWin, and systemd can fall back to
  plasmashell (section 3.7).

Tradeoffs: we must implement everything plasmashell owns on the session bus (section 2: `org.freedesktop.Notifications`,
`org.kde.osdService`, the SNI host, KSplash's "desktop" stage, `org.kde.PlasmaShell` calls). Panel niceties that
come from `org_kde_plasma_shell` (auto-hide through KWin screen edges, "windows can cover") need our own work.
The host also has to be built against each Plasma release, because `libtaskmanager` and `libnotificationmanager`
are installed but make no ABI promise. That is the same pinning we already do for `sources/kde/patches`.

Other engines considered:

| engine | for | against |
|---|---|---|
| **QtWebEngine** (Chromium) | Same engine as Android WebView. Qt-native: LayerShellQt, QWebChannel, KF6. GPU compositing. DevTools via `QTWEBENGINE_REMOTE_DEBUGGING` (Playwright `connectOverCDP`, the workflow the phone already uses). Ships in Fedora/Bazzite (`qt6-qtwebengine`) and Arch ARM | ~150-250 MB for browser + GPU + renderer processes. ~0.5-1 s cold start |
| WPE WebKit / WebKitGTK | Lighter, with an embedded focus. `gtk4-layer-shell` works with WebKitGTK | A second engine whose CSS/JS differs from the phone's. GTK+WebKit in a Qt session. WPE's platform API has no layer-shell role, so we would write the Wayland glue ourselves |
| CEF | What Steam's Big Picture / gaming mode UI uses (full screen on gamescope) | No Qt integration. Ozone-Wayland gives us xdg-toplevels, not layer surfaces, so we would use off-screen rendering + our own surfaces. Heavy |
| Servo | Embeddable, Rust | Not mature enough for a whole shell (web compatibility, IME, a11y) |

### (b) Keep plasmashell, run the web UI inside it

Options: a custom shell package (`org.powos.desktop`, a `Plasma/Shell` KPackage), a desktop containment, or a panel
applet whose QML is one `WebEngineView` with `webChannel`. QtWebEngine QML works in plasmashell. Plasma's own
`org.kde.plasma.webbrowser` applet does exactly this.

For: notifications, OSD, tray, Klipper and KSplash keep working, and panel behaviour (auto-hide, floating) comes
free. We could have this in days.

Against: each applet/containment is its own `WebEngineView`, which is hard to make one app with one state. The
layout is Plasma's panel/containment model, not ours, so `shell/` couldn't run unchanged. A QtWebEngine fault
(GPU process, renderer OOM) is a plasmashell crash. Plasma's applets still draw the tray, notifications and OSD
unless we write those as web applets too, and then we are rebuilding (a) inside a host that resists it. **This is a
fine experiment. It is not the destination.**

### (c) KWin scripting / effects plus a web overlay

KWin scripts (JS/QML, `/usr/share/kwin/scripts`) and declarative effects (QML) run inside the compositor. Putting
QtWebEngine into `kwin_wayland` means a renderer stall or crash takes down the session. KWin scripts are useful as
**helpers**: window rules, and reporting windows over D-Bus, which `targets/android/session/powos-open-task`
already does. Effects stay KWin's (Overview, Present Windows, Desktop Grid), triggered from the shell. **No for
the UI, yes as glue.**

### (d) References from other compositors

- **Quickshell** (Qt Quick + layer-shell) and **AGS/Astal** (GJS + gtk4-layer-shell, with service libraries
  `astal-notifd`, `astal-tray`, `astal-wireplumber`, `astal-network`, `astal-bluetooth`, `astal-mpris`): these prove
  the "own process, layer surfaces, own SNI host + notification server" model, and their service list is
  essentially section 2. Both lean on `zwlr_foreign_toplevel_management_v1` for the window list, which **KWin does
  not implement**. On KWin the window list is `org_kde_plasma_window_management`, which is why we link
  libtaskmanager.
- **eww / waybar**: declarative bars over layer-shell. Same surface model, but bar-only.
- **Firefox OS (B2G) Gaia's "system app"**: the closest precedent for a full web desktop shell. One web page owned
  all system chrome (status bar, notifications, lock screen, task switcher), with apps as separate processes it
  arranged. Lesson: one page or app holding all chrome state works. Here KWin keeps window management and we keep
  only the chrome.
- **Steam gaming mode**: a Chromium (CEF) UI as the whole session shell on gamescope, already on Bazzite. A web
  shell's performance at that scale is acceptable on this hardware.
- **Ubuntu Frame + WPE kiosk / Cog**: a web UI as the only client of a minimal compositor. That is a kiosk, not a
  shell (no third-party windows to manage).

## 2. What the shell must provide, and how

"Today" is who provides it in Plasma 6. "Ours" is what `powos-shell` talks to. "Bridge" is the area in `types.ts`
(new areas are marked *new*).

| Feature | Today (Plasma) | Ours: protocol / API | Bridge |
|---|---|---|---|
| Window list, taskbar | `libtaskmanager` in plasmashell's task manager applet, over **`org_kde_plasma_window_management`** (restricted, see 3.3) | Link `TaskManager::TasksModel` (grouping, pinned launchers, per-screen/desktop filters, `requestActivate`, `requestToggleMinimized`, `requestClose`, `requestVirtualDesktops`, `requestToggleMaximized`, app id → `.desktop`). PowOS's `001-taskbar-force-close.patch` behaviour moves into the host | *new* `windows.list/activate/minimize/close/move` + `windows.changed` (the existing `windows.embed` stays) |
| Window thumbnails | `zkde_screencast_unstable_v1` → PipeWire (`ScreencastingRequest`) | Phase 1: `org.kde.KWin.ScreenShot2` (D-Bus, restricted: `X-KDE-DBUS-Restricted-Interfaces`), a PNG served on `powos://thumb/<id>`. Later: live PipeWire frames drawn by a native surface at a rect the page reports | `windows.thumb(id)` |
| Virtual desktops | `org_kde_plasma_virtual_desktop_management` + `org.kde.KWin /VirtualDesktopManager` | `TaskManager::VirtualDesktopInfo` (wraps both): list, current, create/remove/rename | *new* `desktops.*` |
| Overview, present windows, desktop grid | KWin effects | Keep KWin's. Invoke through `org.kde.kglobalaccel /component/kwin invokeShortcut("Overview")` (also "Expose", "Grid View", "Show Desktop") | `windows.overview(kind)` |
| Launcher apps | Kickoff/Kicker (plasma-desktop, PowOS-patched on the phone) over KSycoca | `KService`/`KApplicationTrader` + `KSycoca::databaseChanged`. Launch through **`KIO::ApplicationLauncherJob`** (systemd `app-*.scope`, `xdg_activation_v1` token, startup feedback). Icons through `QIcon::fromTheme` on `powos://icon/<name>?s=` | `apps.*` (as on the phone, `kind: "linux"`) |
| Recent / frequent | KActivities Stats | `PlasmaActivitiesStats` (`ResultModel`, `agent:org.kde.plasma.favorites`, `applications:` used/linked) | `usage.recent` |
| Search | KRunner / Milou (the `krunner` process and D-Bus runners `org.kde.krunner1`) | Link `KRunner::RunnerManager` (KF6Runner) in the host: every runner, D-Bus ones included, with no second process. Leave `krunner` itself in place for Alt+Space | *new* `search.query/run` + `search.results` |
| Global shortcuts | `kglobalacceld` | Register actions as component `powos-shell` through `KGlobalAccel::setGlobalShortcut`. Meta-alone stays `kwinrc [ModifierOnlyShortcuts] Meta=org.kde.plasmashell,/PlasmaShell,org.kde.PlasmaShell,activateLauncherMenu`, which our host answers (next row) | `system.shortcut` event |
| `org.kde.plasmashell` D-Bus name | plasmashell: `/PlasmaShell` (`activateLauncherMenu`, `toggleDashboard`, `evaluateScript`, `showDesktop`), **`/org/kde/osdService`** | **Our host owns `org.kde.plasmashell`**, so KWin's Meta key, plasma-pa, powerdevil and kded keep calling us unchanged. Implement the methods we need, `evaluateScript` as a no-op | |
| OSDs (volume, brightness, mic, kbd layout, mode, ...) | `org.kde.osdService` in plasmashell (`volumeChanged`, `brightnessChanged`, `microphoneVolumeChanged`, `showText`, `kbdLayoutChanged`, `virtualDesktopChanged`, ...) | Same object on our `org.kde.plasmashell`. Each call becomes an event, and the page shows it in an overlay layer surface (no keyboard, no input region) | *new* `osd` event |
| Notifications | `libnotificationmanager` `Server` in plasmashell owns **`org.freedesktop.Notifications`**, plus `org.kde.JobViewServer` / `org.kde.kuiserver` (jobs) and inhibitions | Link `NotificationManager::Server` + `Notifications` model (history, groups, actions, inline reply, DnD, jobs). Since **one process owns the name**, this moves only when plasmashell goes. Before that, we read plasmashell's model (or watch through the same lib as a client) | `notifications.*` (same as the phone) + `notifications.action/reply` |
| System tray | plasmashell's systemtray applet is the **SNI host**. kded's `statusnotifierwatcher` is `org.kde.StatusNotifierWatcher` | Register `org.kde.StatusNotifierHost-<pid>`, call `RegisterStatusNotifierHost`, follow `StatusNotifierItemRegistered/Unregistered`, and read `org.kde.StatusNotifierItem` props (IconName/IconPixmap, ToolTip, Status, Menu). `Activate/SecondaryActivate/Scroll`. Menus over `com.canonical.dbusmenu` (libdbusmenu-qt6, sent to the page as JSON). The watcher stays kded's. Coexists with plasmashell (several hosts are allowed) | *new* `tray.*` |
| Audio | plasma-pa (`PulseAudioQt` on PipeWire-pulse) | `PulseAudioQt` (sinks/sources/streams, volume, mute, default device, per-app). MPRIS (`org.mpris.MediaPlayer2.*`) for media | `widgets` services volume/media, *new* `audio.*` |
| Network | plasma-nm (NetworkManagerQt + `kded6 networkmanagement` secret agent) | `NetworkManagerQt`. The kded module stays the secret agent, so Wi-Fi password prompts keep working | *new* `network.*` |
| Bluetooth | bluedevil (`BluezQt`, kded `bluedevil` agent) | `BluezQt`. Agent and pairing stay bluedevil's | *new* `bluetooth.*` |
| Power, battery | powerdevil (`org.kde.Solid.PowerManagement`, profiles over `net.hadess.PowerProfiles`), UPower | UPower `DisplayDevice` (or `Solid::Battery`), PowerProfiles, inhibition (`org.freedesktop.PowerManagement.Inhibit`) | `widgets` battery, *new* `power.*` |
| Brightness | powerdevil **`org.kde.ScreenBrightness`** (per display, 6.2+) | Same D-Bus tree. Its OSD comes back through `osdService` | `power.brightness` |
| Night light | KWin `org.kde.KWin.NightLight` | Same | quick setting |
| Wallpaper / desktop | plasmashell's desktop containment (one per screen, `background`) | A background-layer surface per screen: the home page (grid + OWL widgets), wallpaper as CSS | `home.*`, `system.wallpaper` |
| Multi-monitor | plasmashell + libkscreen + `kde_output_order_v1` | `QGuiApplication::screenAdded/Removed`, one surface set per `QScreen` (`LayerShellQt::Window::setScreen`), primary/order from libkscreen. Layout and arranging stay KScreen's (System Settings) | *new* `screens.*` |
| Lock screen | `kscreenlocker_greet` (separate, sandboxed process, QML from the look-and-feel package `contents/lockscreen/`). KWin locks with its own protocol, not `ext-session-lock` | **Keep kscreenlocker** as the security authority (PAM, fingerprint), as the phone keeps SystemUI's bouncer. Make it ours in two ways: a PowOS look-and-feel lockscreen QML themed from the same Omarchy colors, and, optionally, a web "face" (clock, media, notifications) through **`kde_lockscreen_overlay_v1`**, which plasmashell is already allowed to use | `system.locked` event |
| Lock / logout / power menu | `org.freedesktop.ScreenSaver.Lock`, ksmserver `org.kde.LogoutPrompt` (`promptLogout/promptShutDown/promptReboot`) and `org.kde.Shutdown` (`logout`, `logoutAndReboot`, `logoutAndShutdown`), logind for suspend/hibernate | The same calls. The confirmation can be our page or ksmserver's greeter | *new* `session.*` |
| Polkit prompts | `polkit-kde-authentication-agent-1` (own process) | Keep it | |
| Clipboard history | Klipper, which in Plasma 6 runs **inside plasmashell** (clipboard applet) | The host keeps history over the data-control protocol. KWin restricts it, so it must be listed in our `.desktop` (verify the interface name KWin 6.x exposes). Until we switch, Klipper keeps it | `clipboard.*` + `clipboard.history` |
| Splash handoff | plasmashell calls `org.kde.KSplash /KSplash setStage("desktop")` | Call it once the panel and home have painted | |
| Portals, file dialogs, settings | xdg-desktop-portal-kde, systemsettings | Keep them. `system.openSettings(kcm)` runs `systemsettings <kcm>` | `system.openSettings` |

## 3. The host

### 3.1 Shape

```
powos-shell  (C++/Qt 6, KF6; one process)
├─ ShellServer       powos:// scheme: overrides ~/.config/powos/shell → /usr/share/powos/shell; icons, thumbs, fonts
├─ Watcher           QFileSystemWatcher over the override tree (recursive by hand) → files.changed
├─ Surfaces          role × screen → QWebEngineView in a LayerShellQt window
├─ Bridge            one QObject on QWebChannel: call(id, method, args) → resolve / reject / emit
└─ Services          TasksModel, Notifications, SNI host, osdService, RunnerManager, PulseAudioQt,
                     NetworkManagerQt, BluezQt, UPower, ScreenBrightness, KScreen, kglobalaccel, ksmserver
```

Rust (cxx-qt, or smithay-client + wry) was considered. Most of section 2 is C++/Qt libraries
(libtaskmanager, libnotificationmanager, KRunner, the *Qt bindings), so C++ is the shorter path.

### 3.2 One bridge contract on both hosts

The phone's transport is `PowosHost.call(id, method, argsJson)`, answered through `window.__powosHost.resolve /
reject / emit` (`bridge.ts` `android()`, `ShellBridge.kt`'s `when (method)`). The desktop host exposes exactly that:

- A `QWebEngineScript` injected at `DocumentCreation` loads `qwebchannel.js`. When the channel is up, it sets
  `window.PowosHost = { call: (id, m, a) => host.call(id, m, a) }` and connects the host's `resolved / rejected /
  event` signals to `window.__powosHost.*`. QWebChannel is async, which the contract already is.
- `bridge.ts`: rename `android()` to `native()` and take `host` from the host (`"android" | "powos"`). There is no
  other change. Areas that one host lacks reject with `unsupported`. A new `system.caps()` lists the areas the
  host has, and the page hides UI for missing ones (for example, the phone has no `tray`, and the desktop has no
  `speech`, at first).
- Method names and JSON shapes are `types.ts`. A desktop-only area is added there first, with its mock in
  `bridge.ts`, so it can be built in a browser like the rest of the shell.

**Answer to "can the hosts share one contract?": yes, and today's transport already fits both.**

### 3.3 KWin's privileged interfaces

KWin only binds restricted globals for a client whose `.desktop` file (matched by the executable's full path)
lists them. plasmashell's (`org.kde.plasmashell.desktop`) has:

```
X-KDE-Wayland-Interfaces=org_kde_plasma_window_management,org_kde_kwin_keystate,zkde_screencast_unstable_v1,org_kde_plasma_activation_feedback,kde_lockscreen_overlay_v1
X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2
```

`org.powos.shell.desktop` needs the same list (plus data-control for clipboard history), with `Exec=/usr/bin/powos-shell`
as a full path and no `%u`. KDE's mailing list documents that field codes in `Exec=` make KWin refuse the
interfaces. Chromium's helper processes don't talk Wayland (the GPU process renders off-screen and Qt
composites), so only the host process needs the grant.

### 3.4 Surfaces, input, focus

| Role | Layer | Anchors / exclusive zone | Keyboard | Notes |
|---|---|---|---|---|
| panel (per screen) | top | one edge, `exclusiveZone = height` | none (on_demand while its search field is focused) | Auto-hide: zone 0 plus a 1-px edge surface that reveals it (KWin's screen-edge auto-hide is `org_kde_plasma_shell`-only) |
| home / wallpaper (per screen) | background | all edges, zone -1 | on_demand | The desktop grid + OWL widgets. Draws the wallpaper itself |
| launcher, quick settings, calendar, tray menus | top or overlay | anchored to the panel button | **on_demand** (exclusive for the launcher while it is open) | Created on open, hidden when closed. Losing focus closes it |
| notifications (toasts) | overlay | a corner | none | Input region = the toasts only |
| OSD | overlay | centered/bottom | none | Empty input region |
| lock face | via `kde_lockscreen_overlay_v1` | | none | Optional, after the rest |

- **Not one full-screen overlay.** A transparent full-screen page above everything would be the simplest "Gaia"
  design. But it would block KWin's direct scanout for full-screen games, which matters on a Bazzite-based OS,
  and it can't express exclusive zones. Small surfaces per role are better, and they exist only while visible.
- **Click-through**: `QWindow::setMask(QRegion)` becomes `wl_surface.set_input_region`. The page reports its hit
  rects, the same "page reports rects" pattern as `windows.embed`.
- **Transparency**: `page()->setBackgroundColor(Qt::transparent)` + `Qt::WA_TranslucentBackground`.
- **One app across surfaces**: the panel page is the root. It calls `window.open("powos://shell/surface.html#launcher")`.
  `createWindow()` returns a page the host puts in a layer window for that role (the role, anchors and size come
  through a bridge call before showing). Same origin, so the root page renders into `child.document` with Preact,
  and one set of signals drives all of them. QtWebEngine keeps a scripted `window.open` child in the opener's
  renderer process, so it is one renderer, not one per surface. Per-screen backgrounds are children too.
- **IME**: QtWebEngine uses Qt's `text-input-v3` path, the same Maliit keyboard `kwinrc` already sets up.

### 3.5 Scaling, rendering, cost

- HiDPI and fractional scaling: Qt 6.5+ uses `wp_fractional_scale_v1` + `wp_viewporter`, and Chromium gets
  `devicePixelRatio` from Qt. Set `QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough`. Mixed DPI per screen works
  because each surface lives on one `QScreen`.
- Rendering: Chromium's GPU process rasterizes and composites, and Qt imports the result into its RHI scene. That
  costs one extra copy per frame. It is fine for chrome, not for video. For video and live thumbnails, use native
  surfaces at reported rects.
- Memory: one browser process + GPU process + one renderer for all surfaces is roughly 150-250 MB. Separate views
  per role (no `window.open`) would add a renderer each. Plasmashell itself typically uses 200-400 MB, so this is
  a wash.
- Startup: start the profile and pages early (the service starts with `graphical-session.target`), show the panel
  first, then the home, then call KSplash `setStage("desktop")`. Expect under ~1 s to first paint on typical PowOS
  hardware (to be measured in phase 0).

### 3.6 Serving and hot reload

This is the same as `ShellActivity.kt`. A `QWebEngineUrlSchemeHandler` for `powos:` (registered `SecureScheme |
LocalScheme | CorsEnabled` before `QApplication`) serves `~/.config/powos/shell/<path>` if present, else
`/usr/share/powos/shell/<path>`. `files.changed` comes from the watcher, `shell-dev-url` points at a LAN dev
server, and `shell/push.sh` gets a `--desktop` target (scp into the override folder). Navigation away from
`powos:` is refused (`acceptNavigationRequest`), because the bridge is powerful. External links go to
`QDesktopServices::openUrl`.

### 3.7 Session integration and crash recovery

Plasma 6 starts the shell as the user unit `plasma-plasmashell.service` (part of `plasma-workspace.target`).

- `powos-shell.service`: `PartOf=graphical-session.target`, `Restart=on-failure`, `StartLimitBurst=3`/60 s,
  `OnFailure=powos-shell-fallback.service`.
- `plasma-plasmashell.service.d/powos.conf`: `ExecCondition=` skips plasmashell while
  `~/.config/powos/desktop-shell` says `web`.
- The fallback flips that flag to `plasma` for this session, starts plasmashell, and sends a notification. The two
  can't both run, because both claim `org.kde.plasmashell` and `org.freedesktop.Notifications`. A `powos shell
  web|plasma` CLI switch and a login-screen session entry ("PowOS (web shell)") make the choice explicit.
- Inside the host, if a renderer dies (`renderProcessTerminated`), reload the pages in place without restarting
  the process. The services keep their state, so a reload only redraws.

## 4. Reuse: keep vs replace

**Keep, unchanged:** KWin (and our KZones script), kscreenlocker (themed), powerdevil, kded6 (SNI watcher,
networkmanagement and bluedevil agents, kscreen), kglobalacceld, ksmserver + logout greeter, polkit-kde-agent,
xdg-desktop-portal-kde, krunner (Alt+Space and its D-Bus runners), kactivitymanagerd, Baloo, systemsettings and
every KCM, Dolphin/Konsole and the rest of `sources/kde`.

**Reuse as libraries in our host:** libtaskmanager, libnotificationmanager, KF6 Runner/Service/KIO/GlobalAccel/
WindowSystem, PlasmaActivitiesStats, PulseAudioQt, NetworkManagerQt, BluezQt, libkscreen, LayerShellQt, libdbusmenu-qt6.

**Replace (it lives in plasmashell):** panel and task manager, Kickoff/Kicker, desktop containment and wallpaper,
notification UI + server, OSD service, system tray host and its applets' UIs, Klipper, the `org.kde.plasmashell`
D-Bus surface, and the PowOS plasmoids (`desktop/plasmoid/com.powos.*` become OWL widgets or shell screens). The
`desktop/autostart/powos-panel-*` scripts become unnecessary under the web shell.

**The phone.** The phone runs two shells today. The Android app's WebView is the launcher (`ShellActivity`). The
rooted session's KWin 6.7.5 desktop is plasmashell with PowOS's plasma-desktop patches (swipe-up launcher,
Dashboard A-Z). The Anland work (`pkgs/kwin` 0013/0014, `org.powos.WindowTasks`) makes Linux windows Android tasks.

- **Same contract:** the desktop-only areas (`windows`, `desktops`, `tray`, `osd`, `session`, `audio`, `network`, `power`)
  are optional, and `system.caps()` reports them. On the phone, `windows.*` can later be served by the Android
  host from KWin's state through the existing `powos-open-task` KWin script + `org.powos.WindowTasks.show`, so the
  phone's web shell gets a PowOS window strip with no new protocol.
- **Same host on the phone's KWin desktop (later):** `powos-shell` builds on Arch ARM (`qt6-webengine`,
  `layer-shell-qt` are packaged), so the rooted session could drop plasmashell the same way. Then *both* of the
  phone's shells are `shell/`, and the PowOS desktop shown on the phone (and the PowOS desktop on a PC) is one
  code path. This comes after the PC desktop works. Until then the phone keeps plasmashell + its patches.

## 5. Risks and limits

- **Owning the session names**: notifications, OSD, KSplash, `activateLauncherMenu`. If we forget one, something
  silently stops: no volume OSD, a 30 s splash, a dead Meta key. Phase 4 has a checklist test (call each
  `org.kde.plasmashell`/`org.freedesktop.Notifications` method we implement, and diff `busctl --user` names
  against a Plasma session).
- **Plasma library ABI**: libtaskmanager/libnotificationmanager aren't stable API. Build the host in the image
  build against the image's Plasma (like `sources/kde/patches/plasma-desktop`), and pin by version.
- **Panel features from `org_kde_plasma_shell`** (auto-hide via KWin edges, "windows go below", floating-panel
  dodge) aren't in layer-shell. We do auto-hide ourselves and skip the rest at first.
- **Clipboard history and the data-control interface**: confirm the restricted interface KWin 6.x exposes before
  promising history.
- **Lock screen stays QML**: by design, for the security reasons the phone doc gives. A web lock *face* is only an
  overlay.
- **Thumbnails/live previews**: the first version uses still screenshots. Live previews need native surfaces.
- **Security**: the override folder drives the desktop. That is the point (AI-editable), and it is the same trust
  boundary as the phone. Keep remote navigation off and the scheme local-only.
- **Accessibility**: Chromium's AT-SPI bridge works in QtWebEngine, but our components must be semantic HTML. We
  lose Plasma's keyboard navigation of panels unless we build it (focus rings, Meta+Alt+P equivalents).
- **Gaming mode**: Bazzite's gamescope session doesn't use plasmashell, so it is unaffected. The no-full-screen-overlay
  rule (3.4) keeps the desktop's own full-screen games on direct scanout.

## 6. Plan

| Phase | What | Effort |
|---|---|---|
| **0. Panel prototype** (augment) | `powos-shell` with: `powos:` scheme + watcher + hot reload; QWebChannel shim setting `window.PowosHost`; **one bottom layer-shell panel** (exclusive zone) per screen showing `shell/` (a `panel.tsx` entry); `windows.list/activate/minimize` over `TaskManager::TasksModel`; `apps.list/launch` over KService + `ApplicationLauncherJob`. Runs **next to plasmashell** (its panel removed through an update script, as `session/plasma/powos-transparent-desktop.js` does). `.desktop` with the interface grants. Measure RSS, first paint, frame cost | ~1 week |
| 1. Bridge parity | The phone's areas on the desktop host: store, usage (ActivitiesStats), theme, clipboard, term (KPty + the same ring/offset protocol), ai, files. `bridge.ts` `native()` + `system.caps()` | ~2 weeks |
| 2. Launcher + search + desktops | Launcher surface (on_demand focus, closes on focus loss), KRunner `RunnerManager`, virtual desktops, overview shortcuts, kglobalaccel component | ~2 weeks |
| 3. Tray + quick settings | SNI host + dbusmenu, PulseAudioQt, NetworkManagerQt, BluezQt, UPower/PowerProfiles, ScreenBrightness, NightLight, session menu. All coexist with plasmashell | ~3 weeks |
| 4. **Replace** | Own `org.kde.plasmashell` (`/PlasmaShell`, `/org/kde/osdService`) + `org.freedesktop.Notifications` (libnotificationmanager), toasts + history, KSplash stage, clipboard history; systemd units, `ExecCondition`, fallback, `powos shell web\|plasma`, the session entry; VM boot test (the Tier-C "plasmashell running" check accepts either shell) | ~3 weeks |
| 5. Home + widgets | Background surfaces per screen running the home grid with OWL widgets. Depends on the OWL→Kotlin-Multiplatform/JS port (`shell/DESIGN.md` phase 4, which is its own ~3-4 weeks) | ~2 weeks after OWL-JS |
| 6. Polish | Lock-screen look-and-feel + `kde_lockscreen_overlay_v1` face, live thumbnails, auto-hide, a11y/keyboard nav, multi-monitor edge cases, the phone's rooted session on the same host | ~3 weeks |

Total: about 3-4 months for one developer to reach a shell that can be the default, plus the OWL JS port.

### First concrete step

Phase 0's panel, which is code for a new `sources/powos-shell/` (CMake, Qt 6 + KF6, built in the image like other
sources). About 600 lines of C++:

1. `main.cpp`: register the `powos` scheme, create a `QWebEngineProfile`, then create one `QWebEngineView` per
   `QScreen`, and before `show()` set `LayerShellQt::Window` to `LayerTop`, anchored bottom|left|right, with
   exclusive zone 48, `KeyboardInteractivityNone` and scope `powos-panel`.
2. `bridge.cpp`: `Q_INVOKABLE void call(int id, QString method, QString args)` with signals
   `resolved(int, QJsonValue)` / `rejected(int, QString)` / `event(QString, QJsonValue)`, and handlers for
   `apps.list`, `apps.launch`, `windows.list`, `windows.activate`, `windows.minimize`, plus `windows.changed`
   driven by the `TasksModel` signals.
3. `org.powos.shell.desktop` with plasmashell's `X-KDE-Wayland-Interfaces` line.
4. In `shell/`: `types.ts` gets `windows.list/activate/minimize` + `windows.changed` and its mock, and
   `ui/panel.tsx` gets a taskbar row (app icon, title, active/minimized state) plus the launcher button.
5. Try it in a VM (`docs/DUAL-BOOT-VM.md` / the Tier-C VM), never on a running workstation session first.
   Success: the panel reserves space, maximized windows stop above it, clicking a task activates or minimizes it,
   and saving `ui/panel.tsx` in the override folder redraws the panel in place.

### Phase 0: what runs (2026-10-20)

`sources/powos-shell/` (CMake; built in the image by the Containerfile's `powos-shell-builder` stage, shipped but not
started) and `shell/ui/panel.tsx` (`index.html?mode=panel`). Tested in a nested KWin 6.7 (X11-windowed, Xvfb, llvmpipe)
in a Fedora 44 container - `sources/powos-shell/dev/nested.sh`, because this Mac has no KVM for the VM. There:

- the panel is a layer surface along the bottom (top layer, exclusive zone 48): a maximized KWrite stops at y=752 of 800;
- the window list is live over `org_kde_plasma_window_management` (granted by `org.powos.shell.desktop`, the real KWin
  check): clicking a task activates it, clicking the active one minimizes it, again restores it;
- the launcher button grows the surface to 520 px (`panel.height`), lists KSycoca's apps with theme icons on
  `powos://icon/`, and starts one through `KIO::ApplicationLauncherJob`;
- saving `ui/panel.tsx` into `~/.config/powos/shell/` reloads the panel in place (`files.changed`);
- first paint 0.6 s after navigation; RSS 550 MB host + 280 MB renderer + 2x65 MB zygotes, under software GL.

Not tested yet: a real Plasma session next to plasmashell (its own panel removed), a VM boot of the image, multiple
screens, real GPU numbers. One `HACK:` (all of the process's windows are layer surfaces, `src/main.cpp`).


## Windows over the PowOS home (plan, 2026-10-22)

Board task `powos-home-as-the-desktop-linux-android-apps-as`. The desktop home (mode=desktop, `src/home.*`, a
bottom-layer surface) is the desktop expert's; this is the windows side: apps as windows over it, a taskbar, focus,
minimise, close, the switcher.

**What exists**
- Linux apps are KWin windows; the home is a bottom-layer surface, so every window is already over it.
- Android apps as windows (the phone's rooted session): `powos-android-app <pkg>` gives the app its own Android virtual
  display through scrcpy and shows it as a Wayland window (app_id `android-<pkg>`, KWin decorations, resize, input
  back to the app). `powos-android-tasks` puts each app running on the phone's own screen in the taskbar as a
  minimized stand-in window; activating the stand-in moves the app into a real window. The PowOS app writes an
  `android-<pkg>.desktop` per app into `/run/powos-app/share/applications` (52 on the phone), which is on
  powos-shell's `XDG_DATA_DIRS`: `apps.list` already lists them and `apps.launch` runs their Exec.
- powos-shell: `Windows` over `TaskManager::TasksModel` (`windows.list/activate/minimize`, `windows.changed`,
  coalesced 50 ms), granted `org_kde_plasma_window_management` by `org.powos.shell.desktop`; phase 0's `panel` role
  (`src/panel.*`, `ui/panel.tsx`: a bottom layer surface with an exclusive zone, a launcher button and the window
  list) - built, tested nested, not started on the phone (`POWOS_SHELL_ROLES` defaults to `home`).

**What's missing (in order)**
1. `windows.close` and an `android` flag on `DesktopWindow` (app id `android-*`; the stand-ins marked `standin`:
   minimized placeholders, shown as "on the phone's screen").
2. The taskbar on the phone's session, toggleable: `powos-desktop-shell taskbar on|off` (roles `home panel`).
   Plasma's own panel stays until ours is proven; with both, ours sits above it (two exclusive zones).
3. The taskbar's actions: click = activate / minimize the active one, middle click or the close button = close.
   Android windows get a small badge.
4. Proof: one Linux app (Konsole) and one Android app (a stand-in activated -> a scrcpy window) over the home, both in
   the taskbar, recorded with Android's screencap of the activity (KWin's capture comes back empty on Anland) while
   the user has the desktop open.
5. Then: the switcher (Alt+Tab / a swipe) over `windows.*` with thumbnails (`KWin.ScreenShot2`), virtual desktops,
   grouping, and replacing Plasma's panel.
