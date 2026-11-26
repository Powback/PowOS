# HDMI in

A PowOS app that shows what a cheap HDMI-to-USB capture dongle sees (a PS5, a Switch, a PC), live, with its sound,
on the phones and on the PowOS desktop. A PS5's DualSense stays paired to the PS5, so consoles need no input
forwarding. For a computer there are PC controls: Remote input over Bluetooth, because the dongle is using the USB port.

Code: `shell/ui/hdmiin.tsx` + `hdmiin.css` (the screen), `shell/hdmiin.ts` (capture session),
`shell/hdmiin-pick.ts` (device choice, constraints, overlay line; tests in `shell/test/hdmiin.test.ts`),
`targets/android/.../shell/HdmiIn.kt` (Android host side), `sources/powos-shell/src/view.cpp` (desktop media
permission).

## What it does

- **Launcher entry "HDMI in"** (`state.ts` `HDMI_KEY = "p:hdmi-in"`). It is PowOS's own app, so it appears on every
  platform without being installed from the registry.
- **Empty state.** "Plug in an HDMI capture dongle" with the PS5 hint: *Settings → System → HDMI → Enable HDCP off*,
  because with HDCP on the dongle gets a blank picture. On Android it checks again every 2 s, and also when the browser
  reports `devicechange`. When Android lists a UVC device on USB but no external camera for it, the screen says the phone
  doesn't offer the dongle to apps (see the native-source step below).
- **Video.** getUserMedia on the dongle's camera, asking for up to 1920×1080 at 60 fps. The browser picks the format the
  dongle offers (MJPEG or YUY2). The track plays in a plain `<video>`: no canvas and no copy, just the engine's own
  path to the compositor.
- **Overlay.** Resolution and fps from the track settings, plus the frames actually shown (measured with
  `requestVideoFrameCallback`) when that number differs. A tap shows or hides the overlay and controls; they also
  fade after 4 s.
- **Audio.** The dongle's mic goes through Web Audio (`MediaStreamSource → Gain → destination`,
  `latencyHint: "interactive"`), never a media element's buffered playback. Echo cancellation, noise suppression and
  auto gain are off. A mute button sets the gain. If autoplay rules suspend the context, the button reads "tap for
  sound".
- **Full screen or window.** Full screen holds the screen on Android: it keeps it awake, hides the bars (a swipe brings
  them back for a moment) and turns to landscape; everything is restored on close. Window mode is a draggable 16:9
  window over home, with the screen kept awake and home still usable. The capture keeps running when you switch
  between the two. On the desktop, the Screen Wake Lock API is used where the engine supports it.
- **PC controls** (keyboard button). Opens Remote input (`ui/remote.tsx`, commit ad1c0a68) as a side panel
  (`remoteBeside`), with its target set to Bluetooth. It is the same screen, not a copy. Back closes the panel first,
  then HDMI in.
- **Plug-in offer** (Android). `HdmiIn$Attach` has a `USB_DEVICE_ATTACHED` filter (`res/xml/hdmi_in_usb.xml`, any
  UVC interface), so Android offers PowOS when a dongle is plugged in. Picking it opens home with HDMI in showing. Plain
  webcams match the filter too.

## Capture path: one web source everywhere

The user changed the scope on 11-26: HDMI in is a PowOS app for the desktop and the phones, not an Android app.
The dongle is a standard UVC camera plus a USB Audio Class mic, so the browser engine already reaches it on every
platform:

| platform | video | audio | native code |
|---|---|---|---|
| PowOS desktop (Linux / Plasma + web shell, QtWebEngine) | V4L2 webcam → getUserMedia, picked by name (`USB Video`, `MS2109`, `MS2130`…), never `Integrated` | ALSA input of the same USB device (same `groupId`), else one named like the dongle; no match means no audio | none. `view.cpp` grants camera/mic to the `powos:` origin only |
| Android, phone camera HAL takes external cameras (Camera2 `LENS_FACING_EXTERNAL`) | WebView getUserMedia, label `camera2 N, facing external`; never front/back | WebView's default input, which Android routes to the USB input while one is plugged in. Used only when `HdmiIn.probe` reports a USB audio input, so the phone's own mic is never played out of its speaker | `HdmiIn.kt`: probe, CAMERA + RECORD_AUDIO request, `onPermissionRequest` grant for the shell origin, screen hold |
| Android without external-camera HAL support | not visible to the WebView or to Camera2 | n/a | needs the native USB source (unchecked step below) |
| desktop browser (shell dev) | same as the Linux desktop | same | none (mock bridge) |

Why this path: no root and no USB permission are needed (non-root parity; the S25 and razr are non-root), the same code
runs on every platform, and the picture goes through the engine's zero-copy video path. Per the brief, Camera2 external
was preferred over a libuvc path. The WebView uses Camera2, so if Camera2 lists the dongle, so does getUserMedia.

HACK notes (each also in the code):
- `hdmiin-pick.ts pickAudio`: Android's WebView has no per-device mic choice, so audio relies on Android's input
  policy (wired, then USB headset, then USB device, then built-in for the MIC source) and on the probe's
  `usbAudioIn`. Real fix: the native source with `AudioRecord.setPreferredDevice` on the dongle's `AudioDeviceInfo`.
- Dongle detection is by label and needs the camera permission once (labels are empty before that). An unnamed external
  camera is used only when it is the only candidate.

## Devices

| device | root | status |
|---|---|---|
| OnePlus Open (SM8550) | rooted | untested with a dongle; external-camera HAL support unknown |
| Samsung S25 | non-root | untested; Samsung has listed USB (UVC) cameras in Camera2 since One UI 6 (unverified on this unit) |
| Motorola razr fold (XT2651-1) | non-root | untested |
| PowOS desktop (QtWebEngine) | n/a | untested with a dongle; needs the powos-shell rebuild that carries `view.cpp` |

Check on each device with a dongle: the launcher entry opens; the empty state shows without a dongle; plugging in
starts the picture (and on Android, the "Open PowOS?" offer); the overlay shows 1920×1080 · 60 fps; sound plays and
mute works; full screen ⇄ window; PC controls panel pairs over Bluetooth; unplugging returns to the empty state;
closing restores the bars and orientation. If a phone shows "A USB video device is plugged in … doesn't offer it as a
camera", it needs the native source below.

## Next steps

- [ ] Native USB source for phones without external-camera HAL support: a Kotlin `UsbManager` + libuvc/libusb source
      (USB permission granted once through the existing `USB_DEVICE_ATTACHED` filter, which also remembers it). It
      would decode MJPEG with MediaCodec straight into a Surface, shown as a native child surface of the web UI
      (docs/WEB_WINDOWS.md), with audio from `AudioRecord.setPreferredDevice(dongle)` → `AudioTrack` (AAudio, low-latency
      mode). The page would pick it when `HdmiIn.probe` lists a UVC device and no external camera.
- [ ] Desktop: HDMI in on the desktop home is a layer under the windows; give it a real window (KWin) or a fullscreen
      surface.
- [ ] Mode picker (when a dongle offers several modes, e.g. 4K30 vs 1080p60 on MS2130) from the track's
      `getCapabilities()`.

### PowStream (stream the capture to other devices)

The seam: `hdmiin.ts captureStream()` returns the live `MediaStream`. A streamer needs only that, not the screen.

- [ ] Encode the capture's video track (WebRTC in the page, or MediaCodec from the native source's Surface: H.264/HEVC,
      low-latency mode) and its audio (Opus).
- [ ] Publish it as a PowStream source (name "HDMI in on <device>") that other PowOS devices can open.
- [ ] Viewer: the same HDMI in screen showing a remote source (a device picker in the empty state).
- [ ] Latency budget measured end to end (glass to glass) on LAN; TURN via `/etc/powstation/turn.env` off-LAN.
