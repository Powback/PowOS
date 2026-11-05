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

## Results (kwin 3.65 on the phone, Broforce soak 2026-11-05 16:06, cover screen)

    window task 1 draw: 0.92-1.07 ms CPU, 1.56-1.85 ms wall per frame (3.8-4.2 % of a core); direct-eligible 193/193 .. 208/208
    window task 1 client buffer: 1116x2484 fourcc XR24 modifier 0xffffffffffffff (implicit) planes 1 pitch 4608 offset 0 transform 0, task buffers 1116x2484
    window task 1 frames: last 5 s 368-430 commits, 200-202 drawn (40.0-40.4 fps)

- **Every frame is eligible** (100 %, no blocker): one full-screen window, single-plane linear XRGB8888, exactly the
  task's size, no rotation. pitch 4608 = 1152 px (64-px aligned), the same alignment QTI gralloc gives linear RGBA
  - the template splice needs no stride override.
- **The composite is ~4 % of a core, not 12.8 %.** The direct path removes that plus a ~1.6 ms GPU pass per frame
  (the game's own GPU) - worth doing, but it is a third of kwin_wayland's cost. The rest is per-commit work: KWin
  sees **~80 commits/s for 40 drawn frames** (2 Xwayland commits per game frame - 0013's flips plus another commit
  per frame, e.g. the 100 ms KGSL flip timer or a damage-only commit). Halving those commits is likely the bigger,
  cheaper kwin win (an Xwayland-side change) and should go before steps 1-5 above.
- Same soak (`bf-quiet-2026-11-05_16xx`, PASS 600 s): kwin_wayland 14.0-14.8 %, surfaceflinger 17.7-18.3 %, all 7 HWC
  layers DEVICE, game 107-111 %, 40 fps, skin 35.1 -> 38.3 C. (kwin 12.8 % / game 79 % at 08:02; the probe itself is a
  clock read per frame - the difference is the session's state, not 0057.)

## Step 1 result: the cloned buffer works (2026-11-05 18:14, cover screen, agent direct-scanout-1)

`tools/phone/verify/direct-scanout.sh` (queued: `queue.sh add --screen cover <task> .../direct-scanout.sh`): a root
app_process host (`direct-scanout/DsTest.java`) puts a layer on the active display's layer stack; `dstest.c` allocates
two Broforce-shaped dma-bufs from `/dev/dma_heap/system` (1116x2484, pitch 4608, 11448320 bytes, XR24 byte order, a
known pattern, pitch padding filled with garbage), clones a template AHardwareBuffer's handle onto each and shows them
on a child ASurfaceControl. **PASS, both variants** (the clone's size field = the dma-buf's / the template's - equal
here, 11448320):

- template: format 5 (BGRA_8888 = XR24's bytes), usage 0x902 -> stride 1152 px = pitch 4608: **no stride override**.
  QTI handle: numFds 2, numInts 24: `magic 'gmsm', flags 0x100008, width 1152, height 2484, unaligned 1116x2484,
  format 5, buffer_type 0, layer_count 1, id (2 ints), usage (2 ints: 0x902), size 11448320 (int 13), offset 0, ...`.
- `AHardwareBuffer_createFromHandle(desc, clone, 3 /* CLONE */)` = 0 for the foreign fd, template released after.
  **The method value matters**: 1 (TAKE_HANDLE) is refused with -22 even for the template's own handle - REGISTER is
  2, CLONE 3 (vndk/hardware_buffer.h = GraphicBuffer::HandleWrapMethod).
- shown with no CPU lock first: first OnComplete 6.4 ms; SF's HWC list: `powos-ds-clone` **DEVICE** shown and while
  flipping A/B at ~52 transactions/s (165/165 completes, 163-165 release fences signalled, 0 timeouts).
- screencap of the display = the pattern, **0 of 2772144 pixels differ** (after the flips too); buffer B's X byte 0
  under OPAQUE also fine. CPU lock of each clone: stride 1152, 0 mismatches against the pattern.
- not proven by this: the panel's own scanout (screencap goes through RenderEngine, not the DPU; DEVICE + no HWC
  error in logcat is the evidence there), and Broforce's real buffers (turnip-kgsl allocates from the same system
  heap with the same pitch - the test copies that layout, not the buffers).

Next: step 2 (app side, flag off) then 1/3/4 as above - the "high risk" row is retired.
