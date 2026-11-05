# Window-task direct scanout (skip KWin's composite for a full-screen game)

Board task `broforce-fps-low-cpu-bound-under-fex`, agent kwin-direct, 2026-11-05. Status: **design + probe** (kwin
0057, pkgrel 3.65: measures, changes nothing). Background: docs/research/broforce-fps.md "Present path".

## Where the frame goes today

game (Wine X11 Vulkan WSI, turnip-kgsl; its swapchain images are dma-heap dma-bufs, linear) -> DRI3 pixmap ->
Xwayland **flips** it to KWin as itself (xwayland-kgsl 0013: linux-dmabuf, XRGB8888, 0 copies) -> KWin anland window
task: `AnlandWindowTask::render()` draws the window item into the consumer buffer it was offered (`select_dmabuf`
-> one full-screen GL composite per game frame, EGL native fence) -> the app's `native_consumer.c` render thread
`queueBuffer`s that gralloc buffer on `SurfaceView[PowosWindowActivity](BLAST)` -> SurfaceFlinger -> HWC (DEVICE,
`isOpaque=true`, 1116x2484, bufferTransform 0 on the cover screen; all 7 layers DEVICE since 11-05).

The one remaining per-frame copy is KWin's composite: kwin_wayland 12.6-13.2 % of a core in the 08:02 soak. How much
of that 12.8 % is the composite itself (vs. Wayland dispatch, Xwayland's commits, transactions) is **unknown** -
probe 0057 measures it (below) before anyone builds the real path.

## The direct path

For a frame where the client's buffer *is* the frame, KWin skips the draw and the app shows the client's dma-buf
itself. The BufferQueue can't carry it (its slots are gralloc buffers it allocated; `attachBuffer` is libgui C++, out
of an app's linker namespace), so the app shows it on its own **ASurfaceControl** (public NDK, API 29) - a child of
the SurfaceView's surface, above it - via `ASurfaceTransaction_setBuffer(AHardwareBuffer)`.

The hard part is the AHardwareBuffer: Android has no public "dma-buf -> AHardwareBuffer". The way that fits this
device (kalama, Android 16, `android.hardware.graphics.mapper@4.0-impl-qti-display`, kernel 5.15):

1. `AHardwareBuffer_allocate` a template of the same size/format (R8G8B8X8, usage GPU_SAMPLED | COMPOSER_OVERLAY |
   CPU_READ_RARELY - the CPU bit keeps QTI gralloc linear, no UBWC), `AHardwareBuffer_getNativeHandle` (LLNDK,
   dlsym from libnativewindow.so),
2. clone that handle (QTI `private_handle_t`: fd, fd_metadata, magic 'gmsm', flags, width=aligned stride, height,
   ..., id, size, offset) with `fd` = the client's dma-buf and the stride/size fields = the client's pitch,
3. `AHardwareBuffer_createFromHandle(desc, handle, REGISTER)` (LLNDK, dlsym) -> the mapper's importBuffer, which
   imports both fds and maps the metadata fd (the template's: crop, dataspace, no UBWC); release the template.

One AHardwareBuffer per client buffer (a swapchain has 3-4), cached by the client buffer's identity; each keeps
its own gralloc `id` (the template's), so HWC/SDM's per-id caching sees a new buffer each frame.

### Steps, sized

| # | step | where | size | risk |
|---|---|---|---|---|
| 0 | **probe**: per-frame composite CPU + eligibility + client buffer layout (this commit) | kwin 0057 | done | none (logs only) |
| 1 | protocol: `DATA_MSG_DIRECT_FRAME {buffer id, w, h, pitch, fourcc, modifier}` (+ SCM_RIGHTS fd the first time an id is seen), `INPUT_TYPE_DIRECT_RELEASE {buffer id}`, `DIRECT_FORGET {id}`; capability bit in the HELLOs (protocol.h has no versioning yet - its own HACK note) | protocol.h both sides | 0.5 d | low |
| 2 | app: AHB-from-dma-buf (template splice above) + a self-test on first use (lock CPU-read a pixel row of both, compare); refuse direct for good on any mapper error | native_consumer.c, anw_hidden.h | 0.5 d | **high: the one unknown** - QTI mapper may validate size vs fd, HWC may reject the buffer |
| 3 | app: child ASurfaceControl over the SurfaceView, `setBuffer` + `setVisibility` per frame; release = `ASurfaceTransactionStats_getPreviousReleaseFenceFd`, CPU-wait it on the render thread, then `DIRECT_RELEASE`; switching direct<->composited in ONE transaction (show child with its first buffer / hide it when a composited frame is queued), so no black frame | native_consumer.c | 1 d | medium (z-order, transitions, fold) |
| 4 | KWin: in `render()`, when `directBlocker()` is empty and the consumer said it can: hold a `GraphicsBufferRef` per id until its release, send the id (fd once), `framePainted` as today; any blocker -> composite as today (non-fullscreen, popups/overlays, subsurfaces, tiled/multi-plane/other format, size mismatch, pre-rotated, CPU copy). Readiness: KWin applies the commit only after the dma-buf's implicit fence signals (transactions), so the frame goes with acquire fence -1 | anland_window_task.cpp | 1 d | medium (buffer lifetime: a client buffer released to Xwayland while SF still scans it = tearing) |
| 5 | device proof: bf-quiet 600 (kwin CPU, SF, HWC DEVICE on the child), bf-checker (0 checkered/dashes), bf-pacing fps, fold/unfold + a popup over the game (falls back) | verify queue | 0.5 d | - |

Total ~3.5-4 days; does not fit one agent window. Order: step 2's self-test alone first (it decides whether the
whole path exists), then 1/3/4.

### Fallbacks kept

The composited path stays the default and every frame's choice is per frame (`directBlocker`). A consumer without
the capability, a mapper refusal, a self-test mismatch -> composited for that surface's lifetime.

### Alternatives considered

- **Consumer-allocated buffers the game renders into** (gralloc buffers through a linux-dmabuf/wl_drm allocator):
  the game's Vulkan WSI on X11 allocates its own images (DRI3 PixmapFromBuffers); Xwayland never allocates them, so
  this needs Mesa WSI changes on top of an allocator protocol. Larger than the splice and touches the game stack.
- **Cheaper composite** (glBlitFramebuffer of the imported client texture instead of the scene renderer): still one
  GPU pass per frame; only worth it if the probe shows the scene renderer's CPU, not the GPU pass, is the cost.

## Probe 0057: how to read it

kwin logs, per window task, every 5 s while frames flow (next to the `frames:` line):

    window task N draw: X ms CPU, Y ms wall per frame (Z % of a core); direct-eligible A/B[, composited: why=n ...]
    window task N client buffer: WxH fourcc XR24 modifier 0x0 planes 1 pitch P offset 0 transform 0, task buffers WxH

Z is what the direct path removes from kwin_wayland at most (the composite's CPU on KWin's thread; the GPU pass also
goes). A/B is how many of Broforce's frames it could take. Measure: `bf-quiet.sh 600`, then
`journalctl --user -u plasma-kwin_wayland | grep -E 'draw:|client buffer:'` (or the kwin log bf-quiet keeps).

Results: (pending the first soak with kwin 3.65)
