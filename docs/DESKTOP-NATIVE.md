# Native desktop architecture: who composites, and where the PowOS shell runs

Status: **accepted by the user, 2026-10-24** (two compositors: Android draws the PowOS shell, KWin draws Plasma
apps, a window lives in one world unless the user moves it). The provisional hold is lifted: work that locks in
this architecture may proceed. Written 2026-10-24 as a design note; Board task "Native desktop architecture: KWin composites,
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
| Linux windows: decorations, popups, X11 input, resize | patched seam (0013-0027), popups placed inside the task | native KWin | native when unfolded |
| Android apps | native (freeform, split, PiP, Recents) | second class (virtual display: latency, IME, no Recents) | native folded, second class unfolded |
| Android system UI (shade, notifications, IME, gestures) | native | must be bridged into KWin | mixed |
| The web shell's look (glass over the live wallpaper) | native (SurfaceFlinger blur regions) | KWin blur over a transparent output, wallpaper from Android | both paths to keep |
| Cost at rest | 0 frames (Android); KWin frozen when the Plasma app is away | KWin + QtWebEngine always on (~625 MB RSS measured for powos-shell, 2026-10-21) | B's cost only in desktop mode |
| Work to "perfect" | finish the seam (popups, ownership, checks) - weeks | powos-shell paused at phase 0; plasmashell replacement estimated 3-4 months | B's months plus A's weeks |
| Risk | known, measured, checks exist | Android apps and system UI regress | two shells to keep equal |

## 4. Recommendation (accepted 2026-10-24)

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
4. **Popups of task windows** (kwin 0027, 6.7.5-3.31; check `plasma-modes.sh popup`): a popup (Kate's menus) was
   placed by KWin against the output, then clipped by the task's buffer. Now `Workspace::setPopupAreaHandler` gives
   the xdg_positioner the task's area (AnlandWindowTask::area: the client area at the task's size) for a window in a
   task, its dialogs and their popups, so menus flip or slide inside the task like on a small screen. Chosen over a
   task per popup (a second Android window per menu, its input grab and dismissal across two tasks) and over growing
   the parent's task (the window would jump and cover home under it): placement is KWin's own mechanism, one seam.
   The desktop's windows keep the output's area (Plasma's popups unchanged). Open: X11 override-redirect menus
   (Steam's) place themselves; they still clip.
5. **One title bar per window in the web shell** (in progress elsewhere: Window core #7, CSD apps): a task draws the
   client area only; KDE's decoration never shows there.
6. **Shared look**: the Plasma app's desktop uses the same wallpaper (done: transparent) and, later, the web shell's
   theme colours through the theme mirror (powos-windows skill, paused list).
7. **Measure for C**: input latency and frame cost of a Kate window in both modes (plasma-modes.sh records the
   evidence), before any decision about running `shell/` inside KWin.

## 6. Checks

`tools/phone/verify/plasma-modes.sh <plasma|shell|together>` (queued on the board tasks):

- plasma: Kate started in the session is a KWin window on Plasma's desktop, KDE decoration, no Android task; a tap +
  keys reach it; a title-bar drag moves it; KWin's maximize stays KDE's (frame = work area, still no task); its
  popup lies inside the screen.
- shell: Kate from home's launch call is one window task on the hidden tasks desktop (not on Plasma's), at most one
  PowOS title bar per task, a tap + keys reach it.
- popup: Kate's context menu at the bottom line of its task lies inside the task (kwin 0027).
- together: a Kate task stays a task in the Plasma app (no duplicate); SurfaceFlinger has the wallpaper directly
  under the desktop's translucent surface; Dolphin started in Plasma stays a KWin window there, also after going home.

`plasma-transparent.sh` (the wallpaper) and the window-core checks (linux-float, linux-touch, window-chrome,
dock-taskbar) cover the rest of each mode.

## Desktop windows inside the web shell (2026-10-28)

User: "linux windows dont play nice with the webui, they are supposed to be fully integrated in the webui natively not
this overlay shit" - and this applies to every desktop-mode window. Today a floating window (an Android freeform task,
or a Linux window as a `PowosWindowActivity` task) sits above the whole web shell, and its PowOS title bar is a
separate `TYPE_APPLICATION_OVERLAY` window (`WindowFrame.kt:22`) above every task. A screenshot showed a Termux-like
Linux terminal drawn over the open drawer and the dock.

Target z-order, owned by the web shell (one window manager: the web UI decides position, z-order, focus and frames;
Android and KWin only render content):

    [shell desktop layer: wallpaper, widgets]  <  [each window's task surface + its DOM frame]  <  [shell chrome: dock/taskbar, drawer, panels, shade]

### Chosen mechanism (in 3 lines)

1. Tasks stay where WM puts them (the DefaultTaskDisplayArea, organized by WM Shell); the shell moves around them instead:
   the HOME task (ShellActivity's WebView) is the bottom layer, a second shell WebView in a trusted system overlay window is the top layer (chrome).
2. Each window's frame is a SurfaceControlViewHost (FrameChrome's web page) parented under the task's own surface, inside its
   bounds with a captionBar insets source - so it z-orders, moves and animates with its window by construction (TaskBarProbe path).
3. Linux windows take the same path unchanged: they are already `PowosWindowActivity` freeform tasks, so they interleave with Android windows.

### Device evidence (OnePlus Open, 2026-10-28, read-only dumpsys)

- `dumpsys activity containers`: all app tasks are root tasks in `DefaultTaskDisplayArea` next to the HOME task
  (Task=3253 HOME, Task=3209 FREEFORM Termux, Task=3 + 4/5 the split root). Z is the order of these root tasks; the HOME task
  is above the freeform tasks while it has focus (3209 `visible=false`), so "tap the wallpaper" today hides all windows.
- WM Shell (SystemUI) is the organizer of everything: `ShellTaskOrganizer` with `#1 TASK_LISTENER_TYPE_FREEFORM
  FreeformTaskListener`, `task=3209 listener=FreeformTaskListener wmMode=5`; `DefaultTaskDisplayArea
  (RootTaskDisplayAreaOrganizer.onDisplayAreaAppeared)`, `Display 0 (RootDisplayAreaOrganizer...)`.
- SurfaceFlinger: SystemUI already parents `Decor container of Task=3209` / `Task=3260` (z=30000) under each freeform task
  (3260 is a `PowosWindowActivity`). A third-party-process SCVH under a task surface is a normal, supported shape;
  TaskBarProbe (`TaskBarProbe.kt:1-35`) documents PowOS doing the same from a TaskLeash session leash, surviving the transition end and taking touches.
- PowOS windows above apps already exist: `PowOS shade`, `PowOS pull-up panel`, `PowOS quick tools`, `PowOS panel anchor`
  (OverlayHost, `TYPE_STATUS_BAR_SUB_PANEL`, `OverlayHost.kt:26`). The app holds `STATUS_BAR_SERVICE` and `INTERNAL_SYSTEM_WINDOW` (manifest :48, :50).
- `enable_freeform_support=1`, `powos_bar_in_task` unset (probe off), `powos_live_leash` default 1.

### Ruled out

- **Our own TaskOrganizer** (for freeform, or a root task via `createRootTask`): registering a TaskOrganizer makes it the
  organizer of every non-created task (TaskOrganizerController puts the newest organizer first and re-evaluates all
  tasks' organizer state). That steals FreeformTaskListener, split (Task=3) and desktop decor from WM Shell, which owns
  them on this device (dump above). Unregistering removes the root tasks we created. Conflict, not coexistence.
- **DisplayAreaOrganizer / reparenting the (Task)DisplayArea under the launcher**: `FEATURE_DEFAULT_TASK_CONTAINER` and the
  root display area are already organized by WM Shell (RootTaskDisplayAreaOrganizer, RootDisplayAreaOrganizer); a second
  organizer for a feature is refused ("Replacing existing organizer currently unsupported"). Organizing a spare feature to
  `createTaskDisplayArea` gives a new TDA whose tasks are still Shell-organized, and its surface can't sit *between* two
  layers of one ShellActivity window anyway. Kept only as a fallback note.
- **Reparenting task leashes under ShellActivity's SurfaceControl permanently / setRelativeLayer**: every transition's
  finish transaction reparents its participants back to their WindowContainer parent, and WM's `assignChildLayers` calls
  `setLayer`, which drops a relative layer. It would have to be redone after every open/focus/resize/rotation and races
  WM (TaskLeash.kt:201-203 already hit the finish-vs-start reparent race once).
- **TaskView / TaskEmbedder**: `ActivityView`/`TaskEmbedder` were removed in Android 12; WM Shell's `TaskView` only works
  inside SystemUI's process (it is a ShellTaskOrganizer listener). PowOS can't host one.
- **One WebView + SurfaceControl layering**: one WebView draws into one surface; the DOM can't be split into a plane under
  and a plane over other processes' tasks. Two shell surfaces are needed regardless (wallpaper/widgets must be under
  windows, dock/drawer over them).
- **Linux: embedding KWin's buffer straight into the shell** (the consumer in `native_consumer.c` writes any
  ANativeWindow, today `PowosWindowActivity.java:98`'s SurfaceView): it would z-order only against PowOS's own surfaces,
  never interleave with Android app windows, and would lose what the task gives for free (recents card, split, focus,
  IME, back, the switcher, frames). Rejected; Linux windows stay tasks.

### Two web layers and where touches go

- **Bottom** - ShellActivity (the HOME task, alias `andro.marchy.HomeShell`), page as today minus the chrome in desktop
  mode: wallpaper, widgets, desktop icons. It gets every touch that lands on no window and no chrome region.
  So that touching it no longer raises HOME over the windows, the HOME task is made non-focusable while at least one
  desktop window exists (`TaskLeash.setFocusable`, `TaskLeash.kt:325`, as the page slide already does). Text fields
  move to the chrome layer (drawer search lives there anyway).
- **Middle** - task surfaces. Touch goes to the task's own input windows natively; the frame's SCVH has its own input
  window (title bar drag, buttons, double tap).
- **Top** - a new `DesktopChromeHost` window (an OverlayHost sibling; system type so it is a trusted overlay and
  untrusted-touch occlusion doesn't block taps on apps under its transparent parts), full screen, transparent, page
  `?mode=chrome`: dock/taskbar, drawer, panels. Touchable only in the rectangles the page reports
  (`AttachedSurfaceControl.setTouchableRegion`, as `VerifyRun.kt:355`); everything else falls through to the windows or
  the desktop. The shade, quick tools and pull-up panel keep their own existing windows above it. Shown only in desktop
  mode, unfolded, with no full-screen app/game on top.
- State between the two pages goes through the bridge/runtime exactly as the shade and quick-tools pages already do
  (one runtime, two ShellHosts).

### Window bounds: owned and persisted by the shell

User: "sometimes the position of floating windows goes offscreen ... their pos isnt properly persisted". The web shell
owns each window's bounds, persisted **per app and per screen** (unfolded inner / folded cover, keyed by display size +
rotation), not per task id. On open, restore (from the dock), un-maximise, rotation and fold/unfold it always clamps
them on screen: the whole title bar's top inside the area and at least ~96 dp of the bar horizontally inside, so the bar
can always be grabbed.

Today's bugs (step 0, can ship now, independent of the rest):
- `WindowFrames.kt:392` `belowStatusBar` only fixes `top`; nothing clamps left/right/bottom, so a window dragged past
  an edge, or left from a rotation, keeps its bar off screen.
- `WindowFrames.kt:621` un-maximise restores `back.before` unclamped, and `WindowFrames.kt:577` `toWindowAgain` restores
  `fullBefore` unclamped - after a rotation or fold the old rect can be off screen.
- `WindowFrames.kt:765` `restore` (from the dock) raises the task at its old bounds without a check.
- `WindowFrames.kt:859` `lastBounds` is in-memory and keyed by task id: a new task of the same app, or a PowOS restart,
  forgets the position and falls back to the cascade (`AppWindows.kt:108`).

### Ordered edit steps (each one 5-minute edit agent)

0. **Clamp now** - add `AppWindows.onScreen(context, r): Rect` next to `area()` (`AppWindows.kt:92`): keep size (shrink
   only if larger than the area), top in `[area.top, area.bottom - bar]`, >= 96 dp of the bar inside horizontally.
   Generalise `belowStatusBar` (`WindowFrames.kt:392`) to move any visible window whose `onScreen(bounds) != bounds`;
   pass the targets at `WindowFrames.kt:577` and `:621` and `restore` (`:765`) through it. Ships alone.
1. **Persist bounds per app + screen** - a small `WindowPlaces` store (SharedPreferences, key `pkg|linuxId` + screen key)
   written on drag/resize end (`WindowFrame.kt:628` `endDrag`, `:892` `settleTask`) and read by `AppWindows.options`
   (`AppWindows.kt:38`) before `nextBounds`, clamped by step 0. Later (step 11) the store moves behind the bridge so the page owns it.
2. **Task surface registry** - new `TaskSurfaces.kt`: task id -> the task's SurfaceControl, filled from every TaskLeash
   session (`TaskLeash.kt:240` `leashesOf`, `:381`), dropped on task removal (`FreeformTasks.listen`, `FreeformTasks.kt:327`).
3. **Leash at open** - register a second, permanent remote in TaskLeash (`TaskLeash.kt:352` `filter`, `:107` `start` pattern)
   for OPEN/TO_FRONT of freeform tasks that plays a short open (or passes the start transaction straight through) and
   records the leash into TaskSurfaces. Fallback when Shell plays it itself: the first `FreeformTasks.moveTo`
   change transition (`FreeformTasks.kt:160`) run as a TaskLeash session gives the leash.
4. **Frame in the task** - turn `TaskBarProbe.attach` (`TaskBarProbe.kt:42-60`) into `TaskFrame`: the SCVH hosts
   `FrameChrome(context, "window", app)` (`FrameChrome.kt:12`, the existing DOM bar) instead of the tint strip, at the
   top of the task inside its crop, relaid on bounds/config change. Title-bar double tap/double click maximises and
   restores through `WindowFrames.maximise(id)` (`WindowFrames.kt:618`) - the same single path as the maximise button
   today (`WindowFrame.kt:215`); a mouse double click arrives as two ACTION_DOWN within `ViewConfiguration.getDoubleTapTimeout`, handled the same.
5. **Caption insets** - `FreeformTasks.captionInsets(id, heightPx)`: WCT `addInsetsSource(token, owner, 0,
   WindowInsets.Type.captionBar(), Rect(0,0,w,h), ...)` via `transact` (`FreeformTasks.kt:237`), so app content starts
   under the bar; removed in `setFullScreen(on=true)` (`FreeformTasks.kt:143`). Keep OemCaption's 1-px Shell caption (`OemCaption.kt:9-20`) - its input window must not cover the bar.
6. **Switch WindowFrames to in-task frames** - at `WindowFrames.kt:336` create `TaskFrame` when TaskSurfaces has the
   task, else the old `WindowFrame` overlay. Flag `powos_bar_in_task` (`TaskBarProbe.kt:39`) becomes default 1. The drag
   stream stays native (WindowFrame's drag code moved onto the SCVH's touch); `WindowFrame.place` (`:130`) no longer
   positions a bar window for in-task frames.
7. **HOME non-focusable in desktop mode** - in WindowFrames' refresh, `TaskLeash.setFocusable(homeToken, shown.isNotEmpty())`
   inverted (non-focusable while a window shows; focusable again when none or when folded).
8. **Chrome host** - new `DesktopChromeHost.kt` beside `OverlayHost.kt:34`: one warm full-screen transparent window,
   trusted system type below the shade's, page `?mode=chrome`; touchable region = union of page-reported rects
   (`rootSurfaceControl.setTouchableRegion`, pattern `VerifyRun.kt:355`; empty region = touch-through).
9. **Chrome page** - `shell/hosts/desktop.ts` / `wide.ts:63`: a `chrome` host mode rendering dock/taskbar and the
   drawer (`shell/ui/drawer.tsx`), reporting their rects through the bridge (ChromeSlot.regions as `FrameChrome.kt:30`);
   the HOME page stops rendering them in desktop mode (`shell/ui/desktop.tsx`).
10. **Chrome visibility** - DesktopChromeHost hidden when folded, on the lock screen/switcher (the rules WindowFrames
    already follows) and when a full-screen app is on top (`FreeformTasks.fullScreen`, `FreeformTasks.kt:105`).
11. **Shell owns z-order/focus/bounds** - bridge calls `windows.raise/move/maximise/minimise` from the page map to
    `FreeformTasks.raise/moveTo`, `WindowFrames.maximise/minimise`; the page holds the window list, order and the
    persisted places (step 1's store read/written through the bridge), Kotlin only applies.
12. **Linux windows** - nothing new in `PowosWindowActivity.java`; verify the generic path covers task 3260-style tasks
    (frame under the task, captionBar inset shrinks its SurfaceView, KWin's own decoration stays off - `one-title-bar.sh`).
13. **Drop the overlay bars** - once checks pass on phone, remove `WindowFrame`'s `TYPE_APPLICATION_OVERLAY` bar/grip
    windows (`WindowFrame.kt:22`, `:169` `addViews`) and the fallback in step 6.

### Risks

- Shell may play freeform OPEN itself before our remote (handler priority); step 3's fallback covers it at the cost of a
  frame appearing one transition late. Watch PowosTaskLeash "no leash in" logs.
- One WebView per frame (FrameChrome's ShellHost) costs memory with many windows; if > ~8 windows hurts, render frames
  as one shared WebView whose per-window regions are drawn to each SCVH (later).
- The leash reference goes invalid when a task moves display (fold to cover) or is recreated; TaskSurfaces must check
  `isValid` and re-acquire, frames removed while folded (already WindowFrames' rule).
- Non-focusable HOME: desktop widgets can't take keyboard focus; IME-needing desktop UI must live in the chrome layer.
- Trusted-overlay type for the chrome window: with `TYPE_APPLICATION_OVERLAY` untrusted-touch occlusion could block
  taps on apps under its transparent area; use a system type (as OverlayHost does) and confirm in `dumpsys input`.
- Rotation: task surfaces persist, but bounds change; frames relayout on `onTaskInfoChanged`/config, and step 0's clamp runs.

### On-device checks

- SurfaceFlinger: for every freeform task (Android and `PowosWindowActivity`) a `SurfaceControlViewHost` layer of
  com.powos.app under `Task=N`; the chrome window above all `Task=` layers; no PowOS bar overlay windows (`dumpsys window`).
- Screenshot: open the drawer with a Linux terminal and an Android window open -> the drawer and dock are drawn over both.
- Drag a window under the dock: the dock covers it; window A over B covers B's title bar.
- Tap on the wallpaper/widget with windows open: windows stay visible (HOME not raised).
- Tap an app through a transparent part of the chrome window: the app gets it.
- Double tap and mouse double click on a title bar: maximise, again: restore to the clamped previous bounds (both for Android and Linux windows).
- Bounds: drag a window half off the right edge, rotate, fold/unfold, minimise+restore, maximise+restore, kill PowOS and
  reopen the app -> it comes back at its saved place for that screen, title bar fully reachable every time.
- Fullscreen game: no chrome window; recents swipe and page slide still carry the frames (`float-desktops.sh`,
  `linux-float.sh`, `one-title-bar.sh`, `fold.sh`).
