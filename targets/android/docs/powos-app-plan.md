# PowOS Android app: Omalauncher UI on Andromarchy's engine (plan)

Status: **plan only**, not started. Roadmap step 1b, after PowOS runs on the S25 via the stock
Andromarchy app. Written 2026-10-13 from a read of Omalauncher (v0.7.0 source, MIT) and
Andromarchy @ 220754d (GPL-3.0).

## Goal

One app, `com.powos.app`, that is the S25's home screen (Omalauncher's launcher: home grid, widgets,
themes, drawer) and runs PowOS (KDE Plasma via KWin's Anland backend) on Andromarchy's no-root engine
with the Adreno GPU. Android stays underneath, hidden. (The S25 can't boot another OS: Samsung locked
the bootloader. Native PowOS is the OnePlus Open's step.)

## What stays, what goes

Keep (pure launcher): `ui/Home*`, `Folders`, `AppDrawer` (Android half), `AppSearch`, `SideRail`,
`Gestures`, `Style*`, `ThemeCatalog*`, `Settings*`, `theme/`, `widgets/` + the `:owl` module,
`upgrade/`, `AndroidApps`, `AppUsage`, `LauncherData`, the wallpaper service.

Replace or drop (proot + Omalauncher's own CPU compositor): `linux/Proot.kt` (becomes a `Guest`
interface, implemented over Andromarchy's `lotfix-run`), `wayland/*` + `cpp/wlbridge.c`,
`LinuxWindowActivity` (one task per window: not possible with Anland's single output surface),
`ui/WindowManager`, `WindowInput`, `TerminalTiles`, `Keyboard`, `linux/Bootstrap`, `Gpu` (Mali-only),
`ProcShim`, `AudioBridge`, `OpenBridge`, `LinuxService`. `Runtime.kt` is the hub that wires them.

## Shape

- Gradle: `:app` (Omalauncher fork, Kotlin), `:engine` (Andromarchy's Java/AIDL/JNI as a library,
  Java package kept as `andro.marchy` because JNI symbols use it), `:owl`.
- Andromarchy's `MainActivity` becomes `DesktopActivity`: singleTask, own `taskAffinity`, no launcher
  filter, ideally `android:process=":desktop"` with `SessionService` and `InstallActivity`.
- `targetSdk 28` (exec from app data), `minSdk 30`, `compileSdk 37`; restore edge-to-edge manually;
  POST_NOTIFICATIONS via settings; side-load only (not Play Store).
- Remove today's HACKs: session command from `/etc/powos/session`, `/opt/powos/first-boot.sh`,
  `desktop-ready` file instead of the quickshell poll, `powos-rootfs.tar.gz` from our release URL.
- Licence: combined work under **GPL-3.0** (Andromarchy, anland-termux, termux-va); keep MIT notices;
  publish Corresponding Source; source offer for the forked KWin in the rootfs.
- Built in `~/Projects/android-app-dev/projects/powos-app` by `android-builder` with the persistent
  keystore; updates via APK + pacman repo (see the deploy task), never a full rootfs re-download.

## Phases

| Phase | Scope | Effort |
|---|---|---|
| 0 Skeleton | fork, `:engine`, CMake executables, rename, target 28, edge-to-edge, android-builder build | 2-3 days |
| 1 v1 | launcher with Linux surfaces removed + "PowOS desktop" tile/entry (install → session → desktop); HACKs removed | 1-1.5 weeks |
| 2 Widgets on PowOS | `Guest` seam over lotfix; widget `cmd`/`stream` against the PowOS session; session-state placeholders | 1-1.5 weeks |
| 3 Linux apps in drawer | `.desktop` listing, launch into KWin then raise the desktop; optional second compositor socket for terminal tiles | 2-3 weeks |
| 4 Lock screen + bridge | PowOS screen over Android's keyguard (real unlock via `requestDismissKeyguard`); calendar/notification bridge | 2+ weeks |

## Risks

- KWin 6.7.5 + ported Anland patches not yet run on a device (first test pending).
- Memory pressure: Compose launcher + KDE session under one uid on a phone.
- Anland = one output surface for KWin: limits per-window features (phase 3/4).
- GPL-3 obligations for the APK and the rootfs's patched packages.
- Resolved 2026-10-13 on the S25 (Android 16 / One UI 8.0, Adreno 830): exec-from-data at target 28
  and the KGSL Mesa GPU path both work (stock Andromarchy desktop ran).
