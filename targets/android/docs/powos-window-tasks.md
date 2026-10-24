# PowOS windows as Android tasks

Status: design + first implementation, 2026-10-17. Goal: a PowOS (KWin) window can be its own Android task - its own
card in Recents, OnePlus split screen and floating windows, the app's name - and go back to the desktop.

Replaces the first attempt (a second KWin output per task, commit 70b4941): a fake screen pulled in everything a
screen brings - KScreen's "new screen" chooser, output layout and scale, a placement script - none of which a
window needs.

## How

A window is exported, not moved: it stays a normal KWin window (stacking, focus, shortcuts, its popups), and KWin
draws it into its task's buffers the way it already draws one window for a screencast.

```
PowOS app (app uid)                    display daemon (app uid)            KWin (PowOS session)
 MainActivity (desktop)  --surface 0-->  pairs consumer/producer  <--------  AnlandBackend: output "anland-1"
 PowosWindowActivity #7  --surface 7-->  by surface id            <--------  AnlandWindowTask #7: Dolphin
 SessionService  <======= control relay (open/close/title, closed/focus) =====>  AnlandWindowTasks
```

- **Daemon** (`app/engine/native/andromarchy/andromarchy.c`): pairs a consumer and a producer per surface id (HELLO
  carries the id; none = 0, the desktop - old clients unchanged), and relays control messages between the app and
  KWin (`CTRL_MSG_CONTROL_HELLO` / `CTRL_MSG_CONTROL`).
- **KWin** (`pkgs/kwin` patch 0013, `backends/anland/anland_window_task.*`):
  - `AnlandWindowTasks`: the control channel, D-Bus `org.powos.WindowTasks.show(windowId)` on KWin's bus, and the
    window buttons: the user's **maximize** (title bar button or double tap, window menu, Meta+PgUp - all through
    `Workspace::performWindowOperation`, whose platform hook is patch 0014) makes the window its own Android task
    (full screen; split screen and floating windows are Android's then); maximize in the task, Back, or closing it
    from Recents gives it back to the desktop. A window already maximized keeps KWin's restore, and an app
    maximizing itself doesn't come this way. Minimize and close stay KWin's. Activating an exported window the
    desktop way (the PowOS taskbar) brings its task to the front instead of switching to its desktop.
    An application going **full screen** by itself (a game, Steam Big Picture, a video) gets its own task the same
    way, immersive (`open ... fullscreen`: system bars only on a swipe); leaving full screen, Back or closing the
    task gives it back to the desktop as a normal window. An **Android app's own window** (powos-android-app,
    app id `android-<package>`) maximized or full screen is handed back to Android instead: the window closes, which
    returns the app to the phone's screen, and the PowOS app brings it to the front there (`android <package>`).
  - `AnlandWindowTask`: one per exported window. Its own producer connection (the same handshake and reconnect as
    the desktop output), the task's dmabufs imported as framebuffers. On each buffer the consumer offers, it
    renders the window and its popups (`ItemRenderer::renderItem` on their `WindowItem`s, viewport = the client
    area, at the window's scale) when something changed, else holds the buffer until something does (a keepalive
    frame within the consumer's 5 s), and sends frame callbacks (`framePainted`). While exported the window lives
    on a virtual desktop of its own, "Android tasks" (made on first use, dropped when empty): the desktop neither
    paints it nor sends it input, yet it stays shown, so it can have the focus (hidden or minimized windows can't).
    While the task shows it, it renders offscreen (`refOffscreenRendering`, as screencasts do: not suspended, frame
    callbacks keep coming); its size follows the task (`moveResize` to the buffer size / scale).
  - Input from the task: touch goes to the window or popup under the point (`SeatInterface::notifyTouchDown` on its
    surface - no hit test against the desktop); keys and text through KWin's normal path to the active window -
    the task's focus activates its window.
  - The window closes -> `close <id>`; its caption changes -> `title <id>`.
- **App**: SessionService keeps the control channel: `open` starts `PowosWindowActivity` for that id (a document
  task of its own), `close` finishes it. The activity is a consumer on surface `id`; focus -> `focus <id>`;
  finishing (swiped from Recents, Back) -> `closed <id>`: KWin shows the window on the desktop again at its old
  size and activates it. A task only sent to the background keeps its window (not rendering meanwhile).

Control messages are one line of UTF-8 each, fields separated by tabs: `open <id> <app id> <caption>`,
`title <id> <caption>`, `close <id>`, `android <package>` (KWin -> app); `closed <id>`, `focus <id>` (app -> KWin).
`open` may end in `fullscreen`; `focus 0` is the desktop's task coming to the front (a window shown as its own task
then gives up KWin's focus, so the taskbar activates it instead of minimizing it).

Sessions (kwin 0023): window ids restart at 1 with every KWin, while Android keeps the old window tasks through a
session restart. On connecting, and on the app's `hello 1` (its channel came up after KWin's, so the daemon dropped
what KWin said), KWin sends `caps <words>` and `session <uuid> <id,id,...>`: a uuid made once per KWin process and
the ids of the tasks it has. A task's data is `powos-window://<id>?session=<uuid>` (a new KWin's window 1 is a new
document, not the old one's); WindowTasks finishes every window task - live activity or a Recents entry without one -
that isn't one of the listed ids of that session, telling KWin nothing (`closed <id>` would close the new KWin's
window of that id). Only a live window of the running session is raised again (`open` of a known id, the launcher's
and dock's restoreLinux through WindowTasks.appIdOfTask); anything else opens fresh.

Popups (kwin 0027): a task shows nothing beyond the window's client area, so a window's popups (menus, combo boxes,
tooltips: xdg_popup) are placed inside its task - `Workspace::setPopupAreaHandler` hands the positioner the task's
area instead of the output's, for the window, its dialogs and their popups; the desktop's windows keep the output's.

Title bars (kwin 0026): a task shows the window's client area only, so the app's frame (WindowFrames) adds a bar -
unless the window draws its own. KWin says which before `open` and whenever it changes: `decor <id> 1` (KWin's
decoration: Kate, Dolphin) or `decor <id> 0` (client-side: Steam, GTK header bars - no frame bar, only the grip),
again for every task on `hello`. A drag on a window's own bar asks KWin for an interactive move; KWin cancels it and
sends `move <id>`: the task's activity hands the rest of that touch to the frame's drag (KWin's touch lifted first).

## From the launcher

A PowOS app tapped in the PowOS app's launcher (drawer, home, search, the web shell: `Runtime.launch`) opens like a
phone app, straight into its own task: `session/powos-open-task --app-id <desktop id> -- <Exec>`
(`RootedGuest.openAsTask`). It loads a KWin script that reports windows back to it over D-Bus (the existing ones,
then each new one); if the app already has a window (by app id: desktop file name / resource class) that one is
shown - again a task, or brought to the front if it is one - and nothing starts; else the command starts and its
first normal window (by app id, or by being one of the command's processes) is shown. "Shown" is
`org.powos.WindowTasks.show` (un-minimized first), the same as the title bar's maximize.

The tap also opens the app's launch window at once (LaunchWindows, when the app has no window task): a window task
`powos-window://launch?app=<id>` at the place its window will be, the app's icon and name on it. KWin's first `open`
for that app (its app id matched like the launcher's) becomes that task (PowosWindowActivity.become: the consumer on
its surface), no second task; a full-screen window (a game) gets its own and the launch window goes, as it does when
the helper ends with no window. Android apps have the system's starting window for this.

It prints `powos-open-task: desktop` when the app opens on the desktop instead, and the app then brings the desktop
up: no window tasks (the app isn't connected to KWin), a window KWin doesn't export, nothing within 30 s, or an older
PowOS without the script. KWin itself only comes up once the desktop's task has given it a screen (the producer
handshake waits for the screen info): right after a session start the desktop comes up first, and the app opens as
its own task over it once KWin is there.

## Then

- Every new window opens as its own task (a setting), and a PowOS app launched from Android's own shortcuts
  (PowosShortcuts -> OpenPowosApp) opens straight into one: OpenPowosApp is a no-display trampoline that has finished
  by the time KWin asks for the task, so Android may refuse that start from the background - it needs to stay until
  the task is up (or the window task started from the trampoline itself).
- KWin up without the desktop's task: the anland producer handshake not waiting for the consumer's screen info.
- The desktop's taskbar: an exported window's entry brings its task to the front.
- The Android keyboard in a task (keyboard visibility goes to the desktop's connection today).
- Pointer, scroll and gamepad input from the task; the task's density instead of the desktop's scale.
- Zero copy for single-surface windows: hand the client's own dmabuf to the task (ASurfaceControl) instead of
  rendering it.
