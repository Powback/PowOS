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
  - `AnlandWindowTasks`: D-Bus `org.powos.WindowTasks.show(windowId)` on KWin's bus, and the control channel. The
    window menu's "Open as Android task" (KWin script `powos-window-tasks`) calls it.
  - `AnlandWindowTask`: one per exported window. Its own producer connection (the same handshake and reconnect as
    the desktop output), the task's dmabufs imported as framebuffers. On each buffer the consumer offers, it
    renders the window and its popups (`ItemRenderer::renderItem` on their `WindowItem`s, viewport = the client
    area, at the window's scale) when something changed, else holds the buffer until something does (a keepalive
    frame within the consumer's 5 s), and sends frame callbacks (`framePainted`). While the task shows it the
    window is hidden on the desktop (`Window::setHidden`) and kept rendering (`refOffscreenRendering`, as
    screencasts do: not suspended, frame callbacks keep coming); its size follows the task (`moveResize` to the
    buffer size / scale).
  - Input from the task: touch goes to the window or popup under the point (`SeatInterface::notifyTouchDown` on its
    surface - no hit test against the desktop); keys and text through KWin's normal path to the active window -
    the task's focus activates its window.
  - The window closes -> `close <id>`; its caption changes -> `title <id>`.
- **App**: SessionService keeps the control channel: `open` starts `PowosWindowActivity` for that id (a document
  task of its own), `close` finishes it. The activity is a consumer on surface `id`; focus -> `focus <id>`;
  finishing (swiped from Recents, Back) -> `closed <id>`: KWin shows the window on the desktop again at its old
  size and activates it. A task only sent to the background keeps its window (not rendering meanwhile).

Control messages are one line of UTF-8 each, fields separated by tabs: `open <id> <app id> <caption>`,
`title <id> <caption>`, `close <id>` (KWin -> app); `closed <id>`, `focus <id>` (app -> KWin).

## Then

- Every new window opens as its own task (a setting), and a PowOS app launched from Android (PowosShortcuts, the
  launcher) opens straight into one.
- The desktop's taskbar: an exported window's entry brings its task to the front.
- The Android keyboard in a task (keyboard visibility goes to the desktop's connection today).
- Pointer, scroll and gamepad input from the task; the task's density instead of the desktop's scale.
- Zero copy for single-surface windows: hand the client's own dmabuf to the task (ASurfaceControl) instead of
  rendering it.
