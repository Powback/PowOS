# Native desktop architecture: who composites, and where the PowOS shell runs

Status: design note for the user's review, 2026-10-24. Board task "Native desktop architecture: KWin composites,
PowOS shell as Plasma shell". It builds on `docs/DESKTOP-WEB-SHELL.md` (powos-shell, the paused Qt host) and
`targets/android/docs/powos-window-tasks.md` (Linux windows as Android tasks).

The requirement (the user, 2026-10-24): **"both plasma and our webui should both work perfectly independently and
together."** Neither is a fallback for the other.

## 1. The three modes, and what "correct" means

| mode | what the user opens | who composites | where Linux windows live | wallpaper |
|---|---|---|---|---|
| Plasma alone | the Plasma app (drawer "Plasma", or Plasma as the Android home) | KWin, into the app's one surface | KWin windows on Plasma's desktop, KDE decorations, KDE maximize/move/resize/popups | Android's, through the transparent desktop |
| Web shell alone | PowOS home (the Preact shell) | Android (SurfaceFlinger) | each window its own Android task (PowosWindowActivity), PowOS's frame and title bar | Android's |
| Together | both in one session, switching between them | each its own, as above | **one place per window, never two** (below) | the same Android wallpaper behind both |

The rule that makes "together" well defined: **a window lives in exactly one world at a time.**

- Opened in Plasma (Kickoff, Dolphin -> Gwenview, a terminal) -> it is the desktop's: a KDE window on Plasma's
  desktop. It stays there when the user goes home; it is never pulled out into a floating task behind their back.
- Opened from the web shell (drawer, dock, search, recents, the AI) -> it is a task: PowOS's frame, Android's window
  management. It is not also drawn on Plasma's desktop (it lives on KWin's hidden "Android tasks" desktop).
- Moving between worlds is always an explicit user act: tapping a Plasma window's app in the web shell's launcher
  shows it as a task (powos-open-task); closing that task gives it back or closes it.

## 2. What runs today

```
Android (SurfaceFlinger composites)
 ├─ wallpaper (OxygenOS live video wallpaper)
 ├─ PowOS home: ShellActivity, Android WebView, shell/ (Preact)          <- the web shell
 ├─ PowosWindowActivity #n + WindowFrame (title bar)  <- one per exported Linux window, KWin renders it offscreen
 └─ MainActivity ("the Plasma app"): one SurfaceView, KWin's whole output, translucent  <- Plasma
KWin 6.7.5 + Anland backend (pkgs/kwin 0001-0025) inside PowOS
 ├─ output "anland-1" -> MainActivity's surface
 └─ AnlandWindowTasks: control channel to the app ("open/close/size/export-new/desktop ...")
```

What this costs, from the board's bug history (2026-10-21..24): every Linux window in the web shell is a second
rendering path KWin was not built for. Input had to be re-routed by hand (0020: touches to the right window; 0022:
X11 windows shown to Xwayland so taps land), full screen and maximize were re-implemented (0017, 0021, 0024), dialogs
are drawn into the parent's task, and popups that extend past the window are clipped by the task's bounds (Kate's
menus). Each fix is a patch on the seam between two window managers.

In the Plasma app none of that exists: KWin does decorations, popups, input, X11 and full screen natively. Its
remaining bugs were where the seam leaked into it: windows opened from Kickoff left Plasma as floating tasks, the
maximize button sent a window out into a task (PowOS's frame on top of KDE's decoration), and going home pulled every
Plasma window out into floating tasks. kwin 0025 + the app's `desktop 1|0` fix those (section 5).

## 3. Options

**A. Two compositors, a hard seam (today, hardened).** Android composites the web shell and its window tasks; KWin
composites the Plasma app. Each mode is native where it is used; the seam is the window-ownership rule.

**B. KWin composites everything; the PowOS shell becomes the Plasma shell.** The unfolded "desktop" is the Plasma
app full time. powos-shell (sources/powos-shell: QtWebEngine pages in layer-shell surfaces, the same `shell/` and
the same bridge contract) replaces plasmashell's desktop and panel; Linux windows are plain KWin windows. Android
apps join as windows through their own virtual displays (powos-android-app, scrcpy-style) or stay Android tasks over
the surface.

**C. Per form factor.** Folded (phone): A. Unfolded / external display: B as an opt-in "desktop session", the same
`shell/` in both, sharing its store.

| | A: two compositors | B: KWin composites all | C: per form factor |
|---|---|---|---|
| Linux windows: decorations, popups, X11 input, resize | patched seam (0013-0024), popups clipped to the task | native KWin | native when unfolded |
| Android apps | native (freeform, split, PiP, Recents) | second class (virtual display: latency, IME, no Recents) | native folded, second class unfolded |
| Android system UI (shade, notifications, IME, gestures) | native | must be bridged into KWin | mixed |
| The web shell's look (glass over the live wallpaper) | native (SurfaceFlinger blur regions) | KWin blur over a transparent output, wallpaper from Android | both paths to keep |
| Cost at rest | 0 frames (Android); KWin frozen when the Plasma app is away | KWin + QtWebEngine always on (~625 MB RSS measured for powos-shell, 2026-10-21) | B's cost only in desktop mode |
| Work to "perfect" | finish the seam (popups, ownership, checks) - weeks | powos-shell paused at phase 0; plasmashell replacement estimated 3-4 months | B's months plus A's weeks |
| Risk | known, measured, checks exist | Android apps and system UI regress | two shells to keep equal |

## 4. Recommendation

**Keep A as the architecture, and make the seam a rule instead of a pile of patches. Do not start B now.**

- The user's "perfectly independently" already holds by construction in A: the Plasma app is pure KWin, the web
  shell is pure Android. What failed was the seam leaking (windows changing worlds by themselves); that is a rule
  (section 1), now enforced by KWin itself (0025) and checked in all three modes (section 6).
- B gives up what the phone is best at (Android apps, its system UI, Recents, the IME) to fix problems A can fix in
  weeks. Its value - one compositor for Linux windows - is already available: it is the Plasma app.
- Keep B's door open cheaply: powos-shell and the shared bridge contract stay; if the unfolded desktop ever becomes
  mostly Linux work, C (B for desktop mode only) is the route, decided on measurements (input latency, frame cost,
  RSS) of both paths, not on taste.

## 5. Migration slices (A, hardened)

1. **Window ownership** (done 2026-10-24): the app tells KWin when the desktop is on screen (`desktop 1|0`, from
   MainActivity's onStart/onStop, `WindowTasks.desktopShown`). kwin 0025: while it is, new windows stay KDE windows on
   it, maximize is KWin's own, and every application window on it is marked the desktop's (`powosDesktopOwned`), so
   `export-new` and its sweep never pull them out later. With an older KWin the app falls back to `export-new 0`
   while the desktop is on screen.
2. **Mode-aware session restart** (done): a logout / KWin restart started from the web shell brings the session back
   behind it (Restarter starts SessionService) instead of opening Plasma's desktop; from the Plasma app it reopens it.
3. **Transparent desktop, proven** (done): the "0.117 black" FAIL was the check comparing against home's own widgets
   and status bar (lit) over the wallpaper's black sky. plasma-transparent.sh now leaves home's UI out (its rects over
   CDP), skips cells where the live wallpaper moved, and checks SurfaceFlinger's stack: wallpaper directly under the
   desktop's translucent surface. Measured on the phone: 0.99 of the lit wallpaper cells match, 0.009 black.
4. **Popups of task windows** (next, KWin): a popup (Kate's menus) is placed by KWin against the output, then
   clipped by the task's buffer. Constrain popup placement to the task's area (xdg_positioner / X11 override-redirect
   placement against the task window's bounds), so menus flip or shift inside the task like on a small screen.
5. **One title bar per window in the web shell** (in progress elsewhere: Window core #7, CSD apps): a task draws the
   client area only; KDE's decoration never shows there.
6. **Shared look**: the Plasma app's desktop uses the same wallpaper (done: transparent) and, later, the web shell's
   theme colours through the theme mirror (powos-desktop skill, paused list).
7. **Measure for C**: input latency and frame cost of a Kate window in both modes (plasma-modes.sh records the
   evidence), before any decision about running `shell/` inside KWin.

## 6. Checks

`tools/phone/verify/plasma-modes.sh <plasma|shell|together>` (queued on the board tasks):

- plasma: Kate started in the session is a KWin window on Plasma's desktop, KDE decoration, no Android task; a tap +
  keys reach it; a title-bar drag moves it; KWin's maximize stays KDE's (frame = work area, still no task); its
  popup lies inside the screen.
- shell: Kate from home's launch call is one window task on the hidden tasks desktop (not on Plasma's), at most one
  PowOS title bar per task, a tap + keys reach it.
- together: a Kate task stays a task in the Plasma app (no duplicate); SurfaceFlinger has the wallpaper directly
  under the desktop's translucent surface; Dolphin started in Plasma stays a KWin window there, also after going home.

`plasma-transparent.sh` (the wallpaper) and the window-core checks (linux-float, linux-touch, window-chrome,
dock-taskbar) cover the rest of each mode.
