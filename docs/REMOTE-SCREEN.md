# Remote screen — the computer's screen on the phone, over the same USB cable

Remote input (commit `ad1c0a68`) made the phone a computer's keyboard and touchpad: USB HID functions on the phone's
own gadget (root, `assets/remote-input/hidg.sh`) or the Bluetooth HID device profile. Remote screen adds the other
direction: the computer's picture on the phone, full screen, with the touchpad and keys floating over it, and a touch
on the picture is a touch on the computer. No extra hardware: the cable that already carries the keyboard carries
the picture.

## Design

```
 computer (Linux, PowOS desktop first)                         phone (PowOS Android)
 ───────────────────────────────────────                       ──────────────────────────────────────────────
 xdg-desktop-portal ScreenCast → PipeWire                       Remote input → Screen (shell/ui/remote.tsx)
   → PowStream powstream-webrtc-server                            RTCPeerConnection (WebView) ← video
     (hardware H.264, webrtcbin)            ──WebRTC media──▶     <video> full screen, touch = 0x07 TouchContact
     /ws signalling, "input" data channel   ◀─signalling──        RemoteInput.kt: native ws:// relay of /ws
   :8092 plain, IPAddressAllow = cable only                       keys/touchpad: HID reports (USB or BT), as before
 enx02706f770001  10.77.0.1/30   ════ USB cable (NCM) ════        ncm.powos function, 10.77.0.2/30
```

- **(a) The link.** `hidg.sh net up` adds a USB **NCM** network function (`ncm.powos`, linked as `powos_net`) to the
  same configfs gadget as the HID functions, the same way: its own link name so `init.qcom.usb.rc` never removes it,
  the UDC rebound directly, never `sys.usb.config=none` (adbd keeps running). Fixed MACs (`02:70:6f:77:00:01` host,
  `:02` device) make the computer's interface always `enx02706f770001`. The phone end is `10.77.0.2/30`; an `ip rule
  to 10.77.0.0/30 lookup main pref 9000` lets app sockets use the link although Android's netd doesn't manage it
  (HACK, marked in hidg.sh; the real fix is a NetworkAgent, system app only). `net down` is the rollback.
  - **Non-root fallback:** Android's own USB tethering (the computer gets a DHCP address on an
    `rndis_host`/`cdc_ncm`/`cdc_ether` interface; `powos stream cable` finds it and allows its subnet) or the LAN /
    WireGuard (`--allow <cidr>`); the phone side types the computer's address into the Screen panel.
- **(b) The sender is PowStream's**, unchanged: `powstream-webrtc-server` (portal ScreenCast → PipeWire → hardware
  H.264 → WebRTC, its `/ws` offer/answer/ice JSON signalling and its `input` data channel with its own input wire
  format, `PowStream/docs/REMOTE-DESKTOP.md`). No new protocol. `powos stream cable` (lib/stream.sh) runs a second
  instance of it next to the LAN one: `--no-tls --port 8092`, as a transient **system** unit running as the user in
  their session (portal/PipeWire/display env passed), with `IPAddressDeny=any` + `IPAddressAllow=localhost
  <cable subnet> [--allow …]` — only the cable can reach it, so the cable is the credential (`POWSTREAM_NO_AUTH=1`,
  as the main unit already runs, but without its LAN exposure). Mirror mode (no `vw/vh`): the computer's monitor is
  never re-moded for the phone. Its own capture dump dir so it never flips game capture for the LAN instance.
- **(c) The phone side.** `shell/remote-screen.ts` is a PowStream WebRTC receiver (the same steps as PowStream's
  `web/webrtc/index.html`): host candidates only (`iceServers: []`), jitter buffer target 0. The page is
  `https://shell.powos`, so a `ws://` socket from it would be mixed content: on the phone the signalling socket is
  native (`remote.screen(url)` / `remote.signal(text)` / `"remote.screen"` events in RemoteInput.kt, reusing
  `VoiceSocket`'s RFC 6455 client, writes on its own thread); in a desktop browser the page opens it itself. Touch on
  the picture → `0x07 TouchContact` (slot, up/down/move, u16 x/y over the letterboxed picture) on the data channel,
  i.e. PowStream's uinput touchscreen on the computer. The touchpad and keys overlaid on the picture keep sending HID
  reports (USB/BT) exactly as without the screen.
- **HDMI in:** not hooked. Its PC-mode panel already opens Remote input (`shell/ui/hdmiin.tsx`), and with a capture
  dongle the picture is already on the phone; Remote screen is the dongle-free alternative from the same panel.

## Done (2026-11-27)

- [x] `hidg.sh net up|down|status`: NCM function on the gadget, phone address + routing rule, rollback
- [x] RemoteInput.kt: `remote.net(on)` (restored at next start like USB/BT), `net` in `remote.state`;
      `remote.screen(url|null)` / `remote.signal(text)` + `"remote.screen"` events (native PowStream signalling relay)
- [x] `shell/remote-screen.ts`: PowStream WebRTC receiver, input data channel, TouchContact encoding, letterbox mapping
- [x] `shell/ui/remote.tsx`: "Screen" chip → setup (cable link on/off, "Over the cable", or an address for
      LAN/VPN/tethering) → full-screen picture with progress/failure + retry, touchpad and keys toggles over it
- [x] `powos stream cable [--allow CIDR]… | stop | status` (lib/stream.sh)
- [x] tsc clean

## Checklist (needs a phone + a Linux PC on a cable)

- [ ] `hidg.sh net up` on the Open: HID keyboard/mouse still work, `adb` stays up, the PC shows `enx02706f770001`
      (`ip link`), replug + `sys.usb.config` change keep it (as the HID links)
- [ ] Phone: `ip rule` has the pref-9000 rule; `ping 10.77.0.1` from an app context (e.g. `run-as`/the shell page)
- [ ] PC: `powos stream cable` → `systemctl status powstream-cable` active; `curl http://10.77.0.1:8092/` from the
      LAN is refused, from the phone it answers (IP filter works; check `IPAddressAllow` took effect)
- [ ] Portal consent dialog appears on the PC's own monitor the first time (`powos stream setup` pre-seeds it)
- [ ] Phone: Screen → Over the cable → first frame; latency feel; 120 Hz panel
- [ ] **WebRTC ICE over an interface ConnectivityManager doesn't know** — the main risk: if Chromium's network list
      (WebView) skips `ncm0`, no candidate pair forms ("connection failed"). Fallback then: USB tethering (a network
      Android manages) or registering the link properly (NetworkAgent from the privileged side)
- [ ] Touch on the picture lands where touched (letterbox mapping, rotated phone); two fingers; lift on close
- [ ] Keys/touchpad over the picture still go via HID; text field + phone keyboard over the video
- [ ] Non-root: USB tethering on → `powos stream cable` picks the tethering interface → connect by its address
- [ ] `net down` rollback leaves the gadget as Android had it (HID functions untouched)

## Next steps

- Windows/macOS senders: PowStream has no Windows/macOS capture yet; Windows 11 has an NCM driver
  (UsbNcm), macOS has CDC-NCM in-box. Sender = PowStream's server once its capture backends exist there
  (Windows: Desktop Duplication / WGC → Media Foundation/NVENC; macOS: ScreenCaptureKit → VideoToolbox).
- Native decode instead of the WebView: `PowStreamReceiver` (B0, `docs/REMOTE-WINDOWS.md`) once its trusted
  bootstrap exists — lower latency, SurfaceView, no WebRTC jitter logic.
- Keyboard over the data channel (evdev, `0x03`) when no HID target is picked (non-root without Bluetooth).
- Auto-start: a udev rule on PowOS desktops starting `powstream-cable` when `enx02706f770001` appears.
