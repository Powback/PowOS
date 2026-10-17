# PowOS windows as Android tasks: implementation plan

Status: plan, 2026-10-17. Implements step 1-3 of [powos-shell-design.md](powos-shell-design.md) ("Anland
multi-output"). Goal: each PowOS (KWin) window is its own Android task: its own card in Recents, OnePlus split
screen and floating windows, the app's name and icon.

## Today: one output

```
PowOS app (app uid)                         display daemon (app uid)        KWin (PowOS session)
 MainActivity SurfaceView                    libandromarchy.so               backends/anland
  -> Native.nativeStart(surface)  --hello+5 fds-->  rendezvous: 1 consumer  <--pickup--  AnlandBackend
     native_consumer.c g_state                       + 1 producer                       -> AnlandOutput "anland-1"
     (gralloc buffers, render thread)  <==== data / fence / buf_ready / shm channels ====> AnlandEglLayer
```

The consumer (the Android side) owns the gralloc buffers and sends them as dmabufs; KWin renders into them
(zero copy) and signals each frame with a fence. Input, clipboard, keyboard visibility, audio and camera share
the same channels. Everything is single: the daemon's consumer/producer slots, `g_state` in native_consumer.c,
static JNI calls, `m_display`/`m_outputs[0]` in KWin's backend (a full list of the single-output assumptions is
in the session notes of 2026-10-17; the main ones are below).

## Slice 1: one KWin window in its own Android activity

Proves the pipeline end to end with no protocol change: a second daemon on a second socket is a second output.

1. **KWin backend** (patch 0013): per-connection state moves from `AnlandBackend` into the output (an
   `AnlandConnection` owned by `AnlandOutput`): `display_ctx*`, consumer-ready flag, fallback state and reconnect
   timer, data/buf-ready notifiers. `AnlandEglLayer` takes the ctx from its output. `notifyFramePresented`,
   `onBufferReady`, `enterFallback`, `onReconnectTimer` become per output; every `m_outputs[0]` goes.
   `mapInputToLogical(output, p)` adds the output's position; touch ids are offset per output so two tasks never
   share one. Audio, camera, clipboard, keyboard visibility and DPMS stay on output 1 (the desktop).
   `ANLAND_SOCKET_2`: output "anland-2" is created lazily once its consumer has connected (the daemon keeps its
   screen info), placed right of output 1 so they don't overlap.
2. **Consumer JNI**: `consumer_state` per surface (heap, handle returned to Java); `nativeStart(surface, socket,
   primary)` / `nativeStop(handle)` / `nativeSend*(handle, ...)`. Audio, camera and clipboard only for the
   primary. The existing static calls stay as wrappers for the primary (MainActivity unchanged).
3. **Session**: SessionService starts a second daemon (`display_daemon-2.sock`); the session exports
   `ANLAND_SOCKET_2`.
4. **Android**: `PowosWindowActivity` (documentLaunchMode="always", resizeable): a SurfaceView consumer on
   socket 2, touch and keys to its handle.
5. **Placement (proof only)**: a KWin script sends a chosen window to output 2, maximized, without decorations.

Done when: a PowOS window shows in its own Android task, takes touch and keys there, resizes with the task (split
screen), and the desktop task keeps working beside it.

## Then

- One daemon with an output id on HELLO/SCREEN_INFO and per-id slots, and a "consumer N arrived/left"
  notification to KWin: outputs come and go with the activities.
- The window control channel (KWin script <-> the PowOS app over D-Bus or the run dir): window opened -> a new
  task with the app's name/icon (setTaskDescription); task closed/resized/focused -> KWin closes/resizes/
  activates; popups and dialogs stay on their parent's output.
- Output focus: the focused task's window gets keyboard focus; `OUTPUT_TYPE_KEYBOARD` goes to that task.
- Launching a PowOS app from Android (PowosShortcuts / the launcher) opens it as its own task, not on the desktop.
- Memory: each output holds min_undequeued+2 screen-size gralloc buffers; hidden tasks shrink or drop theirs.
