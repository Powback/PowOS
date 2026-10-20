# Smart glasses: Even Realities G2 (and G1) as a PowOS device

The glasses are a first-class PowOS display, input and microphone on the phone (OnePlus Open, rooted PowOS). The
PowOS app talks to them over raw BLE - no Even app in between - with the user's own BLE work, ported:
`android-app-dev/projects/webview-bridge-gradle/.../bluetooth/g2/G2BluetoothModule.java`, `g1/G1BluetoothModule.java`,
`protocol/G1Protocol.java`, `protocol/G2Protocol.java` (specs: `android-app-dev/projects/references/even-realities/`).

## Architecture

```
 shell pages (home, ...)            the glasses' screen                      PowOS (Linux)
 powos.glasses.* + events           index.html?mode=glasses                  powos glasses ...
 ui/glasses.tsx (pair, preview)     glasses/surface.tsx + glasses/hud.tsx    lib/apps/powos-glasses
          |                         (off-screen WebView, while connected)            |
          | ShellBridge "glasses.*"            | ShellBridge "glasses.*"              | run/glasses/cmd/<id>.json
          v                                    v                                      v  run/glasses/status.json
 +-------------------------------------------------------------------------------------------------+
 | glasses/Glasses.kt (object): the paired pair (prefs), the one GlassesDevice, clients, the       |
 | surface page (ShellHost "glasses"), the command folder (FileObserver), status.json, worn policy  |
 | GlassesService (foreground, connectedDevice) | GlassesPairActivity (CompanionDeviceManager)     |
 | GlassesPresenceService (CompanionDeviceService: "in range again")                                |
 +-------------------------------------------------------------------------------------------------+
          | GlassesDevice (interface: connect/disconnect, state, events, showText/showImage/clear/setMic)
          v
   G2Glasses (two BleArm links, auth, heartbeat,        G1Glasses (two Nordic UART BleArm links,
   teleprompter, render channel, Conversate)            text 0x4E, BMP 0x15/0x20/0x16, mic 0x0E)
          |                                                    |
   G2Protocol (pure bytes, JVM-tested)                  G1Protocol, Raster (pure, JVM-tested)
```

- **`targets/android/app/app/src/main/kotlin/dev/omalauncher/glasses/`**
  - `G2Protocol.kt`, `G1Protocol.kt`, `Raster.kt` - packet building/parsing and pixel conversion, no Android: the bytes
    are checked by JVM tests against the community reference that drove real glasses.
  - `BleArm.kt` - one arm's GATT link with the module's hardware-learned timings (no MTU before discovery, discovery
    from the cache 2 s after connecting, one retry at 22 s, a 30 s connect timeout, two reconnects of a link that
    dropped before discovery). Left out on purpose: the module's third step, `removeBond()` by reflection - it
    silently deletes the user's system bond.
  - `G2Glasses.kt` / `G1Glasses.kt` - the two transports behind `GlassesDevice` (`GlassesDevice.kt`).
  - `Glasses.kt` - the device as PowOS uses it; `GlassesService.kt`, `GlassesPairActivity.kt`, `GlassesImages.kt`.
- **`shell/glasses/`** - `surface.tsx` (the glasses' screen page), `hud.tsx` (its default app), `api.ts` (what a glasses
  app gets), `frame.ts` (text/pixels of a frame, change detection, pacing), `open.ts`; `shell/ui/glasses.tsx` (the
  phone's glasses screen), the control center's glasses tile (`ui/control.tsx`).
- **`lib/apps/powos-glasses`** - `powos glasses` (units: `units/phone/glasses-cli.json`,
  `units/phone-android/glasses.json`).

## What's verified on hardware - and what isn't

| Part | Status | Source of the claim |
|---|---|---|
| G2 connect, 7-packet auth, MTU 512 after auth, heartbeat (500 ms, then 15 s) | **verified** by the user's module on real G2 | `android-app-dev/g2-auth-complete.png` ("Auth OK"), the module's comments (link drops ~1.5 s after auth without traffic) |
| G2 teleprompter text (0x0E-20 config, 0x06-20 init/pages/marker, 0x80-00 sync) | **verified by the community reference** (`even-g2-protocol` teleprompter.py, "Teleprompter: Working"); the module marks it working | the JVM tests check our bytes equal teleprompter.py's |
| G2 input events (click, double, scroll top/bottom, foreground) | the module's decoding (Even Hub SDK event enum); the exact BLE service carrying them is *not documented* - decoded as "any non-auth, non-known service with `08 xx`" exactly as the module did | **unverified** on hardware by this port |
| G2 microphone (Conversate 0x0B-20 open/close) and its audio / on-glasses transcript | ported as is; **unverified**. The frame size is inconsistent: "40 bytes per 10 ms frame, PCM S16LE 16 kHz" - 10 ms of that PCM is 320 bytes, 40 bytes/10 ms is LC3 at 32 kbit/s. Passed on as `codec: "pcm_s16le"` with this caveat | - |
| G2 pictures over the 0x6401 render channel (display wake 0x04-20, `15 00 00 1C 00 00` fragments) | **unverified guess** (the module derived it from the G1's bitmap framing; the spec says the channel's format isn't reverse-engineered; the Even Hub SDK's image containers are 200x100 max). Off unless the `g2Raster` option is on | `G2Protocol.renderFragments` |
| G2 clear | no command known: an empty teleprompter page (a registered workaround, `docs/REMOTE-POWOS.md` §4) | - |
| G2 wear detection | **none known**: the display is never blanked for "off the face" on the G2 | - |
| G2 services the module marked `unverifiedServiceId` (navigation, menu, settings, translate, Even AI, ring, case, EvenHub containers) | **not ported** | - |
| G1 (Nordic UART, text 0x4E, BMP + CRC32, heartbeat 8 s, events 0xF5, battery 0x2C, mic 0x0E/0xF1) | the user's module, itself after Even's EvenDemoApp and MentraOS; **not tested on G1 hardware by this port** | JVM tests check the framing |
| Android side (companion pairing, presence, foreground service, the off-screen page) | **built, not yet run on the phone** | - |

## The glasses' screen

The glasses show a shell page: `index.html?mode=glasses` (`shell/glasses/surface.tsx`), which the app loads in an
off-screen WebView of its own (as the gate test's page) while the glasses are connected, and drops a minute after they
aren't. It renders the picked **glasses app** at the glasses' canvas size (G2 576x288 at 4 bits, G1 576x136 at 1 bit)
and pushes what it shows:

- **text mode** (the G2, unless `g2Raster` is on): the page's text (`innerText` of the canvas box) goes through the
  glasses' own text rendering - the G2's teleprompter (25 characters a line, ~7 lines in view; the glasses scroll it
  themselves), the G1's text screen (40 x 5);
- **image mode** (the G1; the G2 with `g2Raster`): the page's pixels, drawn through an SVG foreignObject into a canvas,
  sent as a PNG (the app converts: 4-bit greys, or a Floyd-Steinberg 1-bit BMP);
- only on change (text compared, pixels compared at the glasses' depth), at the glasses' pace (G2 text 3 s - its
  sequence takes ~2.5 s; G1 text 0.8 s; pictures 3 s), the newest frame winning.

**The HUD** (`shell/glasses/hud.tsx`, the default): the time and date, the newest notification (the shell's
notifications), PowOS AI's last reply. Tap: next view (home / notifications / PowOS AI). Double tap (G2): talk to
PowOS AI - the glasses' microphone and their own recognition; the final transcript is sent as a message and the reply
shows. Scroll: through a view (on the G2 in text mode the glasses scroll; reaching an end goes to the previous/next
view). The clock ticks each minute, except in the G2's text mode (each change re-sends the whole text: there the
time is that of the last change).

**Your own glasses app**: any PowOS app can have one - its manifest's `"glasses": { "entry": "glasses.js" }`, an ES
module in its UI whose default export is a Preact component, rendered with `{ glasses, host }`:

```tsx
export default function MyGlasses({ glasses }) {
  glasses.useInput((input) => { /* "click" | "double" | "up" | "down" | "headUp" | "headDown" ... */ });
  const { cols, rows, mode } = glasses.view; // text mode: lay lines out to cols x rows
  return <div class="glasses-hud">{/* white on black */}</div>;
}
export const prefers = "text"; // optional: always text, even where pictures work
```

Pick it on the phone's glasses screen ("On the glasses: ..."). It hot-reloads like its page (`powos app ui`/`dev`);
the HUD and the surface are shell files (`shell/push.sh`). `glasses.live` is false in the phone's preview (act for the
wearer - microphone, messages - only when it's true).

## Pairing (what the user does)

1. Bluetooth on. Take the glasses out of the case (or put them on) - their arms advertise as `Even G2_xx_L_...` /
   `..._R_...` (G1: `G1_xx_L_...`). If the Even app is connected to them, close it (one central at a time).
2. On the phone: pull the control center (right half of the status bar) -> the **glasses** tile -> **pair**. Android's
   own dialog lists nearby Even arms: pick one; a second dialog asks for the same pair's other arm. (Companion
   pairing: the system scans, PowOS needs no location permission.)
3. They connect: left arm, auth, then the right arm. The tile and the glasses screen show "connected"; the glasses show
   the HUD. From then on they reconnect by themselves whenever they're in range (Android's background connect, and the
   companion presence callback) until **disconnect** or **forget**.

The G1 pairs over standard BLE pairing: expect Android's pairing confirmation per arm on the first connect.

## API

**Shell bridge** (`shell/types.ts` `Bridge.glasses`, mock in `shell/bridge.ts`): `state()`, `pair()`, `forget()`,
`connect()`, `disconnect()`, `showText(text)`, `showImage(dataUrl, dither?)`, `clear()`, `mic(on)`, `audio(on)` (opt in
to PCM events), `surface(on)` (the page that is the glasses' screen), `reload()`, `option(name, value?)` (`g2Raster`).
Events: `glasses.state` (GlassesState), `glasses.input` ({ input, side }), `glasses.transcript` ({ text, final }),
`glasses.audio` ({ data: base64, codec, rate, side } - only to pages that asked), `glasses.message` ({ text, seconds }:
`powos glasses show`, to the surface), `glasses.reload`.

**Kotlin**: `GlassesDevice` (`glasses/GlassesDevice.kt`) - `model`, `state: StateFlow<GlassesState>`,
`events: SharedFlow<GlassesEvent>` (Input / Worn / Battery / Audio / Transcript), `connect()`, `disconnect()`,
`showText()`, `showImage(GlassesImage.Gray4 | Bmp1)`, `clear()`, `setMic()`, `imageVerified`. `Glasses` is the one
owner of it; nothing else opens GATT links to the glasses.

**PowOS**: `powos glasses [status [--json] | show TEXT [--seconds N] | clear | connect | disconnect | mic on|off]`.
Commands are JSON files moved into the app's run dir (`/run/powos-app/glasses/cmd/`), answered in
`/run/powos-app/glasses/status.json` (the app's state + `last`). `show` goes to the glasses' screen page as a message
(over the HUD until a tap or N seconds), or straight to the glasses when that page isn't up.

## Power

Connected and idle, the only radio traffic is the protocol's heartbeat (G2 every 15 s, G1 every 8 s). A dropped arm
waits in Android's background connect (the controller watches for its advertising: no timer of ours). Frames are pushed
only when what's shown changed. The G1 says when it's off the face: the display is cleared and nothing is pushed until
it's back. The screen page exists only while connected (+1 min). `GlassesService` is a foreground service only while
the glasses are wanted.

## Tests

- JVM (`targets/android/app/app/src/test/kotlin/dev/omalauncher/glasses/`): `G2ProtocolTest` (CRC-16/CCITT check value,
  varints, the 7 auth packets, display config, teleprompter init/page/marker/sync and the heartbeat byte-for-byte
  against teleprompter.py's output; sequence order/numbering; page formatting; parsing; input/transcript decoding;
  render fragments; arm names), `G1ProtocolTest` (heartbeat, text, CRC32, BMP header/rows/inversion, image packets,
  events), `RasterTest` (luma, 4-bit packing, dither).
- Tier 1: `test/tier1/test-glasses-cli.py` (`powos glasses` against a stand-in app).
- The shell gate boots `?mode=glasses` against the mock (`shell/dev/gate.sh`); `shell/dev/glasses-check.sh` drives that
  page in the same headless Chromium and checks what it sends: text in text mode, a new view on a tap, nothing while
  unchanged, a PNG with lit pixels in image mode. In a desktop browser the page shows the frame, Enter/Space/arrows
  standing in for the touch bars.

## Open / next

- Run it on the phone with the G2: pairing dialogs, auth on both arms, teleprompter text, which input events arrive
  (and on which service), whether Conversate's audio is PCM or LC3, whether the off-screen page keeps time with the
  screen off (Doze can delay its timers).
- The G2's real display protocol (render channel framing, containers) from an HCI capture of the Even app - then the
  picture path can be on by default; a G2 clear/exit command; a wear signal for the G2.
- Glasses microphone into the assist mode as a recognition source (today: the HUD's double tap -> the G2's own
  transcript -> PowOS AI; raw audio is a bridge event).
