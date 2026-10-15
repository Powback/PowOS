# Plasma on Linux/Wasm — build plan

Goal: PowOS's real KDE Plasma desktop in the browser (Linux/Wasm, linuxfb on the canvas, no compositor, no GPU).
Source: dependency research against Plasma 6.8.0 / KF 6.31.0 upstream sources (2026-10-15). Versions: Qt 6.12,
KF 6.31.0, Plasma 6.8.0, plasma-wayland-protocols 1.23.0.

## Status
| done | what |
|---|---|
| ✅ | Qt 6.12: qtbase (Network, Concurrent, DBus), qtdeclarative, qtsvg, qtshadertools |
| ✅ | ECM, Kirigami (static, no D-Bus yet) — `kirigamihello` runs interactively |
| ✅ | expat, dbus (dbus-daemon session bus works in the browser) |

## Milestone A — real plasmoids via `plasmoidviewer` (plasma-sdk/plasmoidviewer only)
Links Qt Widgets/Quick/DBus, KF6 DBusAddons/I18n/ConfigCore/Package, Plasma + PlasmaQuick. No LayerShellQt, KWayland,
KWorkspace, activity daemon. First target: PowOS's own QML plasmoids (desktop/plasmoid/com.powos.*).

## Milestone B — `plasmashell` (trimmed plasma-workspace, ~45 packages)

### Tiers (build order)
0. third-party: zlib, libintl (musl built-in), libmount (util-linux), libxkbcommon (`-Denable-x11=false`),
   [wayland client + protocols + libffi — or patch Wayland out, see risks], libcanberra (null driver) + ogg/vorbis
   (or make Canberra optional in knotifications), libudev only if solid `UDEV_DISABLED=OFF`.
1. Qt: qtwayland (client) [unless patched out], qt5compat (GraphicalEffects QML), PrintSupport, Xml.
2. KF: kconfig, kcoreaddons (inotify; LibMount), ki18n, kwidgetsaddons, kcodecs, karchive
   (`WITH_BZIP2/LIBLZMA/OPENSSL/LIBZSTD=OFF`), kguiaddons (`WITH_WAYLAND/X11=OFF`), kwindowsystem
   (`KWINDOWSYSTEM_X11=OFF`), kdbusaddons (`WITH_X11=OFF`), kitemviews, kitemmodels, kcrash (`WITH_X11=OFF`),
   plasma-wayland-protocols.
3. KF: kcolorscheme, kservice, solid (`UDEV_DISABLED=ON`), kcompletion, kglobalaccel (`WITH_X11=OFF`), kpackage,
   knotifications.
4. KF: kconfigwidgets, kiconthemes (`USE_BreezeIcons=OFF`), kjobwidgets (`WITH_X11=OFF`), kbookmarks.
5. KF: kxmlgui, kio (`WITH_X11/WAYLAND=OFF`), ksvg, kstatusnotifieritem (`WITHOUT_X11=ON`), kdeclarative.
6. Plasma: layer-shell-qt, kwayland (stub EGL find), plasma-activities, libplasma (`ENABLE_ACTIVITIES` ON).
7. plasma-workspace trimmed to libkworkspace, components/{containmentlayoutmanager,shellprivate,dbus}, shell,
   containmentactions, lookandfeel (`WITH_X11=OFF WITH_X11_SESSION=OFF BUILD_GEOTIMEZONED=OFF`); plasma-desktop data
   only (desktoppackage, containments/panel); fake KWinDBusInterface / ScreenSaverDBusInterface cmake configs.
   Common KF options: `BUILD_SHARED_LIBS=OFF BUILD_TESTING=OFF BUILD_PYTHON_BINDINGS=OFF BUILD_DESIGNERPLUGIN=OFF`.

### Known patches needed
- `shell/screenpool.cpp`: drops screens with empty `name()` and waits for Wayland's kde_output_order_v1 — linuxfb
  screens have no name → no desktop view. Off Wayland: use `qApp->screens()`; give linuxfb a screen name.
- `shell/main.cpp`: `qApp->setProperty("org.kde.KActivities.core.disableAutostart", true)` (no kactivitymanagerd).
- Static plugins: PlasmaQuick (hard SHARED), `plasma_add_applet()` (SHARED), KirigamiPlasmaStyle (MODULE), package
  structure plugins, every QML plugin — `kcoreaddons_target_static_plugins` / `Q_IMPORT_PLUGIN`. Missing ones fail
  silently.
- Default desktop containment `org.kde.plasma.folder` pulls the whole KIO stack + workers: start with a plain QML
  containment.
- `QT_QUICK_BACKEND=software` before start (plasmashell re-execs itself when GL fails).

### Risks
1. Wayland client libs are link-time requirements of libplasma/plasmashell (runtime paths are guarded by
   `isPlatformWayland()`); libwayland needs libffi, which has no non-Emscripten Wasm port → likely patch Wayland out
   behind `#if` instead (plasmashellwaylandintegration, outputorderwatcher, screen-edge/plasma-shell protocols, osd).
2. Process spawning on NOMMU: KIO workers, D-Bus activation, KCrash handler (fork), QProcess (feature off in Qt).
3. libcanberra dlopens backends (ltdl).
4. Software rendering speed of SVG-heavy panels.
