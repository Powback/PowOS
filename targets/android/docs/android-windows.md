# Android apps as PowOS windows (design)

Status: design, 2026-10-13. Goal: an Android app (WhatsApp...) opens as a normal window in the PowOS (KDE
Plasma) desktop: taskbar entry, move/resize/snap by KWin, keyboard and touch, no streaming encode.
Today (step 1) Android apps open in a floating Android window over the desktop (AndroidApps.java,
`android-request float`).

## How

Per Android app, the PowOS app creates an Android **virtual display**, launches the app onto it, and passes
the frames it renders to KWin as a Wayland window's buffers. Input to that window goes back to the app.
This is the mechanism of Samsung DeX / scrcpy's `--new-display`, ending in KWin instead of a video stream.

```
Android app ──renders──> VirtualDisplay surface (ImageReader, HardwareBuffer, GPU usage)
                              │ AHardwareBuffer -> dma-buf fd (per frame, SCM_RIGHTS)
                              ▼
               android-window (Linux, in the PowOS rootfs): a Wayland client per app
                 zwp_linux_dmabuf_v1 -> wl_buffer -> xdg_toplevel (title, app_id = android.<package>)
                              │ KWin composites it like any window (GPU, KGSL Mesa)
               pointer/touch/keys/resize <─┘ back over the same socket
                              ▼
Android: inject events into that display; resize the virtual display on window resize
```

## Permissions: Shizuku

A normal app may create virtual displays but may not launch other apps onto them or inject input into
them (shell-level). Without root that is **Shizuku** (started once via Wireless debugging): the PowOS app
calls, through Shizuku's binder:
- `IDisplayManager.createVirtualDisplay` with `VIRTUAL_DISPLAY_FLAG_PUBLIC | OWN_CONTENT_ONLY | TRUSTED`
  (trusted displays can host other apps' activities);
- `IActivityTaskManager.startActivity` / `am start --display <id>` for the app's launch intent;
- `IInputManager.injectInputEvent` with the event's displayId set.
Without Shizuku, PowOS falls back to step 1 (floating Android windows).

## Pieces

1. Engine (Java): `AndroidWindows` service: Shizuku binder wrappers; per app: VirtualDisplay + ImageReader
   (RGBA_8888, `USAGE_GPU_SAMPLED_IMAGE | USAGE_GPU_COLOR_OUTPUT`), frame -> dma-buf fd to the Linux side;
   input injection; resize (`VirtualDisplay.resize`); app exit -> window close.
2. Linux (C): `android-window <package>`: Wayland client; one socket per window under $XDG_RUNTIME_DIR;
   dmabuf import (Mesa KGSL exposes linux-dmabuf through KWin); frame callbacks pace the Android side.
3. AndroidApps.java: the .desktop Exec becomes `android-window <package>` when Shizuku is available.
4. KWin: nothing special; window rules can give Android windows a default size per form factor.

## Risks

- Samsung One UI behaviour with trusted virtual displays (DeX uses the same machinery: likely fine).
- Apps that refuse non-default displays (some banking/DRM apps): they stay on the floating fallback.
- Memory: one buffer set per open Android window.
