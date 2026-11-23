# Native window remoting: showing remote windows above pixels

Status: **research, 2026-11-23.** Docs only. Companion to `docs/REMOTE-WINDOWS.md` (PowStream pixel streaming into
web windows) and `docs/WEB_WINDOWS.md` (Linux windows as native child surfaces on the OnePlus Open).

The owner, 11-23: "Lets do some research and see if we can unlock a new native streaming technique, maybe we can even
run games halfway natively somehow? atm im mostly just curious about regular windows like idk firefox and chrome and
whatever". Earlier: "we are running basically the same os on all devices, can't we directly sync the application
state ... so the servers do the heavy lifting and we just render the window and its internal state natively". Scope
addition (11-23): "Maybe some memory sharing and instruction rerouting or blocking or something idk, think state of
the art" (§5).

Fixed facts for every row below:

- The phone (OnePlus Open, SM8550, arm64) and the servers (`.58`, gpu-195, x86-64) differ in ISA. Binaries cannot
  migrate; protocol messages, rendering commands, files and URLs can.
- The phone already runs KWin (anland patches) in its Arch Linux ARM userland; every Wayland toplevel KWin owns is
  shown as a native child surface of a PowOS web window (`WEB_WINDOWS.md` S6). **Any technique that makes a remote
  app a Wayland client of the phone's KWin inherits the whole web-windows integration for free.**
- PowStream's budget (REMOTE-WINDOWS.md §3): pixel→photon ~20-30 ms p50 in phase 1, ≤16 ms target at 120 Hz; input
  leg +5-12 ms. Wi-Fi air 1-3 ms p50, 10+ ms p99 (estimate there).
- Measured here, 2026-11-23, from the Mac (wired): `ping` to `.58` 0.32 ms avg (0.26-0.41), to gpu-195 0.32 ms avg
  (0.24-0.43), 20 samples each. The wired LAN is not the constraint; the phone's Wi-Fi leg (2-10 ms RTT, long tail)
  is. Nothing was installed or run on the phone for this note.

Legend: `[S]` = read in a cited source, `[M]` = measured here, `[E]` = my estimate (to be replaced by a measurement),
`[K]` = background knowledge not re-read for this note.

---

## 1. Where a window can cross the network

From the bottom up, the layers of a Firefox/Chromium window on Linux, and what would cross the wire at each:

| layer | what crosses | who rasterizes | example |
|---|---|---|---|
| 0. application state / session | URLs, scroll offsets, form data, cookies, profile | the phone, natively | browser sync, hand-off |
| 1. web content (DOM/CSS) | DOM mutations | the phone's browser | Menlo "DOM mirroring" (§2.4) |
| 2. browser compositor | layer tree + display lists (Chromium cc / Firefox WebRender DL) | the phone (vector) | Blimp (removed 2017), Menlo Smart DOM |
| 3. paint-op stream | serialized Skia ops (Chromium OOP-R) | the phone's GPU | none in production across a network |
| 4. GPU API | Vulkan/GL command streams | the phone's GPU | Venus, gfxstream, Juice |
| 5. toolkit | render nodes / scene graph | the phone | GTK4 Broadway, Qt WebGL QPA |
| 6. display protocol | Wayland messages + buffer contents (diffed or video) | the server | waypipe, Xpra |
| 7. pixels | encoded video of a window or output | the server | PowStream, Xpra video, Moonlight-class |

Higher layers win on bandwidth, fidelity and (only at layers 0-2) local input response; lower layers win on
generality and "works with any app unmodified". The two browser engines only expose clean cut points at 0, 6 and 7
without a fork.

---

## 2. Findings per approach

### 2.1 Wayland protocol forwarding: waypipe

How it works. Waypipe proxies a Wayland connection: one instance beside the app (server), one beside the compositor
(client), joined by a socket, usually ssh (`waypipe ssh user@host app` runs both ends) [S: man page]. Protocol
messages pass as-is; buffers are replicated. For shared-memory buffers it keeps a private copy of each buffer and sends
"a series of runs of changed data, prefixed by the range in the buffer", merging gaps smaller than 256 bytes, driven
by Wayland damage; work is split into ~256 KB chunks across threads [S: GSoC blog]. Compression is `none` / `lz4`
(default) / `zstd=N`; LZ4/Zstd ratios run "from 30x for some text and whitespace heavy images, to only 1.5x for mildly
noisy image data" [S: GSoC blog]. `--threads` defaults to half the hardware threads [S: man page]. `waypipe bench`
estimates which compression gives the lowest latency for a given bandwidth [S: man page].

DMA-BUF (what GPU-accelerated Firefox/Chromium hand to the compositor). Since 0.10 (the Rust rewrite) waypipe imports
and copies DMA-BUFs through Vulkan instead of libgbm, for "better performance, explicit synchronization support and
more efficient RGB to YCbCr conversion"; modifiers need not be replicated exactly [S: Rust rewrite notes]. Each side
needs a Vulkan device; `--no-gpu` blocks `linux-dmabuf`/`wl_drm` so the app falls back to shm [S: man page].

Video mode. `--video h264|vp9|av1[,hw|sw][,bpf=B]` encodes specific DMA-BUF formats lossily ("Opaque, 10-bit, and
multiplanar formats, among others, are not supported") [S: man page]. Caveat from the README: each buffer gets its own
video stream, so a video-encoded window can flicker as the app cycles buffers [S: search summary of the README].
Historic numbers (2019, C version): SuperTuxKart 1024x768 lossless ~130 MB/s at ~40 fps; with hardware video ~80 fps
at ~4 MB/s [S: GSoC blog]. Games lose "a factor of 2 or more" FPS from the frame-callback round trip [S: GSoC blog].

Field reports. Firefox over 2.5 GbE: "Scrolling is responsive and video playback is silky-smooth", GTK4 demo ~75 fps
[S: LinuxLinks]. Vivaldi over GbE on KDE Wayland: "nearly no latency when typing", faster start than Xpra (no numbers)
[S: TauCeti]. Over Wi-Fi the only report is the author's 2019 note that weston-terminal "lags quite horribly"; his
Wi-Fi did ~1 MB/s [S: GSoC blog]. **No Wi-Fi numbers exist for current waypipe; that is the first measurement (§4).**

Judgement.
- Latency: the app runs remotely, so every input is a full round trip (event → app → commit → diff → wire → apply).
  Same structure as PowStream, minus the encoder for static content. [E] keystroke→photon ≈ Wi-Fi RTT (2-10) + app
  frame (~8-16) + diff+lz4 of the damaged region (≤1-2 for a text line) + apply/compose (~4-8) ≈ 15-35 ms.
- Bandwidth: tiny for typing and cursor blinks (damage-sized diffs); large for scrolling. A full 1080p BGRx frame is
  8.3 MB [E: 1920x1080x4]; a text-heavy scroll with lz4 at ~5-10x is ~1-2 MB/frame = 60-120 MB/s at 60 fps, beyond
  the Open's realistic Wi-Fi goodput. So browsers need `--video` (or damage-limited scrolling) for scroll/video,
  lossless for the rest. This switch is per buffer format, not per content type: an open question (§7).
- Fidelity: lossless text when not in video mode; real Wayland popups, menus, clipboard, cursor, resize, IME and
  fractional scale cross as protocol, so the phone's KWin and the web-windows layer treat the window exactly like a
  local Linux window. This is the large advantage over PowStream for "regular windows".
- Packet loss/Wi-Fi: rides on ssh/TCP, so a loss stalls the stream (head-of-line blocking) rather than dropping a
  frame; no FEC, no IDR recovery logic. A retransmit at Wi-Fi p99 is a visible hitch [E].
- ARM↔x86: yes, the protocol is ISA-neutral; Arch Linux ARM and Arch x86 package it [K]. Both ends must run the same
  major version (0.10 is incompatible with earlier) [S: SUSE changelog summary].
- Effort: low for a prototype (packages + one ssh command), medium for integration (launch from the drawer, auth via
  PowAuth/deviced instead of ssh keys, reconnection, which 0.10 removed [S: SUSE changelog summary]).

### 2.2 Xpra

Per-window ("rootless") forwarding of X11 apps; picks an encoding per window from window characteristics, network
and CPU: WebP/PNG/JPEG for UI, h264/hevc/av1 (x264, NVENC) for animated regions, a `scroll` pseudo-encoding that sends
motion vectors for scrolls [S: Encodings.md]. A third-party Android client decodes each window with its own MediaCodec
in low-latency async mode [S: xpra-client PR #3]. Recent work tunes the encoder motion search right after scroll input
[S: issue #5118]. It is X11 (Firefox/Chromium run fine under X11/Xwayland) and pixel-based, so per window it sits
between waypipe and PowStream. Valuable as **a reference for the encoder policy** (lossless for UI, video for motion,
scroll as motion vectors) that a waypipe- or PowStream-based path should copy; adopting Xpra itself means a second
window system (X11 rootless) next to KWin's Wayland, which REMOTE-WINDOWS.md already avoids.

### 2.3 Browser compositor remoting

**Chromium.** Renderer → `cc` → CompositorFrame (metadata + ordered render passes of quads referencing resources such
as GPU textures) → viz [S: how_cc_works]. Below that, OOP raster: paint ops "that survive culling are serialized to
the GPU side via a ring-buffer"; images, paths, text blobs go through an LRU resource cache; fonts via `SkStrikeServer`
[S: graphics-dev thread; paint_op_buffer_serializer.cc]. Transport is the GPU command buffer over shared memory
(`RasterCHROMIUM`) [S: Castanets #18]; OOP-R has been the default for over a year as of Jan 2022 [S: search summary].

Blimp (2015-2017) was Chromium-to-Chromium remoting: the engine ran with `--use-remote-compositing`, serialized
compositor state (layer tree + display lists) to protobufs and sent it over TCP/SSL (port 25467) to an Android client
that rasterized and composited [S: blimp/docs/running.md; Menlo; WebARonARCore d7178e4]. All `//blimp` code was
deleted on 2017-01-18 (codereview 2626423004), after its build infra was removed [S: codereview]. **No public
statement of why it was stopped was found** (searched chromium-dev/crbug summaries). What can be read from the record:
it needed `--android-fonts-path` and `--disable-remote-fonts` (fonts had to match on both ends), a token, and a
same-version client [S: running.md]; and the remote-compositing path was a second implementation of the
cc main↔impl channel that the code removal had to unwind from `content/` [S: d7178e4]. A maintenance burden with a
version-locked pair is the plausible reason, but it is an inference.

Samsung Castanets (Chromium 76 fork) splits differently: the browser process with the GPU stays on the display
device, renderer processes run on "in-home edge devices", Android renderers need root [S: Castanets README]. Its
attempt to carry OOP raster over the network stalled on the shared-memory dependency of the GPU channel and paint-op
serialization, and incomplete tiles on M63; deferred, issue closed 2019 [S: Castanets #18]. Menlo Security ships the
same compositor-mirroring idea commercially for browser isolation (layer tree + display lists → a rebuilt DOM in an
unmodified client browser), claiming vector-crisp output at any resolution and viewport-first bandwidth priority, with
no published numbers vs pixels [S: Menlo].

Mighty (cloud-streamed Chrome, pixels) shut down in Nov 2022: "Much of the web is bound by single core performance of
JS ... We could improve things by 2x but not 5-10x"; users churned over "networking stutters" and hover/scroll delay
[S: Liliputing/HN/Chase Lambda retrospective]. Lesson for us: offloading a browser buys little compute because the
client CPU is already good, and costs input latency on every hover and scroll.

**Firefox.** Content processes build the Gecko display list, convert it into a self-contained WebRender display list
blob and send it over IPC to the GPU process, which deserializes it into a Scene [S: RenderingOverview]. Serialization
moved from bincode to a bespoke `peek-poke` format (2019) and the buffer is sent as a `ByteBuf`, not through IPDL
[S: gfx newsletter #47, bug 1406507]. Content WebRender cannot draw natively becomes "blob images": recorded Moz2D
commands rasterized on CPU worker threads during scene building on the WebRender side [S: blob.md summary, newsletter
#32]; native-theme widgets must still paint in the content process (`MustPaintOnContentSide`) [S: bug 1377595].
Because a GPU-process crash is survived by "resend the display list" [S: WebRender newsletter #10], the content
process already treats the DL as a replayable artefact.

Could the content process run on `.58` while the phone's GPU process renders? Architecturally this is the cleanest
cut of any browser (one serialized blob per transaction, fonts/images as resource updates). In practice: the
parent/GPU/content IPC is IPDL over shared memory with synchronous messages (input, APZ hit testing, clipboard) that
would each pay a Wi-Fi RTT; it needs a forked Firefox at the same version on both ends; and nobody has done it. Effort
is "maintain a browser fork". APZ (async pan/zoom, compositor-side scrolling) would make scrolling local on the phone,
which is the one thing pixels and waypipe can never do.

Judgement: the best possible fidelity/bandwidth/scroll-latency trade, and a dead end for us at our size: two
browser forks to maintain, no prior system survived (Blimp deleted, Castanets stalled at Chromium 76), and
§2.5 shows the payoff the owner wants is reachable more cheaply.

### 2.4 Toolkit-level remoting

- **GTK4 Broadway**: render nodes become DOM elements with CSS, diffed frame to frame; unchanged subtrees are reused,
  text and icons go as images [S: alexl blog]. Officially "written as an experiment and is not the most actively
  developed backend" [S: GTK4 docs summary]; GTK 4.20 shares icon nodes in a way that asserts in `gtk4-broadwayd`
  [S: phosh-toolkit PR #57]. Browser-only target (HTML5 + WebSocket), single toolkit.
- **Qt WebGL QPA**: streamed OpenGL calls into a browser canvas; Qt 5.10 preview, released 5.12, one connection at a
  time; not released for Qt 6 (only a community port attempt in 2022) [S: Qt blog 5.12, qt-project list, forum].
  Qt's VNC QPA is pixels. Qt Quick scene-graph serialization has no shipped remoting backend [K]. Qt RemoteObjects
  syncs QObject properties/signals, so it is an app-architecture tool (write the app as model + UI), not a window
  transport [K].
- **KDE**: KRdp and the screencast portal are pixel paths; nothing above pixels [K].

Judgement: none applies to Firefox/Chromium (they draw their own content), and for Qt/GTK apps waypipe already
forwards them unmodified with better fidelity. Toolkit remoting is only worth it for **PowOS's own apps**, and there
the right tool is state sync (§2.5), not toolkit streaming.

### 2.5 State hand-off: run the browser natively on each device

Firefox and Chromium already run as arm64 builds in the phone's Arch Linux ARM userland and appear as native windows
there (WEB_WINDOWS.md). So the owner's idea ("sync the application state ... render natively") is directly achievable
for browsers at layer 0, and is exactly what the browsers' own sync systems do:

- what moves: open tabs + URLs, per-tab history, scroll position, form data (session store), cookies/logins (sync or
  a shared password store), extensions/settings (sync).
- input latency: **zero network** on the critical path; scrolling, hover, typing, video are all local at the phone's
  120 Hz. Bandwidth after the hand-off: none for the UI; the page loads from the web/LAN as normal.
- ARM↔x86: no issue (data, not code).
- loses: live JS heap state (an unsaved draft in a web app that does not persist, a WebRTC call, a running
  download), and anything only the server can reach (localhost services on `.58`).

The Mighty post-mortem (§2.3) is the evidence for the trade: the phone's own CPU runs the web nearly as well as a
server, and remoting costs latency on every interaction.

### 2.6 Remote GPU API (layer 4), for apps

Venus serializes Vulkan into a ring shared with the host and needs host-visible blob memory (`hostmem`, `blob=true`)
[S: Mesa Venus docs, QEMU docs]; gfxstream does the same through its ASG ring and lists "one computer to another via
network sockets" as a use [S: gfxstream README]. A Venus-over-TCP experiment measured each synchronous Vulkan call at
≥3 blocking round trips, `vulkaninfo` runtime scaling linearly with added RTT (20/40/80 ms → 20.8/40.8/81.2 s,
~1,000 sequential round trips), and has not drawn a `vkcube` frame; the author's scope: work that "submits a lot and
waits rarely" [S: gpu-over-ip-research]. Juice (commercial GPU-over-IP) users report 5-20 ms on a LAN for graphical
apps (anecdote) [S: HN 41206401]. For a browser this is the wrong direction (it would put the GPU remote and keep the
CPU local; we want the opposite).

---

## 3. Ranked table: ordinary windows (Firefox/Chromium first, then Qt/GTK)

Input = added network latency on the interactive path; Wi-Fi RTT assumed 2-10 ms.

| # | approach | layer | input → photon | bandwidth | fidelity | Wi-Fi loss | ARM↔x86 | effort | verdict |
|---|---|---|---|---|---|---|---|---|---|
| 1 | **Native browser + state hand-off** | 0 | local, 0 network [E] | ~0 after hand-off (KB of session) | native, 120 Hz | n/a | yes (data) | low-medium | **browsers: do this** |
| 2 | **waypipe → phone KWin** (lossless, `--video` for motion) | 6 | RTT + app frame + diff ≈ 15-35 ms [E] | KB/s idle, 60-120 MB/s lossless scroll [E], ~4 MB/s video [S, 2019 game] | lossless text, real popups/IME/clipboard/resize | TCP: stalls on loss | yes | low (proto), medium (integrate) | **generic windows: prototype** |
| 3 | PowStream per-window video (REMOTE-WINDOWS phase 2) | 7 | 20-30 ms p50 + 5-12 input [E, REMOTE-WINDOWS §3] | CBR, a few-tens Mb/s [E] | lossy text, no native popups | FEC, latest-wins | yes | already planned | games + fallback |
| 4 | Xpra per window | 6/7 | like 3 [E] | adaptive | lossless UI, video motion, scroll vectors [S] | TCP/QUIC [K] | yes | medium (X11 side-system) | reference for encoder policy |
| 5 | Browser compositor remoting (Blimp / WebRender DL) | 2 | **local scroll**, RTT for JS-driven changes | lowest (vector, cached glyphs/images) [S Menlo, no numbers] | vector, any DPI | needs reliable ordered | yes | browser fork, both ends, per version | dead end for us (Blimp deleted 2017, Castanets stalled) |
| 6 | Chromium OOP-R paint ops over network | 3 | RTT per raster | medium-high (ops + images) | exact Skia | reliable only | yes | fork; shared-memory design [S Castanets] | dead end |
| 7 | GTK4 Broadway / Qt WebGL QPA | 5 | RTT | low-medium | text as images (GTK) | WebSocket | yes | low, but GTK-only/Qt5-only | not for browsers; unmaintained |
| 8 | GPU API remoting (Venus/gfxstream/Juice) | 4 | ≥3 RTT per sync call [S] | high (buffers, textures) | exact | reliable only | yes | high | wrong direction for windows |
| 9 | DSM / far memory / Popcorn / syscall forwarding (§5) | below app | µs-scale assumptions × 1000 | — | — | — | partly | research | dead ends at Wi-Fi RTT |

---

## 4. Recommended path for Firefox/Chromium on the OnePlus

Two tracks, because they answer different needs: **hand-off** for browsers (the window should simply be native), and
**waypipe** for "any regular window on the server" (Dolphin, Kate, a Qt tool, a browser whose live state must stay
on the server).

### Phase 1a: browser hand-off ("continue on phone")

- [ ] Source side (`.58` / any PowOS desktop): read the focused browser window's session. Chromium: the DevTools
  protocol on a local-only `--remote-debugging-port` lists tabs and URLs, `Runtime.evaluate` gives scroll offsets
  [K]; Firefox: the session store (`sessionstore-backups/recovery.jsonlz4`) or WebDriver BiDi [K]. Expose it via the
  device's `powos-deviced` action (device-ecosystem D6) as `browser_session`.
- [ ] Phone: open the same tabs in the phone's native Firefox/Chromium window, restore scroll; logins come from the
  browser's own sync account (no new secret store; PowAuth owns device identity only).
- [ ] Drawer/window bar action "Continue on phone" on a remote browser card, and the reverse on the phone.
- Measure: tap → first contentful paint on the phone (p50/p95 over 20 hand-offs of 5 typical sites); what was lost
  (form text, scroll, auth) per site; then the same pages' scroll/typing latency (they are local, so this is the
  phone's own baseline for every other row).
- Success: hand-off ≤ 2 s p50 to usable page; URL + scroll + login kept on ≥ 9/10 sites; interaction latency =
  native.

### Phase 1b: waypipe into the phone's KWin

Measure before integrating. Proposed measurements (nothing installed system-wide; not run for this note):

1. **Encoder/diff cost on `.58`, no phone**, in a pool container (PowStation/docs/COMPUTE.md):
   `PowStation/bin/pow-job <dir> -- 'waypipe --version && waypipe --threads 8 bench'` with `<dir>/Dockerfile` =
   `FROM archlinux:latest` + `RUN pacman -Sy --noconfirm waypipe`. Check `waypipe bench --help` first: the 0.10
   syntax may take the bandwidth as an argument. Gives MB/s per compression mode on text-like vs picture-like frames.
2. **Loopback with a real browser on `.58`**, same container plus `weston` (headless backend) and `firefox`:
   `weston --backend=headless --socket=wl-test & waypipe -s /tmp/wp client & WAYLAND_DISPLAY=... waypipe -s /tmp/wp
   server -- firefox --new-instance https://en.wikipedia.org/wiki/Wayland` - then a scripted scroll; record bytes on
   the socket per second (`waypipe` debug stats or `ss -ti`), with `--video=none` vs `--video=h264,hw` vs `--no-gpu`.
3. **The real path**, in a free window on the Open (a verify-queue job, never touching the user's session):
   `waypipe` as a managed package in the chroot (a registered unit, memory: no unmanaged deps), then from the
   chroot `waypipe --video=h264 ssh user@192.168.50.58 firefox` and the same for `chromium --ozone-platform=wayland`
   and `kate`. Film with the S25 at 240 fps (REMOTE-WINDOWS §3 method): keystroke→photon, scroll smoothness, a
   menu open, a resize; log Wi-Fi RSSI and retransmits.

Success criteria against PowStream's budget:

| metric | PowStream phase 1 | waypipe must reach |
|---|---|---|
| keystroke/tap → photon p50 | ~25-42 ms (20-30 + 5-12) [E] | **≤ 30 ms p50, ≤ 60 ms p95** |
| idle/typing bandwidth | CBR stream | ≤ 1 MB/s |
| scroll on a text page | 60 fps lossy | ≥ 60 fps with p95 frame gap ≤ 33 ms, at ≤ 30 MB/s |
| text fidelity | lossy | pixel-exact when static |
| popups, menus, IME, clipboard, resize | phase 3+ (P5-P7) | work on first run (protocol-native) |
| 1% Wi-Fi loss (`tc netem` on `.58`) | FEC hides it | no stall > 100 ms |

If waypipe meets the first four and fails the loss row, the fix is the transport (waypipe over QUIC instead of ssh,
or a PowStream-style FEC lane for buffer diffs), not a different layer.

Integration if it passes: a remote app = a Linux window on the phone's KWin, so the web-windows code needs no new
source kind; the drawer's "Desk" group (REMOTE-WINDOWS §2) launches through `waypipe` instead of PowStream for
non-game apps; auth through the deviced ticket instead of ssh keys.

---

## 5. Execution splitting: memory sharing, instruction rerouting, blocking

The question: can part of a running program execute on the server and part on the phone (shared memory, migrated
threads, rerouted calls)? The deciding number is the cost of one remote round trip versus how often the program
needs one.

| idea | needs (per remote access) | ever over wireless? | Firefox/Chromium | games | verdict at 2-10 ms RTT |
|---|---|---|---|---|---|
| Classic DSM / far memory (Infiniswap, Fastswap, AIFM, LegoOS) | Fastswap remote page < 5 µs; Infiniswap up to 40 µs, ~25 µs fault path [S: far-memory survey/lightswap]; LegoOS assumes RDMA/InfiniBand RPC, busy polling [S: LegoOS]; disaggregation needs single-digit-µs networks [K, Gao OSDI'16 — exact figures not re-read] | no | every page fault +2-10 ms → unusable | unusable | **dead end** (~1,000x too slow) |
| CXL memory pooling | rack-scale PCIe-class link, sub-µs [K, Pond] | impossible over radio | — | — | **dead end** |
| Heterogeneous-ISA thread migration (Popcorn Linux) | migration 1.2 ms x86→ARM, inverse 8.7 ms; DSM page fault 80-141 µs; ARM stack rewrite several ms; measured over PCIe point-to-point [S: MARS'16, ASPLOS'17] | no | JIT + multiprocess + GPU: out of scope of the compiler [E] | no | **dead end** as continuous split |
| H-Container (cross-ISA container C/R, HetCRIU) | 10-100 ms per migration, no steady-state overhead [S] | edge servers, wired | one-shot "move the app" only; needs IR-lifted binaries [S]; browsers' JIT not covered [E] | no | research curiosity; hand-off (§2.5) does the same job for browsers with data |
| Mobile code offload (MAUI, CloneCloud, COMET) | method/thread granularity; COMET adds field-level DSM on the Dalvik VM [S: COMET summary]; CloneCloud moves stack + reachable heap [S] | **yes, Wi-Fi and 3G** (their premise) [S] | only for coarse compute (an image filter, an ML call), not the per-frame path | no (frame-coupled) | works only where compute per call ≫ RTT; speedup figures not verified (COMET PDF unreachable) |
| WebAssembly migration | Nomad: cross-platform live migration < 2 ms fixed delay, < 5% overhead (interpreter) [S]; Wanco: cross-ISA C/R of AOT-compiled wasm via OSR [S] | edge/femtocloud | browsers are not wasm programs | no | **the one live-migration route that crosses ARM↔x86 cleanly**, for PowOS's own apps if written as wasm components (§7) |
| Syscall / API interception (LD_PRELOAD, seccomp user notification, eBPF) | seccomp-unotify blocks the task and wakes a supervisor per call (Linux ≥ 5.0) [S: man page]; filter overhead up to 2.6 ms in one benchmark [S: USENIX Sec'22] - before any network | not as a remoting system | per-frame calls die; whole-file or whole-request calls fine | no | useful only for coarse calls (open a big file on the NAS, one inference call) |
| Remote GPU/compute API (rCUDA, Juice) | near-local only on InfiniBand; "noticeably increases execution time" on 1 GbE [S: rCUDA papers]; Juice 5-20 ms on a LAN (anecdote) [S] | no | no | see §6 | batch compute only |

Plain reading: everything that shares memory or routes fine-grained calls assumes microsecond networks; Wi-Fi to the
phone is milliseconds with a tail, three orders of magnitude off. These are **dead ends for windows and games**. What
survives is coarse: move the whole program's *state* once (hand-off, wasm migration) or send *whole requests*
(an inference, a transcode, a build) to the server, which PowOS already does with Nomad/pow-job.

---

## 6. "Halfway native" games: what it can realistically mean

| idea | what runs where | numbers | fit for us |
|---|---|---|---|
| **A. Native client of the game's own client/server split** | the game's dedicated/integrated server on `.58`, the game's ARM client on the phone | game-specific; latency = the game's own netcode (designed for 50+ ms internet) [K] | **the real "halfway native"**, today, for games that have it: Minecraft Java (the JVM runs on arm64; launchers exist for Android [K]), Luanti, any game with a Linux ARM client. Server does world simulation, phone renders natively at 120 Hz. Zero new tech; a drawer entry that starts the server on Desk and the client on the phone. |
| **B. Client-side reprojection (ATW) over PowStream** | everything on the server; the phone warps the last frame with the newest camera pose | PowStream's `feat/atw-mesh-warp` (REMOTE-WINDOWS §1) | the generic "feels native" lever for any game: camera motion at local latency, game reaction at stream latency. Needs depth + pose from the source (a Vulkan layer, SPEC-window-stream). Already in development for Minecraft. |
| C. Collaborative rendering (Kahawai) | both render the same deterministic game; server sends the delta to high detail, or the missing frames | same quality at "as little as one-sixth of the bandwidth" of a thin client, 50-person study, idTech 4 [S: MSR abstract]; best on a LAN [S: phys.org] | needs a deterministic engine running on both ends: per-game engine work, ARM build of the game. Not for Steam/Proton titles. |
| D. Speculation (Outatime) | server renders likely futures; client picks by actual input; rollback | masks up to 120 ms (MobiSys'15; 250 ms in the 2014 TR) [S]; 1.51-4.54x the bandwidth of standard cloud gaming [S: AppStreamer citing it] | engine integration again; our LAN latency (≤ 30 ms) is already under its range, so the bandwidth cost buys little. |
| E. GPU API remoting (phone GPU draws the PC game) | game + DXVK on `.58`, Vulkan commands to Adreno | ≥ 3 RTT per synchronous call; no frame drawn yet over TCP [S: gpu-over-ip-research]; Venus requires coherent host-mapped memory [S: Mesa/QEMU docs], i.e. DSM of GPU buffers over Wi-Fi | **dead end**: per-frame dynamic buffers, sync points, and the Adreno 740 cannot render what the RTX card renders anyway. |
| F. Asset caching / dedup for E | content-addressed texture/mesh cache on the phone | cuts load-time traffic only [E] | only matters if E were viable; it is not. |

So "halfway native" for games means **A** where the game has a client/server split, and **B** (ATW, already in
flight) for everything else. C and D are per-engine research; E is a dead end.

---

## 7. Open questions

1. Current waypipe (0.10.x) on Wi-Fi: bytes/s and keystroke→photon for Firefox/Chromium with lossless vs `--video`
   (§4 measurements 1-3). Nothing published.
2. Can waypipe pick lossless vs video per *content* (static text vs scroll/video) instead of per buffer format? If
   not, is a damage-size threshold patch small?
3. Does the phone's KWin (anland) accept waypipe's DMA-BUFs from Turnip/Vulkan on Adreno, or must the phone side use
   shm? Effect on the 120 Hz path through `native_consumer.c`?
4. Waypipe over ssh/TCP under Wi-Fi loss: how bad is head-of-line blocking at p99? Would a QUIC transport (reusing
   PowStream's B0/wtransport) be accepted upstream or need a fork?
5. Hand-off: which session fields survive for the owner's top sites (logins via Firefox Sync vs Chromium sync; a
   self-hosted sync server is a new service and needs a yes)?
6. Is there a single browser the owner uses on all devices? Hand-off is simplest when it is the same browser.
7. Why was Blimp really stopped? No primary statement found; a chromium-dev archive search (Dec 2016 - Jan 2017)
   could settle it. Does not change the verdict.
8. Firefox content-process-on-server: are there sync IPC messages on the per-frame path (APZ hit testing, input)
   that make it impossible even in principle at 2-10 ms RTT? A Firefox engineer's view would settle it cheaply.
9. Games A: which titles in the owner's library have an ARM-capable client and a separable server, beyond Minecraft?
10. PowOS's own apps: should new apps be written as state + UI (Qt RemoteObjects-style or wasm components) so they can
    migrate across ARM/x86 like the owner's original idea? A design decision for the manager, not a measurement.

---

## Sources

All rows are in `docs/research/REFERENCES.md` (2026-11-23). Read for this note: waypipe man page (mankier), M.
Stoeckl's GSoC 2019 blog and Rust-rewrite notes, waypipe search summaries (SUSE changelog, README), LinuxLinks and
TauCeti waypipe reviews; Xpra Encodings.md, issue #5118, xpra-client PR #3; Chromium how_cc_works.md,
graphics-dev "Thoughts on OOP raster model", paint_op_buffer_serializer.cc (search summary), Blimp running.md,
codereview 2626423004, WebARonARCore d7178e4, Menlo Smart DOM; Samsung Castanets README and issue #18; Mighty
(Liliputing, Chase Lambda retrospective, HN); Firefox RenderingOverview, gfx newsletters #10/#32/#47, bugs 1406507,
1377595, 1550640, blob.md (search summary); GTK4 Broadway (alexl blog, docs, phosh-toolkit PR #57); Qt WebGL (Qt blog,
qt-project list, forum); Mesa Venus docs, QEMU virtio-gpu, gfxstream README, gpu-over-ip-research; Juice (HN);
Kahawai (MSR page, phys.org); Outatime (search summaries of MobiSys'15 and the 2014 TR; AppStreamer); Popcorn
(MARS'16, ASPLOS'17 summaries); H-Container (VEE'20/TOCS summaries); COMET, CloneCloud, MAUI (search summaries; the
COMET PDF was unreachable); Fastswap/Infiniswap/AIFM (search summaries); LegoOS; Nomad and Wanco wasm migration;
seccomp_unotify(2), USENIX Security '22 (Schrammel et al.); rCUDA papers (ANL). PDFs that could not be text-extracted
here (Kahawai, Outatime full text) are cited only through their abstracts/summaries.
