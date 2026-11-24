# Native window remoting: showing remote windows above pixels

Status: **research, 2026-11-23; measured on `.58` the same day (§8).** Companion to `docs/REMOTE-WINDOWS.md` (PowStream pixel streaming into
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
| 2 | **waypipe → phone KWin** (lossless, `--video` for motion) | 6 | measured §8: +2 ms per ms of one-way delay; Kate 9-20 ms, Firefox 14-25 ms p50 at 3-8 ms each way [M] | KB/s idle, 60-120 MB/s lossless scroll [E], ~4 MB/s video [S, 2019 game] | lossless text, real popups/IME/clipboard/resize | TCP: stalls on loss | yes | low (proto), medium (integrate) | **generic windows: prototype** |
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
   (§4 measurements 1-3). Nothing published. **Measured 2026-11-23 on emulated Wi-Fi (§8.2)**; the real phone run is
   §8.6.
2. Can waypipe pick lossless vs video per *content* (static text vs scroll/video) instead of per buffer format? If
   not, is a damage-size threshold patch small? **§8.2: no, it is per format, and stock 0.11.3 refuses Firefox's
   ARGB8888 entirely (4-line patch fixes that); static text then stays lossy, so a lossless refresh after motion is
   the next patch.**
3. Does the phone's KWin (anland) accept waypipe's DMA-BUFs from Turnip/Vulkan on Adreno, or must the phone side use
   shm? Effect on the 120 Hz path through `native_consumer.c`?
4. Waypipe over ssh/TCP under Wi-Fi loss: how bad is head-of-line blocking at p99? **§8.2: 1% loss gave 236-267 ms
   stalls (Firefox up to 6-8 per 35 s run).** Would a QUIC transport (reusing
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

## 8. Measurements (2026-11-23)

The owner, 11-23: "ok lets run a test for the most promising methods". Three experiments, fresh runs only; every number
below is `[M]`. Scripts: `tools/research/remoting/` (one command each: `run-waypipe.sh`, `run-dirty.sh`,
`run-criu.sh`, `run-fidelity.sh`; `report.py` prints these tables from `results/*.jsonl`; `cleanup.sh` removes the
containers and images). No phone was used.

### 8.1 Environment

- `.58` (Ryzen 9 9950X3D2, Bazzite 44, kernel 7.2.9), rootless podman 5.8.9 over the `pow58` Docker context, Compose
  project `rmm`, `cgroup_parent: nomad.slice` (the 24-thread job cap). comp = 4 cpus, app = 6, criu-a/b = 2 each.
  The other tenants of .58 kept running (load average 5-10 during the runs).
- One Arch Linux image for every container: sway 1.12 / wlroots 0.20.2 (headless backend, GLES2 on the Radeon 610M
  iGPU render node, one 1920x1080 output at 120 Hz, key repeat 60/s), waypipe 0.11.3, Firefox 160.0.1,
  Kate/Dolphin 26.08.3 (Qt 6.12), Mesa 26.3.1 (RADV with Vulkan video encode/decode H.264), libwayland 1.26, CRIU 4.3.1.
- comp = the "phone": headless sway + `waypipe client` behind `socat TCP-LISTEN` (TCP_NODELAY). app = `waypipe server`
  + the app, reaching comp over the containers' bridge (TCP, the same transport `waypipe ssh` uses, minus ssh crypto).
- Phone Wi-Fi emulation: `tc netem` on **both** containers' eth0 egress, so the delay applies once per direction
  (RTT ≈ 2 × delay): `delay 3ms 2ms` and `delay 8ms 4ms` (uniform jitter), each with `loss 0%` and `loss 1%`, all with
  `rate 400mbit` (~50 MB/s, a realistic Open goodput; with a rate set netem keeps packets in order). "wired" = no qdisc.
- Pages and inputs: Firefox on a local copy of Wikipedia's "Linux" article (styles/images still from Wikipedia, a
  sticky textarea on top, Wikipedia's pulsating onboarding dot hidden). Kate on a 2.7k-line Python file (argparse.py,
  syntax highlighting on). Dolphin on a 3,901-icon folder. Input through `wtype` (sway's virtual keyboard).
- Phases per run: idle 10 s; typing 60 letters 150-300 ms apart; scroll 10 s (Firefox: JS scroll 12 px/frame, the
  page's own rendering load; Kate/Dolphin: Down held, 60 repeats/s).
- Latency = sway sends `wl_keyboard.key` (pressed) → the first `wl_surface.commit` carrying damage from the app's
  connection, both from sway's `WAYLAND_DEBUG=server` log (libwayland's µs timestamps). That is input→frame-arrives at
  the compositor; the compositor's own repaint (≤ 1 output frame, 8.3 ms here) and the panel are not included, nor is
  the phone's input leg to the compositor. fps = damaged commits/s on the busiest surface; a stall = a frame gap or a
  key→frame time > 100 ms. Bytes = `tcp_info` bytes_acked/bytes_received of the waypipe TCP connection, 100 ms samples.
- Modes: `local` = the app straight on sway (the app's own baseline); `shm` = `waypipe --no-gpu`; `gpu` = waypipe
  default (DMA-BUF via Vulkan, lossless LZ4 diffs); `video-stock` = `waypipe --video=h264`; `video` = the same release
  built with a 4-line patch (`tools/research/remoting/waypipe-argb-video.patch`) that lets ARGB8888/ABGR8888 buffers
  use video. H.264 encode/decode ran on the iGPU (waypipe reported hwenc/hwdec available; 0.11 has no switch for sw).

### 8.2 Experiment 1: waypipe

| app | mode | net (each way) | key→commit p50 / p95 / max ms | idle KB/s | typing KB/s | scroll fps | gap p95 / max ms | scroll MB/s avg / peak 1 s | stalls >100 ms (local) | retrans | bar |
|---|---|---|---|---|---|---|---|---|---|---|---|
| firefox | local | wired (none) | 3.7 / 4.4 / 4.8 | - | - | 122.7 | 8.2 / 139.6 | - | 1 (1) | - | - |
| firefox | shm | wired (none) | 2.3 / 3.8 / 4.1 | 0.0 | 7.2 | 123.0 | 8.4 / 140.6 | 52.63 / 63.05 | 1 (1) | 0 | FAIL: scroll |
| firefox | shm | 3±2 ms | 9.1 / 11.1 / 12.8 | 0.0 | 6.7 | 93.1 | 16.3 / 146.5 | 40.32 / 48.40 | 1 (1) | 0 | FAIL: scroll |
| firefox | shm | 3±2 ms 1% loss | 9.8 / 20.3 / 27.4 | 0.0 | 6.3 | 78.3 | 23.7 / 254.8 | 34.35 / 45.41 | 3 (1) | 203 | FAIL: scroll,stalls |
| firefox | shm | 8±4 ms | 21.9 / 30.0 / 40.6 | 0.0 | 6.8 | 50.2 | 25.8 / 135.9 | 22.87 / 28.61 | 1 (1) | 0 | FAIL: scroll |
| firefox | shm | 8±4 ms 1% loss | 23.4 / 57.6 / 58.3 | 0.0 | 6.2 | 48.0 | 33.6 / 131.8 | 21.74 / 27.67 | 1 (1) | 53 | FAIL: scroll |
| firefox | gpu | wired (none) | 6.4 / 8.2 / 8.7 | 0.0 | 7.8 | 123.2 | 8.3 / 143.4 | 51.54 / 61.80 | 1 (1) | 0 | FAIL: scroll |
| firefox | gpu | 3±2 ms | 13.9 / 17.4 / 18.4 | 0.0 | 7.6 | 53.2 | 21.6 / 140.6 | 24.50 / 27.76 | 1 (1) | 0 | FAIL: scroll |
| firefox | gpu | 3±2 ms 1% loss | 11.1 / 22.3 / 45.7 | 0.0 | 6.2 | 75.4 | 25.9 / 384.5 | 32.48 / 40.59 | 1 (1) | 351 | FAIL: scroll |
| firefox | gpu | 8±4 ms | 25.4 / 36.6 / 39.1 | 0.0 | 7.4 | 32.2 | 34.8 / 107.6 | 14.72 / 17.80 | 1 (1) | 0 | FAIL: scroll |
| firefox | gpu | 8±4 ms 1% loss | 29.1 / 64.2 / 106.1 | 0.0 | 7.1 | 27.9 | 48.6 / 267.4 | 12.28 / 16.66 | 6 (1) | 82 | FAIL: latency,scroll,stalls |
| firefox | video-stock | wired (none) | 5.4 / 8.0 / 8.4 | 0.0 | 7.8 | 122.9 | 8.5 / 142.7 | 51.38 / 61.54 | 1 (1) | 0 | FAIL: scroll |
| firefox | video-stock | 3±2 ms | 12.3 / 14.9 / 15.3 | 0.0 | 7.6 | 54.6 | 21.2 / 138.0 | 24.98 / 28.35 | 1 (1) | 0 | FAIL: scroll |
| firefox | video-stock | 3±2 ms 1% loss | 12.5 / 22.1 / 28.4 | 0.0 | 7.7 | 43.4 | 27.6 / 250.5 | 19.22 / 25.86 | 7 (1) | 203 | FAIL: scroll,stalls |
| firefox | video-stock | 8±4 ms | 26.6 / 39.1 / 58.1 | 0.0 | 7.4 | 31.6 | 34.9 / 101.9 | 14.43 / 17.44 | 1 (1) | 0 | FAIL: scroll |
| firefox | video-stock | 8±4 ms 1% loss | 29.3 / 70.8 / 147.9 | 0.0 | 7.4 | 26.2 | 52.0 / 285.0 | 11.49 / 15.95 | 6 (1) | 84 | FAIL: latency,scroll,stalls |
| firefox | video | wired (none) | 13.4 / 15.3 / 15.7 | 0.0 | 7.2 | 121.9 | 12.9 / 137.4 | 1.80 / 2.11 | 1 (1) | 0 | PASS |
| firefox | video | 3±2 ms | 20.7 / 27.4 / 32.1 | 0.0 | 7.2 | 70.7 | 16.6 / 119.3 | 1.07 / 1.29 | 1 (1) | 0 | PASS |
| firefox | video | 3±2 ms 1% loss | 18.0 / 25.1 / 33.4 | 0.0 | 6.5 | 64.8 | 16.9 / 232.2 | 0.95 / 1.13 | 5 (1) | 21 | FAIL: stalls |
| firefox | video | 8±4 ms | 29.5 / 45.1 / 56.0 | 0.0 | 6.7 | 40.0 | 29.6 / 108.8 | 0.59 / 0.73 | 1 (1) | 0 | FAIL: scroll |
| firefox | video | 8±4 ms 1% loss | 28.3 / 61.5 / 72.5 | 0.0 | 6.5 | 32.7 | 31.2 / 258.8 | 0.48 / 0.80 | 8 (1) | 14 | FAIL: latency,scroll,stalls |
| kate | local | wired (none) | 1.7 / 2.5 / 2.7 | - | - | 98.0 | 16.7 / 285.2 | - | 2 (2) | - | - |
| kate | shm | wired (none) | 2.6 / 3.5 / 5.2 | 1.0 | 49.8 | 97.3 | 16.8 / 315.7 | 14.04 / 20.23 | 2 (2) | 0 | PASS |
| kate | shm | 3±2 ms | 9.0 / 11.8 / 13.2 | 1.0 | 49.3 | 97.3 | 17.2 / 309.3 | 13.43 / 19.51 | 2 (2) | 0 | PASS |
| kate | shm | 3±2 ms 1% loss | 9.1 / 12.1 / 30.9 | 1.0 | 49.0 | 97.8 | 21.2 / 283.9 | 13.65 / 19.23 | 2 (2) | 195 | PASS |
| kate | shm | 8±4 ms | 20.1 / 24.9 / 25.9 | 1.1 | 70.8 | 97.6 | 17.9 / 286.2 | 13.58 / 19.14 | 2 (2) | 0 | PASS |
| kate | shm | 8±4 ms 1% loss | 20.0 / 25.6 / 236.3 | 1.0 | 49.4 | 94.2 | 21.8 / 283.4 | 12.79 / 19.21 | 4 (2) | 45 | FAIL: stalls |
| kate | gpu | wired (none) | 2.5 / 3.2 / 3.6 | 1.0 | 48.6 | 97.3 | 17.0 / 315.8 | 13.34 / 19.04 | 2 (2) | 0 | PASS |
| kate | gpu | 3±2 ms | 9.0 / 11.9 / 12.5 | 1.0 | 48.8 | 97.3 | 17.3 / 310.5 | 13.44 / 19.45 | 2 (2) | 0 | PASS |
| kate | gpu | 3±2 ms 1% loss | 9.3 / 11.7 / 18.8 | 1.0 | 49.8 | 97.5 | 19.2 / 297.3 | 13.60 / 19.32 | 2 (2) | 82 | PASS |
| kate | gpu | 8±4 ms | 19.6 / 24.7 / 26.7 | 1.0 | 50.0 | 97.5 | 17.5 / 301.7 | 13.54 / 19.18 | 2 (2) | 0 | PASS |
| kate | gpu | 8±4 ms 1% loss | 19.3 / 25.0 / 61.7 | 1.0 | 28.6 | 95.7 | 32.0 / 282.6 | 13.16 / 18.10 | 2 (2) | 117 | PASS |
| dolphin | local | wired (none) | 2.0 / 3.0 / 3.3 | - | - | 68.3 | 14.9 / 315.2 | - | 3 (3) | - | - |
| dolphin | gpu | wired (none) | 2.0 / 3.3 / 3.7 | 0.0 | 821.2 | 70.2 | 14.3 / 285.4 | 25.57 / 62.06 | 3 (3) | 0 | PASS |
| dolphin | gpu | 3±2 ms | 8.7 / 11.6 / 12.2 | 0.0 | 657.6 | 66.5 | 10.2 / 314.6 | 24.44 / 48.61 | 3 (3) | 0 | PASS |
| dolphin | gpu | 3±2 ms 1% loss | 8.4 / 12.1 / 235.8 | 0.0 | 690.8 | 65.3 | 23.2 / 301.6 | 23.84 / 46.43 | 4 (3) | 186 | FAIL: stalls |
| dolphin | gpu | 8±4 ms | 17.6 / 23.3 / 23.8 | 0.0 | 730.2 | 65.0 | 12.0 / 288.7 | 23.60 / 47.60 | 3 (3) | 0 | PASS |
| dolphin | gpu | 8±4 ms 1% loss | 18.2 / 23.4 / 36.8 | 0.0 | 747.9 | 64.0 | 28.7 / 309.3 | 23.16 / 43.64 | 3 (3) | 36 | PASS |

Bar (§4): key→commit ≤ 30 ms p50 / ≤ 60 ms p95; idle and typing ≤ 1 MB/s (both directions); scroll ≥ 60 fps with
p95 gap ≤ 33 ms at ≤ 30 MB/s; at 1% loss no stall > 100 ms beyond the app's own (the "(local)" count: Firefox's own
first-scroll hitch ~140 ms; Kate/Dolphin's ~300 ms gap when the Down repeat starts).

Findings:

1. **Stock `--video` never engages for Firefox.** waypipe 0.11.3 video-encodes only opaque DMA-BUF formats
   (`src/video.rs` `supports_video_format`: XRGB/XBGR8888, 565, 2101010, 16161616); Firefox's toplevel is ARGB8888
   even with `widget.transparent-windows=false`, so `video-stock` rows equal `gpu` (52 MB/s scroll). With the 4-line
   patch, video works and looks right (screenshot checked): scroll 1.8 MB/s instead of 52 MB/s at 122 fps wired, for
   +7 ms key→frame (13.4 vs 6.4 ms p50, the encode/decode). One unpatched observation from the first matrix: one
   `video 3±2 1%` run sent lossless-sized traffic (38 MB/s); its re-run (in the table) used video. Not explained.
   Kate and Dolphin draw into **shm** buffers (Qt raster), and waypipe only video-encodes DMA-BUFs, so video never
   applies to them; they do not need it (≤ 26 MB/s average scroll lossless).
2. **The frame-callback round trip caps fps at phone RTTs.** Even at 1 MB/s (video), Firefox's scroll fell from 122
   fps (wired) to 71 fps at 3±2 ms and 40 fps at 8±4 ms per direction; lossless `gpu` fell to 53/32 fps. waypipe
   forwards `wl_surface.frame` callbacks, so every frame waits a network round trip before the app draws the next one
   (GSoC 2019 saw the same for games). Kate/Dolphin held ~97/65 fps because their scroll frames are cheap to send and
   not callback-paced the same way. This, not bandwidth, is the first thing to fix for browsers: answer frame
   callbacks on the app side (pace locally, waypipe server side) instead of round-tripping them.
3. **Lossless browser scroll exceeds the bandwidth bar.** 52 MB/s average, 62 MB/s peak per second at 122 fps wired
   (`gpu` and `shm` alike); under the 50 MB/s emulated link it self-limits to 15-40 MB/s by dropping to 32-93 fps.
4. **Latency passes for every app without loss, up to 8±4 ms per direction**: Firefox lossless 25.4/36.6 ms (p50/p95),
   video 29.5/45.1 ms (p50 at the bar); Kate 19.6/24.7 ms; Dolphin 17.6/23.3 ms. Each emulated millisecond of one-way
   delay adds ~2 ms (one round trip per key).
5. **1% loss produces stalls > 100 ms (TCP head-of-line blocking), as §2.1 predicted.** Firefox `gpu` 8±4 ms 1%:
   6 stalls (app's own: 1), worst 267 ms frame gap, key p95 64 ms; `video` 8±4 1%: 8 stalls, worst 259 ms; Kate `shm`
   8±4 1%: a 236 ms key; Dolphin 3±2 1%: a 236 ms key. Kate `gpu` at 1% loss stayed clean in this run. The loss row of
   the bar needs a different transport (QUIC/unordered lanes, or FEC), not a different layer.
6. **Idle is free, typing is small.** Firefox idle 0 B/s once the page's one animation (Wikipedia's pulsating dot,
   kept for the first test run) is hidden; with it, a 128x64 px region repainted at 124 fps and cost 44 KB/s
   lossless. Kate idle 1 KB/s (cursor blink). Typing: Firefox ~7 KB/s, Kate ~50 KB/s, Dolphin 0.5-0.8 MB/s (type-ahead
   search redraws the view).
7. **Fidelity** (`run-fidelity.sh`, Firefox after a 10 s scroll and a return to the top, 2 s static, vs the same state
   drawn locally): `gpu` pixel-identical (0 px differ); `shm` ≤ 2 levels off on 69k px (Firefox's software renderer,
   not the transport); `video` 36.5 dB PSNR, 882k px differ, 33.7k px off by > 16 levels: **waypipe's video mode leaves
   the static page lossy** (no lossless refresh after motion stops).

Bar verdicts: **Kate and Dolphin pass** every row except the loss row (one 236 ms key stall in 1 of Kate's 4 and 1
of Dolphin's 2 runs with 1% loss). Firefox
passes only with the ARGB video patch and only at 3±2 ms without loss (fps 71, 1.1 MB/s, 20.7/27.4 ms); at 8±4 ms it
misses the fps bar (40), at 1% loss the stall bar, and its static text stays lossy. Lossless Firefox fails the
scroll-bandwidth row everywhere.

### 8.3 Experiment 2: dirty-memory rate (could a continuous memory mirror work?)

`run-dirty.sh`: each app straight on sway (local), `bin/dirty.py` writes `4` to `/proc/<pid>/clear_refs` for the
whole process tree, waits 100 ms or 1 s, then counts present-and-soft-dirty pages in `/proc/<pid>/pagemap` over all
writable mappings; 10 s per state and interval, the 100 ms pass first. firefox-news = theguardian.com/international
live (idle and scroll only; no text field).

| app | state | 100 ms: mean / p95 / max MB/s | 1 s: mean / p95 / max MB/s | RSS MB | processes |
|---|---|---|---|---|---|
| firefox-wiki | idle | 52.43 / 223.62 / 1425.3 | 0.5 / 3.09 / 3.09 | 1515 | 11 |
| firefox-wiki | typing | 65.58 / 109.86 / 455.32 | 17.55 / 50.38 / 50.38 | 1519 | 11 |
| firefox-wiki | scroll | 66.43 / 130.45 / 160.18 | 12.24 / 28.1 / 28.1 | 1525 | 11 |
| firefox-news | idle | 12.63 / 29.93 / 500.59 | 3.43 / 16.95 / 16.95 | 1561 | 11 |
| firefox-news | scroll | 24.37 / 45.33 / 219.09 | 5.96 / 23.07 / 23.07 | 1547 | 11 |
| kate | idle | 9.51 / 46.11 / 46.24 | 4.7 / 4.73 / 4.73 | 98 | 1 |
| kate | typing | 50.15 / 97.73 / 180.84 | 11.02 / 18.49 / 18.49 | 111 | 1 |
| kate | scroll | 5.32 / 8.99 / 106.27 | 1.81 / 10.79 / 10.79 | 127 | 1 |
| dolphin | idle | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 134 | 1 |
| dolphin | typing | 95.72 / 197.99 / 489.41 | 17.23 / 28.15 / 28.15 | 147 | 1 |
| dolphin | scroll | 3.44 / 2.25 / 149.84 | 1.7 / 15.2 / 15.2 | 147 | 1 |

- At the granularity an interactive mirror needs (100 ms), Firefox dirties **52-66 MB/s on average with p95
  110-224 MB/s and single 100 ms windows of 455 MB/s-1.4 GB/s** (GC, allocation, THP-sized writes); Kate 50 MB/s and
  Dolphin 96 MB/s while typing. Even the 1 s granularity (useless for interaction: a 1 s mirror lag) needs 12-18 MB/s
  for Firefox typing/scroll with 50 MB/s peaks.
- Against ~50-100 MB/s Wi-Fi goodput this is at or over the whole link, before any page-fault round trips, and the
  same interactions cost 1-2 MB/s as waypipe video or 7-50 KB/s as lossless typing. **A continuous memory mirror is
  not viable over phone Wi-Fi**, independent of the ISA problem (§5): numbers confirm the dead-end verdict.
- Caveats: GPU memory (DMA-BUFs/VRAM) is not counted (it would add to the mirror); a THP written once counts 2 MiB;
  clearing soft-dirty write-protects every page, so the app pays one minor fault per first write per interval.

### 8.4 Experiment 3: CRIU pre-copy hand-off (same ISA, container to container)

`run-criu.sh`: vim in a tmux server (a terminal app; Kate is a Wayland client whose compositor connection CRIU cannot
move), a separate process typing ~20 chars/s into it. Pre-copy = 3 × `criu pre-dump --track-mem` 1 s apart, each
image dir streamed (tar over TCP) to criu-b right away, then the final `criu dump` (the app freezes here) streamed the
same way and `criu restore -d` on criu-b. ITER 0 = plain stop-and-copy. vim-big = vim on a 256 MB text file.
Freeze = final dump start → restore done on the destination, end to end (includes the transfer and the receiver's
untar, which is why it exceeds dump + send + restore). Every restore was checked: vim alive on criu-b with the typed
text in the buffer.

| workload | RSS MB | pre-dumps | net (each way) | total ms | freeze ms (dump + send + restore) | bytes moved MB (pre-dumps + final) | restored + typed text kept |
|---|---|---|---|---|---|---|---|
| vim-small | 24 | 0 | wired (none) | 268 | 61 (24 + 17 + 15) | 18.13 (18.13) | yes |
| vim-small | 24 | 3 | wired (none) | 3325 | 39 (17 + 4 + 15) | 23.92 (18.13+1.94+1.93 + 1.91) | yes |
| vim-small | 24 | 0 | 3±2 ms | 1753 | 1548 (22 + 1290 + 17) | 18.13 (18.13) | yes |
| vim-small | 24 | 3 | 3±2 ms | 4760 | 211 (18 + 15 + 17) | 23.93 (18.12+1.94+1.93 + 1.94) | yes |
| vim-small | 24 | 0 | 8±4 ms 1% loss | 986 | 781 (23 + 687 + 17) | 18.13 (18.13) | yes |
| vim-small | 24 | 3 | 8±4 ms 1% loss | 6150 | 453 (17 + 33 + 18) | 23.98 (18.13+1.96+1.93 + 1.96) | yes |
| vim-big | 386 | 0 | wired (none) | 606 | 400 (104 + 169 + 123) | 389.23 (389.23) | yes |
| vim-big | 386 | 3 | wired (none) | 4174 | 189 (46 + 5 + 135) | 397.26 (390.03+2.42+2.40 + 2.41) | yes |
| vim-big | 386 | 0 | 3±2 ms | 8354 | 8149 (105 + 7865 + 127) | 389.23 (389.23) | yes |
| vim-big | 386 | 3 | 3±2 ms | 12712 | 366 (39 + 18 + 136) | 397.37 (390.03+2.47+2.43 + 2.44) | yes |
| vim-big | 386 | 0 | 8±4 ms 1% loss | 12030 | 11825 (117 + 11527 + 131) | 389.23 (389.23) | yes |
| vim-big | 386 | 3 | 8±4 ms 1% loss | 16280 | 519 (39 + 34 + 133) | 397.35 (390.03+2.50+2.41 + 2.41) | yes |

- **Rootless works without new host privileges**, with two conditions: capabilities inside podman's user namespace
  (`SYS_ADMIN SYS_PTRACE CHECKPOINT_RESTORE NET_ADMIN SYS_RESOURCE DAC_READ_SEARCH`, seccomp unconfined, SELinux
  label disabled; all container-level) and CRIU's **`--unprivileged`** mode. Without it, restore fails at
  `SO_SNDBUFFORCE/SO_RCVBUFFORCE` ("Operation not permitted"): those need CAP_NET_ADMIN in the initial user
  namespace, which rootless podman cannot have. `/proc/sys` is read-only in the container (`ns_last_pid`), CRIU used
  clone3 set_tid instead. The destination needs the same files at the same paths (tmux's socket directory had to be
  created) and the same PIDs free.
- Pre-copy cuts the freeze from the full image to the last delta: vim-big 386 MB RSS, 389 MB image → freeze 8.1 s
  (3±2 ms) / 11.8 s (8±4 ms 1%) stop-and-copy vs **366 / 519 ms** with 3 pre-dumps (wired: 400 → 189 ms). The cost
  is ~2 % more bytes (397 vs 389 MB) and a longer total (12.7 / 16.3 s), dominated by the first full copy.
- The emulated link moved the 389 MB first copy at 34-49 MB/s in the tabled runs; an earlier identical 3±2 ms
  stop-and-copy (whose restore failed on a leftover pty from the previous run, since fixed) took 31.5 s (12 MB/s).
  netem's rate cap plus queue drops make bulk TCP throughput vary up to 4x, so treat the multi-second rows as rough.
- Scope: this is server↔server only (`.58` ↔ another x86 box). The phone is arm64 and cannot restore an x86 image;
  hand-off to the phone stays at the state level (§2.5) or wasm (§5).

### 8.5 What changes in the recommendation

- **waypipe for non-browser Linux windows (Kate, Dolphin, Qt/KDE tools) is confirmed as the generic-window track**:
  it meets latency, bandwidth, fps and fidelity at phone-like Wi-Fi without loss. The open item is the loss row:
  ~240 ms stalls at 1% loss over TCP, so the integration should plan a non-TCP transport (QUIC with an unordered
  diff lane, or the PowStream FEC lane) from the start.
- **For Firefox/Chromium, the state hand-off (§4 Phase 1a) stays first.** waypipe can only meet the bar for a browser
  with three changes, two of them waypipe patches: video for ARGB buffers (4 lines, measured working), local
  frame-callback pacing on the server side (measured cap: 71 fps at 3±2 ms, 40 fps at 8±4 ms), a lossless refresh
  after motion stops (static text is otherwise lossy), plus the transport fix above. Each is upstreamable; until then
  a remoted browser is a fallback, not the default.
- Memory mirroring and execution splitting stay dead ends (now with measured dirty rates). CRIU pre-copy is a viable
  sub-second **server-to-server** move for terminal/headless apps (e.g. `.58` → gpu-195), not a phone path.

### 8.6 Proposed phone follow-up (not run)

One verify-queue job in a free window, never in the user's session, no Steam/game changes:

1. Make waypipe 0.11.3 a registered unit in the phone's Arch Linux ARM chroot (same release as the server; the
   patched build if the ARGB video patch is kept), no unmanaged install.
2. On `.58`, start the measurement image as a Compose job (`tools/research/remoting/dc up -d app`, `tc` off) with
   `waypipe --video=h264 server -- firefox …` / `-- kate …` reaching the phone over TCP.
3. Check script `tools/phone/verify/waypipe-window.sh`, queued with `tools/phone/verify/queue.sh add waypipe-window
   tools/phone/verify/waypipe-window.sh`: in the chroot, `WAYLAND_DISPLAY=<KWin socket> WAYLAND_DEBUG=client waypipe
   -s /tmp/wp.sock client` + `socat TCP-LISTEN:5000 UNIX-CONNECT:/tmp/wp.sock`; confirm the window appears as a native
   child surface of a web window (WEB_WINDOWS.md S6), screenshot it; inject the same 60 keys and a 10 s scroll
   (KWin fake-input, or a key script inside the remote app if KWin's virtual keyboard is refused), and log
   key→commit from the client-side `WAYLAND_DEBUG`, bytes from `ss -ti`, Wi-Fi RSSI and TCP retransmits.
4. Pass/fail against the same bar as 8.2; film one run with the S25 at 240 fps for photon latency (REMOTE-WINDOWS §3).
   Also answers §7 Q3 (does KWin on Adreno accept waypipe's DMA-BUFs, or must the client fall back to shm).

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
