# Removing the Compose launcher (2026-10-19)

The PowOS Android app (targets/android/app) carried two launchers: Omalauncher's original Jetpack Compose one
(`MainActivity` + `ui/`) and the web shell (`shell/`, Preact + TypeScript in a WebView, `ShellActivity`). The shell
had already replaced it as the phone's home (Settings › Home screen › "web launcher"); the Compose screens it had no
own yet were shown over it by `ShellScreensActivity`. This removes the Compose launcher: the shell is the only
launcher UI, and those screens are ported to it (`shell/ui/screens.tsx`, backed by `shell/ShellScreens.kt`).

What stays Compose: not the launcher, but the app's other activities and the widget engine's renderer (see the last
table). So the Compose dependencies stay in build.gradle.kts.

## Who reached what

| Entry point | Before | After |
|---|---|---|
| Android's Home | `.HomeShell` alias (web shell) or `.HomeLauncher` alias (Compose), toggled by `HomeScreen.java` from the engine Settings switch "web launcher" | `.HomeShell` only; `HomeScreen.apply` still switches it against `.HomeDesktop` (auto/desktop/launcher, folding) and FoldWatcher still makes it the default home |
| App drawer entries | "PowOS Launcher" (`MainActivity`) and "PowOS Shell (preview)" (`ShellActivity`) | "PowOS Launcher" (`ShellActivity`) |
| FoldWatcher (cover screen, nothing in use) | `HomeScreen.launcherActivity()`: either activity | always `ShellActivity` |
| Shell bridge `screens.open(name)` (edit sheet: widget store, AUR app store, settings, theme "browse…") | `ShellScreensActivity` (Compose, its own task) | the page's own screens (`openScreen`), no call to the host |
| `agents.newWidget` / `agents.newApp` without Linux or an agent | `ShellScreensActivity` Linux / coding agents | `"screens.open"` event: the page opens Linux / coding agents |
| `runtime.linuxWanted` (a terminal or Linux app asked for without Linux) | Compose home opened its Linux sheet | the home page opens the Linux screen (ShellBridge) |
| Widget notifications (`WidgetServices.notify`) | `MainActivity` | `ShellActivity` |
| Shared widget links (`https://simonschubert.github.io/omarchy-widgets/w#…`, VIEW intent) | `MainActivity` → `SharedWidgetScreen` | dropped (see below) |
| Debug extras (`--es exec/app/theme`, scripts/collage-captures.sh) | `MainActivity` | `ShellActivity` (debug builds) |
| PowOS desktop, engine, notifications of SessionService | engine's `andro.marchy.MainActivity` (the desktop) | unchanged |

## Screens

| Compose screen | What the user did there | Status |
|---|---|---|
| Home grid, pages, folders, dock, recent strip, prompt bar, side rail (`Launcher.kt`, `Home.kt`, `HomeGrid.kt`, `Folders.kt`, `PromptBar.kt`, `SideRail.kt`, `ShortcutTile.kt`, `LauncherState.kt`) | home | **ported** earlier: shell home (`grid.tsx`, `home.tsx`, `bar.tsx`, dock, recent row) |
| App drawer + search (`AppDrawer.kt`, `AppSearch.kt`) | find / launch / pin / uninstall apps | **ported** earlier: `drawer.tsx`, `apps.tsx` |
| Home menu (`HomeMenu.kt`) | new widget / app with the agent, stores, settings, theme strip | **ported** earlier: edit sheet (`editsheet.tsx`) |
| Settings hub (`SettingsScreen.kt`) | style, gestures, linux, coding agents, packages, widget store, android settings, licenses; system updates (check / update all), rootfs updates retry | **ported now**: `screens.tsx` SettingsScreen, an icon grid; the updates and setup cards as before |
| Style (`StyleScreen.kt`) | pick installed theme, install a theme from GitHub, update/remove own theme, download Omarchy's themes, backgrounds (pick, add image via the photo picker, use as Android's live wallpaper), icon flags (monochrome, theme colors, system colors), terminal font and text size | **ported now** (StyleScreen). Dropped from it: *home transparent*, *home apps boxed*, *recent apps shown*, *corners*, *widgets gaps / border width*, *screens gaps / border width*, *system bars background / border* - knobs of the Compose launcher's own drawing; the shell never read them (its look is theme.css's tokens), so on the phone they already did nothing. They stay in style.toml. The live foot preview of the terminal font is replaced by the size/columns line |
| Community themes (`ThemeCatalogScreen.kt`) | search omarchy.org/themes, install (with confirm), apply installed | **ported now** (ThemesScreen) |
| Widget store (`StoreScreen.kt`) | built-in terminal / agent tiles, reviewed widgets by category, search, a widget's page (what it installs and runs), add / update | **ported now** (StoreScreen + its widget page); previews are served by ShellHost (`/_screens/market/…`) |
| Linux (`LinuxScreen.kt`, `Setup.kt`'s progress) | install Arch with agents (and ask for notifications), progress by stage, retry, size, GPU acceleration on/off, remove (confirm) | **ported now** (LinuxScreen) |
| Coding agents (`AgentsScreen.kt`, `PromptBar.kt`'s agent picker) | install / remove / open agents; pick the default | **ported now** (CodingScreen: open, make default, remove, install). Not the shell's Agents view (`agents.tsx`), which shows running agents |
| Packages (`PackagesScreen.kt`) | search pacman + AUR, install, remove (second tap confirms) | **ported now** (PackagesScreen); the debounced search moved to ShellScreens |
| Licenses (`LicensesScreen.kt`) | the third-party notices and texts | **ported now** (LicensesScreen; the list moved to `shell/Licenses.kt`) |
| Gestures (`Gestures.kt`) | swipe up on home: app drawer or nothing | **dropped**: only the Compose home read it; the shell's swipe up always opens its drawer (gesture.ts) |
| First-run welcome (`Setup.kt`) | pick a theme, opt into Linux, become home | **dropped**: the shell goes straight home (`ShellActivity` finishes the welcome so the themes download behind it); themes from the edit sheet, Linux from settings, the home role asked once as before |
| Shared widget link / QR (`SharedWidgetScreen.kt`, `ShareWidgetScreen.kt`) | open a widget someone shared as a link, share one as a QR code | **dropped**: reached only from the Compose home (long press › share) and Omalauncher's GitHub Pages links; no PowOS flow uses them. Widgets come from the store or an agent |
| Style errors banner (`Launcher.kt` StyleErrors) | style.toml's parse errors over home | **dropped** from the UI; still written to errors.txt next to style.toml |
| Super+key shortcuts on home (`MainActivity.dispatchKeyEvent`) | Super+Enter terminal, Super+Space drawer, Super+A ask, Super+1..9 page | Super+Enter **kept** (ShellActivity); the others **dropped** (the shell has its own keyboard handling) |

## MainActivity's non-UI duties

All moved to `ShellActivity`: `runtime.start()` (was there already), asking once for the home role, the debug extras,
`onResume` (unfocus Linux windows, drop stale window tasks, re-read the Linux state, re-check the live wallpaper),
`onStart`/`onStop` (`screenStarted`/`screenStopped`, `usage.settle`), the photo picker's result.

## Compose that stays (not the launcher)

| Code | Why it stays |
|---|---|
| `PowosAiActivity` | PowOS AI as its own app: share sheet, Quick Settings tile, the agents' notifications, `ai.open` from the shell |
| `PowosTerminalActivity`, `ui/PtyTerminal.kt`, `ui/ExtraKeys.kt`, `ui/Keyboard.kt`, `ui/TerminalTiles.kt` | rooted mode's terminals (`runtime.terminal`: agents' tasks, "new widget/app with"), the shell's terminal font (`PtyTerminal.fontFile`) |
| `FilesActivity`, `ui/Files*.kt`, `ui/FileDialogs.kt`, `ui/FileTypes.kt` | the Files app |
| `LinuxWindowActivity`, `ui/WindowManager.kt`, `ui/WindowInput.kt` | Linux (Wayland) windows as tasks |
| `widgets/render/*`, `ui/WidgetTile.kt`, `widgets/Previews.kt` | OWL widget rendering for `.preview` PNGs agents look at while making widgets |
| `ui/Theme.kt` (Palette), `ui/Icons.kt`, `ui/IconTheme.kt`, `ui/IconMask.kt`, `ui/Images.kt`, `ui/Speech.kt`, `ui/Components.kt` | the palette the shell's `theme()` sends, app icons, speech to text, shared pieces of the activities above |
| Compose runtime state (`mutableStateOf`, `snapshotFlow`) | the runtime's state model (ThemeStore, Market, ...), which the bridge observes |
