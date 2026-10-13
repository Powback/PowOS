# PowOS on phones: Omalauncher's shell, PowOS underneath (design)

Status: design, 2026-10-13. Supersedes the "desktop tile" v1 in [powos-app-plan.md](powos-app-plan.md) as
the target (that plan's phase 0, the app skeleton, still applies).

## What "use it as an OS" means

The user wants Omalauncher's native, instant home screen, and PowOS as the real system: PowOS apps as
first-class Android tasks, widgets backed by PowOS, one drawer for Android and PowOS apps, PowOS's
lock screen. Not a launcher with a desktop app inside it.

## The two existing models

| | Omalauncher | KWin on Anland (ours) |
|---|---|---|
| Window ↔ Android | every Linux toplevel = its own Android task (Recents card, gestures, split screen) | the whole desktop = one Android window |
| Pixels | `wl_shm` only; damage regions `memcpy`'d into `ANativeWindow_lock` buffers (`cpp/wlbridge.c`), vsync-paced per window | client dmabufs imported as EGLImages on KGSL, rendered into daemon-provided gralloc buffers, zero CPU copies |
| GPU apps | render on GPU, read back to shm (`MESA_VK_WSI_DEBUG=sw`), Mali only | native (Adreno via KGSL) |
| Protocol coverage | small Kotlin server: core, xdg-shell, seat, data device | full KWin: Xwayland, layer-shell, portals, Plasma |
| Runtime | proot | lotfix (patched loader, no proot) |

## The combination

- **Shell** (Android side, Kotlin/Compose): the Omalauncher fork is HOME: home grid, OWL widgets,
  themes, the bar, drawer listing Android apps and PowOS `.desktop` apps.
- **Compositor**: KWin in the PowOS rootfs, Anland backend extended to **one output per Android
  window**. Each PowOS toplevel is placed alone, maximized, on its own output; the output's buffers
  come from that window's Android `SurfaceView` (dequeued gralloc buffers, as Andromarchy already does
  for the single desktop window). GPU path end to end, no CPU copies.
- **Window control channel**: a small protocol between the shell and KWin (D-Bus or a KWin script):
  window created/titled/closed → shell creates/updates/finishes the Android task (Recents label,
  icon); task focused/closed/resized → KWin activates/closes/resizes the window. Input per output
  over Anland's existing input path.
- **Desktop mode**: the same KWin session can also drive one big output with the full Plasma desktop
  (unfolded Open, external display): today's working path.
- **System**: PowOS rootfs on Andromarchy's runtime (no proot); OS updates as pacman packages.

## What has to be built

1. Anland multi-output: the Andromarchy display daemon (`apk/native/andromarchy`, `jni/native_consumer.c`)
   and protocol (`protocol.h`) carry an output id; KWin's backend (`backends/anland/`) creates/destroys
   `AnlandOutput`s on demand, each with its own buffer set, fences and input routing.
2. KWin placement: a KWin script/rule pinning each toplevel to its own output, maximized, no decorations;
   popups and dialogs stay on their parent's output.
3. Shell side: Omalauncher's `WindowManager`/`LinuxWindowActivity` re-pointed from its own compositor to
   the control channel, each activity hosting an Anland consumer surface instead of `WindowRenderer`.
4. Drawer + launch: `.desktop` listing from the PowOS rootfs; launching runs the app in the KWin
   session's environment; the window arrives as a new task.
5. Widgets: OWL `cmd`/`stream` sources executed through lotfix in the session environment.

## Risks

- Memory: one gralloc buffer set per open window (2-3 buffers × screen size); cap open windows or
  shrink hidden ones.
- Anland's single-consumer assumptions in the daemon (fallback/reconnect logic) need care per output.
- Kept from Omalauncher: none of its compositor; only shell UI, widgets, themes, window/task glue.
