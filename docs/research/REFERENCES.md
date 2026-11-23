# External references (PowOS)

One row per external reference used in a research doc or sent by the user. Newest first.

| date | reference | what it gave | used in |
|---|---|---|---|
| 2026-11-23 | https://www.mankier.com/1/waypipe | waypipe options: --compress none/lz4/zstd, --video h264/vp9/av1 (DMA-BUF only), --threads, --no-gpu, bench | native-window-remoting.md |
| 2026-11-23 | https://mstoeckl.com/notes/gsoc/blog.html | waypipe buffer diff design (runs, 256 B gaps, 256 KB chunks), lz4/zstd 1.5-30x, 2019 game numbers (130 MB/s lossless, 4 MB/s hw video), Wi-Fi lag note | native-window-remoting.md |
| 2026-11-23 | https://mstoeckl.com/notes/code/waypipe_to_rust.html | waypipe 0.10 Rust rewrite: Vulkan DMA-BUF path, explicit sync, video via libavcodec | native-window-remoting.md |
| 2026-11-23 | https://packagehub.suse.com/packages/waypipe/0_8_6-bp156_1_3/ | (search summary) 0.10 breaking changes: --video takes an argument, reconnection removed, incompatible with older | native-window-remoting.md |
| 2026-11-23 | https://www.linuxlinks.com/waypipe-running-remote-wayland-applications-on-linux/ | Firefox over waypipe on 2.5 GbE: smooth scrolling/video; GTK4 demo ~75 fps | native-window-remoting.md |
| 2026-11-23 | https://www.tauceti.blog/posts/ssh-x-vs-xpra-vs-waypipe-remote-display-comparison-single-window/ | ssh -X vs Xpra vs waypipe on GbE/KDE Wayland, qualitative only | native-window-remoting.md |
| 2026-11-23 | https://github.com/Xpra-org/xpra/blob/master/docs/Usage/Encodings.md | Xpra per-window encoding choice, scroll pseudo-encoding, NVENC | native-window-remoting.md |
| 2026-11-23 | https://github.com/Xpra-org/xpra/issues/5118 | Xpra motion-search tuning after scroll input | native-window-remoting.md |
| 2026-11-23 | https://github.com/lukaszsobala/xpra-client/pull/3 | Android Xpra client: one MediaCodec per window, low-latency async | native-window-remoting.md |
| 2026-11-23 | https://chromium.googlesource.com/chromium/src/+/HEAD/docs/how_cc_works.md | CompositorFrame = render passes of quads; PaintRecord serialized for GPU raster | native-window-remoting.md |
| 2026-11-23 | https://groups.google.com/a/chromium.org/g/graphics-dev/c/jQ-Q1qrUOlo | OOP raster model: culled paint ops over a ring buffer, LRU resource cache, unmeasured trade-offs | native-window-remoting.md |
| 2026-11-23 | https://chromium.googlesource.com/chromium/src/+/5e542c8e2d79e45ce058ae9d2d5539bf2a7ea547/cc/paint/paint_op_buffer_serializer.cc | (search summary) PaintOpBufferSerializer: transfer cache, paint cache, SkStrikeServer | native-window-remoting.md |
| 2026-11-23 | https://github.com/crosswalk-project/chromium-crosswalk/blob/master/blimp/docs/running.md | Blimp engine/client flags: --use-remote-compositing, TCP/SSL 25467, font flags | native-window-remoting.md |
| 2026-11-23 | https://codereview.chromium.org/2626423004 | (search summary) 'Remove all //blimp code', landed 2017-01-18 | native-window-remoting.md |
| 2026-11-23 | https://github.com/google-ar/WebARonARCore/commit/d7178e48283e3c8ffbf8d45049066b65ab2d22dd | (search summary) removal of blimp remote compositing (proto serialization, RemoteChannel) from content/ | native-window-remoting.md |
| 2026-11-23 | https://www.menlosecurity.com/blog/the-mobile-isolation-era-begins-smart-dom | compositor mirroring (layer tree + display lists) credited to Blimp 2015; Smart DOM claims, no numbers | native-window-remoting.md |
| 2026-11-23 | https://github.com/Samsung/Castanets | distributed Chromium: browser+GPU local, renderers on edge devices; Chromium 76 base | native-window-remoting.md |
| 2026-11-23 | https://github.com/Samsung/Castanets/issues/18 | OOP raster over network stalled on shared memory dependency; deferred 2019 | native-window-remoting.md |
| 2026-11-23 | https://liliputing.com/not-so-mighty-after-all-web-browser-in-the-cloud-business-winds-down/ | (with HN 33583830, blog.chaselambda.com 2022-11-15) Mighty shut down: JS single-core bound, 2x not 5-10x; churn from network stutters | native-window-remoting.md |
| 2026-11-23 | https://firefox-source-docs.mozilla.org/gfx/RenderingOverview.html | Firefox: content process serializes a self-contained WebRender display list to the GPU process | native-window-remoting.md |
| 2026-11-23 | https://mozillagfx.wordpress.com/2019/08/19/moz-gfx-newsletter-47/ | (search summary) WR display list IPC moved from bincode to peek-poke | native-window-remoting.md |
| 2026-11-23 | https://mozillagfx.wordpress.com/2017/11/27/webrender-newsletter-10/ | (search summary) GPU process crash survived by resending the display list | native-window-remoting.md |
| 2026-11-23 | https://searchfox.org/mozilla-central/source/gfx/wr/webrender/doc/blob.md | (search summary, with newsletter #32, bugs 1377595/1406507/1550640) blob images rasterized on WR worker threads; MustPaintOnContentSide | native-window-remoting.md |
| 2026-11-23 | https://blogs.gnome.org/alexl/2019/03/29/broadway-adventures-in-gtk4/ | GTK4 Broadway: render nodes to DOM/CSS diffs, text as images | native-window-remoting.md |
| 2026-11-23 | https://github.com/nexumia-de/phosh-toolkit/pull/57 | GTK 4.20 shared icon nodes assert in gtk4-broadwayd | native-window-remoting.md |
| 2026-11-23 | https://www.qt.io/blog/2018/11/23/qt-quick-webgl-release-512 | (search summary, with lists.qt-project.org 2022-June/042712, forum.qt.io 130312) Qt WebGL QPA: Qt 5.12 release, one connection, no Qt 6 release | native-window-remoting.md |
| 2026-11-23 | https://docs.mesa3d.org/drivers/venus.html | Venus: Vulkan serialization over virtio-gpu; renderer requirements | native-window-remoting.md |
| 2026-11-23 | https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html | (search summary) Venus needs hostmem + blob resources | native-window-remoting.md |
| 2026-11-23 | https://android.googlesource.com/platform/hardware/google/gfxstream/+/fbc9e43e236777dacf23c0d4bf71dc414df984a9/README.md | (search summary) gfxstream streams GL/Vulkan guest→host, process→process, over sockets | native-window-remoting.md |
| 2026-11-23 | https://github.com/emirhancabukk/gpu-over-ip-research | Venus over TCP: >=3 blocking RTT per sync call, runtime linear in RTT, no frame drawn | native-window-remoting.md |
| 2026-11-23 | https://news.ycombinator.com/item?id=41206401 | Juice GPU-over-IP anecdote: 5-20 ms on a LAN for graphical apps | native-window-remoting.md |
| 2026-11-23 | https://www.microsoft.com/en-us/research/publication/kahawai-high-quality-mobile-gaming-using-gpu-offload-3/ | Kahawai collaborative rendering: same quality at 1/6 thin-client bandwidth, idTech 4, 50-person study | native-window-remoting.md |
| 2026-11-23 | https://alecw.azurewebsites.net/work/papers/mobisys-2015-outatime.pdf | (search summary) Outatime: masks up to 120 ms (250 ms in 2014 TR); AppStreamer arXiv 2001.08169 cites 1.51-4.54x bandwidth | native-window-remoting.md |
| 2026-11-23 | https://popcornlinux.org/publications/mars2016.pdf | (search summary, with ASPLOS'17 ssrg.ece.vt.edu) Popcorn cross-ISA migration 1.2/8.7 ms, DSM faults 80-141 us over PCIe | native-window-remoting.md |
| 2026-11-23 | https://www.ssrg.ece.vt.edu/papers/vee20-h-container.pdf | (search summary, with ACM 10.1145/3524452) H-Container: cross-ISA container migration 10-100 ms, IR-lifted binaries | native-window-remoting.md |
| 2026-11-23 | https://sites.cs.ucsb.edu/~rich/class/cs293-cloud/papers/clonecloud.pdf | (search summary, with COMET OSDI'12 and MAUI) mobile code offload: method/thread granularity, COMET field-level DSM | native-window-remoting.md |
| 2026-11-23 | https://arxiv.org/pdf/2107.13848 | (search summary, with AIFM OSDI'20 and the Fastswap thesis) far memory: Fastswap <5 us, Infiniswap up to 40 us, RDMA | native-window-remoting.md |
| 2026-11-23 | https://www.usenix.org/system/files/osdi18-shan.pdf | (search summary) LegoOS splitkernel on RDMA/InfiniBand, busy-poll RPC | native-window-remoting.md |
| 2026-11-23 | https://ieeexplore.ieee.org/document/9610311/ | (search summary) Nomad: cross-platform wasm live migration <2 ms fixed delay, <5% overhead | native-window-remoting.md |
| 2026-11-23 | http://www.shudo.net/publications/202510-MPLR-2025-WASM/tamura-MPLR-2025-WASM.pdf | (search summary) Wanco: cross-ISA checkpoint/restore of AOT wasm via OSR | native-window-remoting.md |
| 2026-11-23 | https://man7.org/linux/man-pages/man2/seccomp_unotify.2.html | (search summary, with USENIX Sec'22 Schrammel et al.) seccomp user notification mechanics; filter overhead up to 2.6 ms | native-window-remoting.md |
| 2026-11-23 | https://www.mcs.anl.gov/papers/P5004-0813_1.pdf | (search summary) rCUDA near-local on InfiniBand, noticeably slower on 1 GbE | native-window-remoting.md |
| 2026-11-23 | https://github.com/skylot/jadx (v1.5.1) on the OnePlus Open's own oplus-framework.jar, oplus-services.jar, services.jar, SystemUI.apk (OxygenOS, pulled 2026-10-23) | decompiled pocket-studio / Open Canvas capture paths (needInterceptStartForSplitScreen, needInterceptActivityForMinimized, CanvasCalculateLayoutRect, OplusSplitScreenAppReader) | pscanvas.md |
| 2026-11-12 | https://github.com/ValveSoftware/wine/tree/experimental_11.0 (dlls/ntdll/unix/env.c, programs/wineboot/wineboot.c, programs/services/services.c) | first process of a session runs `wineboot --init` and waits; wineboot waits for services.exe, which signals after starting every auto-start service | broforce-engine-init.md lever 1 |
| 2026-11-12 | https://github.com/ValveSoftware/Proton/blob/experimental_11.0/proton | `waitforexitandrun` runs `wineserver -w` before the game; `run` doesn't | broforce-engine-init.md lever 1 |
| 2026-11-12 | https://github.com/dnSpy/dnSpy-Unity-mono/tree/master/unity-2017.4.7/mono/mini | Unity 2017.4.7 Mono: AOT loader hook always installed, loads `<assembly>.dll.dll` (GUID + build-info checked), Win32 AOT compiler path | broforce-engine-init.md lever 2 |
| 2026-11-12 | https://github.com/FEX-Emu/FEX (eff9f45: Config.json.in, FEXCore/include/FEXCore/Utils/SHMStats.h) | defaults of the code cache / DiskCache / SMC / TSO options; ProfileStats per-thread counters (JIT time, SMC, DiskCache hits) | broforce-engine-init.md lever 3, measurement 1 |
| 2026-11-12 | https://fex-emu.com/FEX-2610/ | disk cache 1 GB cap, in-memory buffer, prune on update; no startup numbers | broforce-engine-init.md lever 3 |
| 2026-11-12 | https://github.com/FEX-Emu/FEX/pull/6072 | (search snippet) WoW64 code-cache load fix, FEXOfflineCompiler process-all on Windows | broforce-engine-init.md lever 3 |
| 2026-11-12 | https://www.linuxcompatible.org/story/fex26111-stable-patch-ships-with-codecache-rework-and-steam-frame-crash-fix | (search snippet) FEX-2611.1 code-cache keying shared across Linux/WoW64/ARM64EC | broforce-engine-init.md lever 3 |
| 2026-11-12 | https://windowsforum.com/news/valve-enables-fex-code-cache-for-proton-on-arm-plans-steam-pre-caching.451345/ | Proton Experimental (ARM) has the FEX cache on; Steam pre-caching planned, no timetable or numbers | broforce-engine-init.md lever 3 |
