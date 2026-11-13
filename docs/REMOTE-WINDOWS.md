# Remote windows: PowStream into PowOS web windows

Status: **design, 2026-11-13.** Docs only; no code changed with this note. Board task: "Remote windows: PowStream
into PowOS web windows" (project Windows).

The owner, 11-13: **"get PowStream properly implemented on Android with full web-windows integration so that the
remote windows act like native Android apps, so that we can start games and whatever on the desktops and stream it
to the phones with as low latency as possible."**

Sized to the real fleet: one stream source (Desk, `.58`, Bazzite/KDE, RTX 5090), one primary target (OnePlus Open,
SM8550, 120 Hz inner screen 2440x2268), the S25 as the second phone. No multi-tenant broker, no new service on
PowStation, no WebRTC on the native path.

Sources read for this note (PowStream from GitHub `Powback/PowStream` master `eca64b5`, 2026-11-13, a scratch clone;
the owner's local checkout was not touched):

| PowStream | what it says |
|---|---|
| `docs/SPEC-android.md` (2026-07-10, last touched `6f606ee`) | native client, own UDP + RS-FEC wire, MediaCodec H.264 + `KEY_LOW_LATENCY`, SurfaceView, unbuffered touch, milestones A0-A4 |
| `spec-android.md` (2026-07-10) | the long form: Gradle modules mirroring the crates, gap equation (`ADDED_client`), M0 canned-capture conformance (`fec.dat`/`nofec.dat` sha256s), level table, firewalled ATW |
| `stream/SPEC-lan-sub-ms.md` (`267c418`, 2026-07-30) | server <1 ms capture-complete→wire, client <5 ms wire→queued; NvFBC→CUDA→NVENC, slice output, NDK client |
| `docs/SPEC-sub-ms-latency.md` (2026-09-17) | measured on `.58`: KDE screencast emits **~80 fps** (the cap), NVENC p1 1080p ~1.5 ms, transport p50 0.49 ms; native loopback NVENC+swdec 11.4 ms p50 |
| `docs/SPEC-wm-bridge.md`, `docs/SPEC-window-stream.md` | `/wm` control channel (snapshot/added/changed/removed, focus/close/resize/move/subscribe), `capture_hint`, per-window layer capture plan |
| `docs/SPEC-virtual-screen-toggle.md` (`ebb06d6`, 11-13) | live mirror ⇄ virtual-output switch |
| `docs/REMOTE-DESKTOP.md` (`4b39d49`) | B0 now served by `powstream-webrtc-server` on udp/47800; the PoC `powstream-server` is deprecated |
| code: `bins/powstream-webrtc-server/src/{b0.rs,viewer.rs,input_path.rs,main.rs,wm/}`, `crates/powstream-webrtc/src/{au_session.rs,pipeline_parts.rs}`, `crates/powstream-proto/src/lib.rs`, `crates/powstream-inject/src/uinput.rs`, `crates/powstream-client/src/lib.rs`, `bins/powstream-wmd/src/main.rs` | below |

PowOS: `docs/WEB_WINDOWS.md` ("The host snapshot: the contract", "The page's sync", S6 "one window model, two
sources"), `docs/WINDOWS_FIX_PLAN.md`, `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/WebWindows.kt`
(`Win` :695, `LinuxSource` :840, `openLinux` :1373, `linuxCards` :1518, `layerKey` :1873, `place` :2049, buffer
size on resize :2289, `onTouch` :2642, snapshot :197), `WebWindowState.kt` (`WebWindowMachine.Kind` :19),
`docs/research/device-ecosystem.md` (Desk row, L13, D6), `sources/powstream/source.conf`.

---

## 1. PowStream today (master `eca64b5`)

**There is no Android client code on any branch** (remote heads: master, `integrate/master-2026-11` = master,
`feat/b0-in-webrtc-client` and `feat/virtual-screen-toggle` 1 commit ahead each, `feat/atw-mesh-warp`,
`feat/remote-desktop`, `feat/unified-b0`, `fix/atw-pose-pairing`). `feat/audio` (Opus desktop audio) is local-only
on the owner's checkout and was not read.

| piece | where | state | reusable for Android |
|---|---|---|---|
| Live server | `bins/powstream-webrtc-server` (user unit on `.58`, `:8090`, self-signed TLS) | serves WebRTC **and B0** from one capture/sizing/input path (`47452a0`, `f5801d7`, 11-13) | **yes, as-is for phase 1** |
| B0 transport | `b0.rs` | WebTransport (QUIC) on udp/47800; video = QUIC datagrams carrying the wire format (24 B header + RS-FEC, shards sized to the datagram ceiling); input = a reliable uni stream `[u16 len][input datagram]` (`eca64b5`); auth = short-lived signed token from `/b0/session.json` (behind the page login), cert pinned by `certHashHex` | yes: a native QUIC client speaks it unchanged |
| Encoder | `crates/powstream-webrtc/src/au_session.rs` + `pipeline_parts.rs:48` | GStreamer `nvh264enc preset=p1 tune=ultra-low-latency rc-mode=cbr`, **gop = fps (an IDR every second)**, default 60 fps, `--fps` up to the output's refresh | yes; the 1 s IDR must go (§5 R5) |
| Sizing | `viewer.rs` `decide_encode_size` | adopt / `exclusive=1` (a virtual output at the client's size) / fit / mirror; Virtual Screen toggle (`ebb06d6`, `7744cf7`) | yes: "a virtual output at the window's size" is the phase-1 window |
| Capture | `resolve_capture` | X11, KWin direct, portal (`SourceType::{Monitor,Window,Virtual}`, `portal/session.rs:437`) | yes |
| Input | `powstream-proto` `InputEventKind` (:106): `MouseMove`, `MouseButton`, `Key{scancode}`, `ControllerAxes`, `MouseMoveAbsolute` (u16-normalised), `MouseWheel`, `TouchContact{id,phase,x,y}` (Direct Touch); `input_path.rs` → uinput | touch/mouse/keys work; **gamepad: `uinput.rs:279` returns "uinput gamepad not built"**; no text/IME event | codec yes; gamepad + text missing |
| WM bridge | `bins/powstream-wmd` (KWin script ⇄ D-Bus `com.powstream.WindowManager`), `webrtc-server/src/wm/` (`/wm`: `wm.snapshot/added/changed/removed/focus`, verbs `focus/close/resize/move/subscribe`) | events and verbs built; **`wm.subscribe` mints a session but the media path only logs it** (`main.rs` ~1057-1088: the `/ws?session=` id picks no source; the whole output is streamed) | the window list, titles, `app_id`, `pid`, focus/close/resize: yes. Per-window pixels: not yet |
| Native desktop client | `bins/powstream-client-app`, `crates/powstream-client` (`NoopDecoder`, `SwDecoder` ffmpeg, `present.rs` latest-wins mailbox) | speaks the deprecated `powstream-server` raw-UDP path; software decode | the mailbox model and FEC reassembly (`powstream-transport::fec_reassembly`) |
| Android specs | `docs/SPEC-android.md`, `spec-android.md`, `stream/SPEC-lan-sub-ms.md` | specs only | the decode/present/input/Wi-Fi rules all carry over (§3); the transport choice changes (below) |

**One deliberate departure from the Android specs:** they choose raw UDP without TLS against `powstream-server
--transport udp`. That server is deprecated (`4b39d49`); the live process now carries the same wire format inside
QUIC datagrams. The Android client speaks **B0 natively** (Rust `wtransport` client, the crate the server already
uses): zero server work for phase 1, MTU handled by QUIC (the WireGuard-safe shard size of spec-android §3.3 comes
for free), and input already has its reliable lane. The browser costs SPEC-android §0 lists (Chrome's datagram queue,
WebCodecs→canvas, vsync-batched touch) are all browser costs, not QUIC costs. QUIC's own cost (userspace crypto per
datagram) is measured in phase 1 (§5 M4); a raw-UDP lane is added only if that number says so.

---

## 2. Target: a remote window is a web window

One window model, now **three sources** (WEB_WINDOWS.md S6 has two). Everything that places, crops, orders, hides,
hit-tests and moves a window stays the same code; only source-specific steps branch.

| step | Android app (S1-S3) | Linux window (S6) | **Remote window (new)** |
|---|---|---|---|
| content | VirtualDisplay mirror | `powos-ww-<id>-linux` buffer layer, KWin's buffers via `native_consumer.c` | `powos-ww-<id>-remote` buffer layer; `Surface(content)` is **MediaCodec's output surface**: the decoder queues each frame straight into the layer's BLAST queue, SurfaceFlinger composites it at the DOM element. Zero copies after the radio. |
| identity | package | KWin id, `l:<desktop id>` | `r:<source>:<app_id>` key; title, `app_id`, `pid` from `/wm`; icon from the source (PowStream change P6) |
| open | `webwindows.open` | KWin offers → page adopts | page `webwindows.openRemote(source, window, rect)` from the drawer or a `/wm` `wm.added` offer (same adopt/offer shape as `pendingLinux`) |
| size | `VirtualDisplay.resize` | `size <id> w h` to KWin | `wm.resize` (debounced on settle, SPEC-wm-bridge §5) → the source resizes the window and its output → in-band new SPS; MediaCodec configured with `KEY_MAX_WIDTH/HEIGHT` = screen size so a size change is not a codec restart. During a drag the last frame is scaled by the layer's matrix; the new size replaces it |
| input | page / native | native `onTouch` → KWin | native `onTouch` → `remoteBodyAt` → body-relative, u16-normalised `TouchContact`/`MouseMoveAbsolute` on the reliable stream, unbuffered (§3); hardware keys `KeyEvent.getScanCode()` = evdev code → `Key`; gamepad `SOURCE_GAMEPAD` → `ControllerAxes` + buttons; IME text → text event (P7) |
| close | tasks removed | `quit <id>` | bar close → `wm.close`; the card waits for `wm.removed` (2 s rollback, SPEC-wm-bridge) |
| switcher | Android task | `linuxCards` (:1518) | `remoteCards`, same shape (card id range above `LINUX_CARD`) |
| fold / rotate | display resize | `growBuffers` | the body's new size → `wm.resize`; full screen → the screen's size |
| full screen | task on display 0 | KWin maximise | the window's own full screen (bar button) + `wm.resize` to the screen; a game window on the source stays full screen there |

Snapshot contract (WEB_WINDOWS.md): `windows[]` entries gain `remote?: {source, window, session}`; a new
`pendingRemote[]` mirrors `pendingLinux[]` for `wm.added` offers; `WebWindowMachine.Kind` gains `remote` (a source
enum replacing the `linux` boolean is the cleaner shape, done when phase 2 lands). All other fields and the page's sync
are unchanged.

**Several windows per source.** One QUIC connection per remote window at first (mirrors `/ws` per media session in
SPEC-wm-bridge §1); one `/wm` connection per source carries the window list for all of them. Pixels per window: each
streamed window gets **its own KWin virtual output at the window's size**, the window maximised on it. That reuses the
Virtual capture that works today (`exclusive=1` + `keep=1`) instead of the privileged per-window screencast
(SPEC-sub-ms §2.C), and a phone-side resize becomes an output mode change. Vulkan games later take the layer capture
(SPEC-window-stream) for >80 fps.

**Launching from the drawer.** The drawer lists each paired source as a group ("Desk"): its desktop apps and Steam
library (`wm.apps`, P6). A tap sends `wm.launch`; the window that appears comes back as `wm.added` and opens as a
remote web window exactly like a Linux window's offer. A game that goes full screen on the source is shown full
screen on the phone.

**Audio.** One Opus stream per source session (owner's local `feat/audio`), decoded in the Rust core or with
MediaCodec `audio/opus`, played through AAudio `PERFORMANCE_MODE_LOW_LATENCY` + exclusive sharing; no jitter buffer
beyond one packet; clock-matched to video only by playing at once (lip sync is a later measurement, not a buffer).

**Pairing and reach.** LAN-direct first: the phone and Desk are on `192.168.50.0/24`. Device auth follows
device-ecosystem D6: Desk advertises `stream_source`, the phone asks Desk's `powos-deviced` for a stream ticket (`POST
/v1/action {action: "stream_offer"}`), the server checks the ticket on loopback (P10) - PowAuth owns the identities,
PowStream stores none. Off the LAN the phone is a WireGuard peer of the hub; Desk is LAN-only today
(device-ecosystem: "not a VPN peer"), reached through the hub's WireGuard routing to the LAN, or as its own peer once
enrolment (P2 there) gives it one. **TURN is not on the native path**: QUIC over WireGuard covers every case the fleet
has; TURN stays where it already is, the browser/WebRTC tier (`crates/powstream-webrtc/src/ice_servers.rs`, coturn).

**Non-root.** Nothing here needs root: our own SurfaceControl layers, MediaCodec, sockets, AAudio. Remote windows
are a non-root PowOS feature from day one (memory: non-root parity).

**Code placement.** PowStream owns the protocol and a client core: `crates/powstream-client-core` (Rust, `cargo-ndk`
aarch64) with a **C ABI** (`ps_open`, `ps_poll_au`, `ps_send_input`, `ps_stats`, `ps_close`), so PowStream never
names a PowOS Java class. PowOS owns the integration: a JNI shim beside `native_consumer.c`
(`engine/src/main/jni/powstream_jni.c`), `RemoteSource` in `WebWindows.kt`, the page. The APK build takes
`libpowstream_core.so` from PowStream at a pinned commit through `sources/powstream/` (same `source.conf`, an Android
build step), like the Vulkan layer today.

---

## 3. Latency budget (pixel change on Desk → photon on the Open)

`[M]` = measured (cited), `[E]` = estimate to replace with a phase-1 measurement. Phase 1 = 60 fps, portal virtual
output, 1080p-class window; target = 120 fps end to end.

| stage | phase 1 | target (120) | how, on this hardware |
|---|---|---|---|
| capture wait (damage → frame) | 0-16.7 ms, ~8 avg [E] | 0-8.3, ~4 avg | the source output at 120 Hz; KDE screencast measured **~80 fps cap** on `.58` [M, SPEC-sub-ms §1] - for 120: KWin direct/virtual output cadence check (M2), then the Vulkan layer for games (SPEC-sub-ms §2.A) |
| convert / copy | ~1 ms [E] | ~0 | NVENC takes BGRx directly [M, SPEC-lan-sub-ms §1]; DMA-BUF import, no CPU convert |
| NVENC encode (p1, ULL, CBR, no B) | ~1.5 ms [M, 670 fps 1080p] | ~1 ms to first slice | slice output later (SPEC-lan-sub-ms M2); window-sized encode, never the whole 5120x1440 desktop |
| packetize + FEC + send | <0.5 ms [M, 0.49 ms p50 UDP+FEC] | same | + QUIC crypto, measured in M4 |
| Wi-Fi air (Desk wired → GT-AX11000 5 GHz → Open) | 1-3 ms p50, 10+ ms p99 [E] | same; the tail is the enemy | `WifiManager.WIFI_MODE_FULL_LOW_LATENCY` lock while a remote window is in front (power-save batching is 10-100 ms of jitter, SPEC-android §2); 5 GHz asserted; CBR without a 1 s IDR spike (R5) |
| rx + FEC reassembly (Rust core) | ≤0.5 ms [E] | same | one rx thread, latest-wins 1-deep mailbox, request-IDR on a gap, no jitter buffer, no NACK |
| MediaCodec decode (SM8550 `c2.qti.avc.decoder`) | 3-8 ms [E, SPEC-android §4.6] | 2-4 ms | async mode; `KEY_LOW_LATENCY=1` (check `FEATURE_LowLatency`), `vendor.qti-ext-dec-low-latency.enable=1`, `vendor.qti-ext-dec-picture-order.enable=1`, `KEY_PRIORITY=0`, `KEY_OPERATING_RATE=Short.MAX_VALUE`, `KEY_MAX_WIDTH/HEIGHT`; zero-B stream; `releaseOutputBuffer(idx, true)` at once; feed + rx threads in an ADPF `PerformanceHintManager` session (frame-period target) so they land on big cores; HEVC/AV1 (both HW on SM8550) only after H.264 is measured |
| present (latch + scanout) | 0-8.3 ms latch, ~4 avg + panel [E] | same | the layer must stay an **HWC device-composited** layer: opaque, no alpha, no corner radius on the content layer itself (corners on the chrome); `Transaction.setFrameRate(content, 120, FIXED_SOURCE)` so the LTPO panel does not idle down to a low rate while a remote window plays; check `dumpsys SurfaceFlinger` composition type (CLIENT = +1 frame) |
| **pixel → photon** | **~20-30 ms p50** [E] | **≤16 ms p50** | SPEC-android §7: 12-16 ms at 120 |
| input leg (touch → inject) | +5-12 ms [E] | ≤8 ms | `requestUnbufferedDispatch` for a gesture in a remote body; every historical sample sent; reliable QUIC stream (B0 lost taps on datagrams, `eca64b5`); server injects on arrival |

Glass-to-glass method: the S25 films at 240 fps both Desk's monitor (mirror mode, a millisecond clock / flashing
patch full screen) and the Open's remote window; ≥20 samples, p50/p95, frame-counted. Motion-to-photon: the same
film with a finger tapping a patch that flips colour on press. Beside it the core's per-stage ledger (rx first shard,
FEC done, queued, decoder out, released) and `FrameMeta` stamps; cross-machine numbers only after a clock-offset
ping (spec-android §8: never subtract unsynced clocks).

---

## 4. Plan (checklists; each phase lands on its own)

Repos: **PS** = PowStream (owner's; the changes are listed in §6, not committed by PowOS agents), **OS** = PowOS
`main`. Device checks run in a free window on the Open (unfolded, user idle), never touching the user's Steam.

### Phase 1: one remote window from Desk, glass-to-glass measured

- [ ] PS: `crates/powstream-client-core` - B0 client (wtransport), FEC reassembly from `powstream-transport`, `FrameMeta`
  strip, latest-wins mailbox, input on the reliable uni stream, stats ring; C ABI (P1).
- [ ] PS: native session bootstrap - `/b0/session.json` for a paired client without the page login (a pairing secret
  in phase 1, the deviced ticket in phase 5) (P2).
- [ ] PS: AuSession gop = fps → intra-refresh/infinite GOP + IDR on the client's request (P3).
- [ ] OS: `sources/powstream/` Android build step → `libpowstream_core.so` in the engine; JNI shim
  `powstream_jni.c` + `PowStreamCore.java`.
- [ ] OS: `WebWindows.kt` `RemoteSource` (content layer `powos-ww-<id>-remote`, MediaCodec async on `Surface(content)`
  with the §3 keys, Wi-Fi low-latency lock, ADPF hint), `openRemote`, the remote branch of `place` / `onTouch` /
  close; `Kind.remote`; snapshot `remote`.
- [ ] OS: page - a drawer entry "Desk (remote)" opening one window = Desk's virtual output at the body's size
  (`exclusive=1&keep=1`); a debug HUD line in the bar (fps in/out, decode p50, loss, IDRs).
- [ ] Measure first (§5 M1-M4) before tuning anything.
- **Device check:** open "Desk (remote)"; logcat `RemoteSource: connected .58:47800 ... decoder c2.qti.avc.decoder low-latency on`;
  `dumpsys SurfaceFlinger --list` has `powos-ww-N-remote`, composition DEVICE; drag a window on Desk's virtual output
  from the phone (touch reaches it); the S25 film gives pixel→photon and tap→photon p50/p95 at 60 fps; numbers into
  this doc.

### Phase 2: windows, not a desktop

- [ ] PS: `wm.subscribe` streams that window: a virtual output per window, the window maximised on it, `wm.resize` =
  output mode change (P5); icons in `wm.snapshot` (P6); runtime resize without reconnect (P4).
- [ ] OS: one `/wm` per source → `pendingRemote` offers → page adopts as web windows with title + icon; bar close →
  `wm.close`; focus on touch → `wm.focus`; fold/resize → `wm.resize` on settle with origin echo suppression;
  `remoteCards` in the switcher.
- **Device check:** open Kate and Dolphin on Desk → two web windows with their own titles/icons; resize one (Kate
  re-lays out at the new size, no stretch after settle); fold/unfold; close from the bar (window gone on Desk);
  switcher shows both cards.

### Phase 3: launch apps and games, keys and gamepad

- [ ] PS: `wm.apps` (desktop entries + Steam library, icons) and `wm.launch` in `powstream-wmd` (P6); uinput gamepad
  (P7); text commit event (P7).
- [ ] OS: drawer group per source; launch → the offer → a window (a full-screen game → full screen on the phone);
  hardware keyboard scancodes, gamepad (`SOURCE_GAMEPAD`, axes at the device's report rate), IME text.
- **Device check:** launch a Steam game on Desk from the Open's drawer (a verify-queue job, never the user's own
  session); play it with a Bluetooth pad; tap→photon filmed again.

### Phase 4: audio

- [ ] PS: merge `feat/audio` into the B0 session (P8).
- [ ] OS: AAudio low-latency player in the core's thread.
- **Device check:** game audio on the Open; audio-to-video offset filmed (a flash + click test clip).

### Phase 5: pairing and off-LAN

- [ ] PS: accept a deviced stream ticket (P10).
- [ ] OS: Devices app "Stream from Desk" (device-ecosystem D6, P6 there); `stream_source` cap on Desk; wake Desk
  first if asleep; the VPN route to Desk (hub routing or Desk as a peer).
- **Device check:** on mobile data with the VPN up, open a Desk window; revoke the phone in Devices → the next open
  is refused.

### Phase 6: 120 fps and the tail

- [ ] PS: 120 fps capture path (KWin cadence or the Vulkan layer for games), slice output, HEVC/AV1 behind a
  measured switch (P9).
- [ ] OS: decode partial frames if `c2.qti` takes them; present-timing experiment only if the ledger shows a bimodal
  latch.
- **Device check:** ≤16 ms p50 pixel→photon at 120 fps, filmed.

---

## 5. Risks, and what to measure first

| # | risk | measure first (phase 1, before any tuning) |
|---|---|---|
| M1 | MediaCodec on SM8550 holds frames despite `KEY_LOW_LATENCY` | decode harness: a recorded B0 AU dump from Desk replayed into a remote web window's layer, queued→output p50/p95 over 1000 frames (spec-android M0.5 / SPEC-android A0, ≤5 ms gate) |
| M2 | Desk cannot capture at 120 (KDE screencast measured ~80 fps) | frames/s of a virtual output at 120 Hz with a moving test pattern, KWin direct and portal |
| M3 | the remote layer is GPU-composited inside home's window tree, or LTPO drops the refresh rate | `dumpsys SurfaceFlinger` composition type + active refresh rate while a remote window plays |
| M4 | Wi-Fi tail and QUIC cost | RTT/jitter phone↔Desk with and without the low-latency lock; per-datagram QUIC send/recv cost vs the 0.49 ms raw-UDP number |
| R5 | the 1 s IDR (`au_session.rs` gop = fps) puts a bitrate spike on the air every second, the p99 | frame-size trace per frame on the core's ledger |
| R6 | resize loops between the phone's window and the source window (both sides own a size) | SPEC-wm-bridge's `origin` echo suppression + resize on settle only; covered by the phase-2 device check |
| R7 | one-process server state (`viewer_joined`/`viewer_left` snapshot and restore the desktop) assumes one viewer; N window sessions may restore under each other | phase-2 log with 2 sessions open/closed in either order |
| R8 | **biggest:** the window-per-virtual-output model at the source (portal grants, KWin with N extra outputs, games choosing an output) - everything in phase 2-3 rests on it | phase 1 already runs one virtual output; check a second one opens without a dialog before phase 2 starts |

---

## 6. PowStream changes needed (for the owner; not committed from PowOS)

- **P1 `crates/powstream-client-core`**: Rust, `cargo-ndk` aarch64; B0 client over `wtransport` (cert pinned by
  `certHashHex`), `powstream-transport` FEC reassembly, `FrameMeta` strip, latest-wins mailbox, input sender on the
  reliable uni stream, clock-offset ping, per-stage stats ring; C ABI only.
- **P2 native bootstrap**: `/b0/session.json` reachable by a paired native client (pairing secret now, P10 later),
  returning size/fps capabilities with the token.
- **P3 encoder**: `au_session.rs` - no periodic IDR (intra-refresh), IDR on a client request (a control message on
  the session), `--fps 120` per session, the encode size per session.
- **P4 runtime resize**: a control message that resizes the session's virtual output and encoder without a
  reconnect (new SPS in-band).
- **P5 per-window media**: `wm.subscribe` → that window's pixels (`main.rs` ~1057-1088 only logs the session today):
  a virtual output per window, the window maximised on it; Vulkan-layer capture for games later
  (SPEC-window-stream).
- **P6 WM verbs**: icons in `wm.snapshot`/`wm.added`; `wm.apps` (desktop entries + Steam library) and `wm.launch`
  in `powstream-wmd`; `wm.fullscreen`.
- **P7 input**: per-window coordinate mapping for `TouchContact`/`MouseMoveAbsolute`; a uinput gamepad
  (`uinput.rs:279` "not built") with buttons; a text-commit event for IME.
- **P8 audio**: `feat/audio` (local only) merged and carried on the B0 session.
- **P9 120 fps**: capture beyond the ~80 fps screencast cadence; slice output; HEVC/AV1 behind a measured switch.
- **P10 device auth**: validate a `powos-deviced` stream ticket on loopback (device-ecosystem D6), no PowStream
  accounts.
- **P11 multi-session state**: `viewer_joined`/`viewer_left` restore semantics for N concurrent window sessions.
- Docs: `docs/SPEC-android.md` and `spec-android.md` still say raw UDP + `powstream-server`; note B0-over-QUIC as the
  native transport (this note's §1).
