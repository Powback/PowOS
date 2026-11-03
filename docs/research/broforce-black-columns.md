# Broforce black columns - buffer layout and reader cache (bf-columns, 2026-11-03)

Board task `broforce-games-black-noise-flicker-artifacts-ove`. Fences ruled out earlier (kgsl-fence): Mesa
ef25369b attaches a real KGSL fence on every present; Xwayland 0011's "stub" = fence already signalled or none
(kernel 0005 drops signalled fences). xwayland-kgsl 24.1.13-6 relabels that counter accordingly.

## What the corrupt frames are (bfo-2026-11-03_1902, Xwayland's own XGetImage copy, half-res)
- h029/h052/h058: 8.1 % non-black each (111.9k/111.9k/111.8k px - the same structure every time); every non-black
  pixel has x mod 48 (full res) in [0,16); inside those strips only sparse fragments in the scene's true colours.
- h087-h089: the scene intact except x mod 48 in [32,48): black, with sparse true-colour dots.
- So: full-height columns with a 192-byte period at 32 bpp (16 px = one 64-B cache line of every three), stable
  down the frame -> the row pitch is a multiple of 192 B (2268 px aligned to 64 px = 2304 px = 9216 B = 48 x 192 B).
  A memory-address pattern of a LINEAR buffer, not a tile/UBWC misread: a tiled or UBWC image read as linear
  scrambles every pixel (4-row tile structure), and linear read as UBWC decodes flag bytes into noise.

## (1) Layout: every hop is linear (Mesa ef25369b, Xwayland 0001-0003)
- Xwayland advertises only LINEAR to DRI3 clients (0003 xwl_dri3_get_modifiers); without modifiers WSI sets
  scanout (wsi_common_drm.c:597) and Turnip makes scanout / LINEAR-modifier images linear (tu_image.cc:707,
  tu_CreateImage's wsi_info->scanout).
- freedreno (Xwayland's GL, kgsl backend) imports LINEAR/INVALID as TILE6_LINEAR (fd6_resource.cc:316-334; KGSL
  bos have no metadata) and refuses other modifiers on kgsl (freedreno_resource.c:1678).
- Xwayland's window pixmaps start as normal (UBWC-capable) textures but every export on kgsl is shadowed to LINEAR
  first (fd_resource_get_handle, freedreno_resource.c:1219-1233). Ruled out.

## (2) Reader/writer cache: the remaining candidate
- Both sides allocate shared buffers from /dev/dma_heap/system (tu bo_init_new_dmaheap, freedreno
  kgsl_bo_new_dmabuf). On this phone that is qcom,system (cached; no uncached heap exists in /dev/dma_heap).
- Coherency then rests on KGSL_GPUOBJ_SYNC / GPUMEM_SYNC_CACHE on the imported object (kgsl_bo_from_dmabuf,
  kgsl_sync_imported_bo_to_gpu); freedreno's own comment says some KGSL kernels don't implement it, and
  kgsl_bo_cpu_prep is a no-op (no DMA_BUF_IOCTL_SYNC around CPU maps of imports).
- Zeroed 64-B lines in a freshly allocated buffer (heap zeroing left in the CPU cache, evicted over the GPU's
  writes, or read back stale) fit black lines with the GPU's data surviving between them, and the user's "when I
  open an overlay" (KWin holds buffers -> Xwayland allocates fresh window buffers).
- Not proven: needs the sync ioctls' return codes on the device during play (below).

## Next run (one game launch, read-only otherwise)
Start Xwayland with DMD_VA_LOG=1 (freedreno kgsl, Xwayland: "sync-to-gpu ... cache=rc/errno obj=rc/errno"
and "dma-buf GPU cache sync failed") and the game with TU_KGSL_DEBUG_IMPORT=1 (Turnip's import path), run
bf-overlay-watch.sh while the user opens overlays. Failing syncs + checkered frames on fresh buffers = fix in the
allocator (uncached/IO-coherent allocation or DMA_BUF_IOCTL_SYNC before the GPU's first write). TU_DEBUG=noubwc
would not change anything: no hop uses UBWC.

## Live run 22:32 (read-only, game running; ~/.cache/powos-verify/bfo-2026-11-03_2232/)
- Xwayland's own copy (XGetImage) checkered in 10 of 120 frames: 3 of 53 with an overlay up, 7 of 67 without ->
  not overlay-bound; the damage is in the game buffer / Xwayland pixmap, upstream of KWin.
- kgsl tracefs, 30 s (kgsl-trace.txt): cache syncs are NOT missing. Xwayland 4135 kgsl_mem_sync_cache op=ci on the
  game's 22487040-B (9216 x 2440) imports, KWin 1341 on its own; the game issued none in the window (Turnip cleans
  once at import/alloc, kgsl_bo_init_dmabuf). Both import with flags=0 (no KGSL_MEMFLAGS_IOCOHERENT), cachemode
  writeback ('b'); gfx3d_user context bank is not dma-coherent in DT (kgsl-smmu is) -> the syncs do real work.
- Nobody CPU-writes those buffers (useraddr N on both sides), so a CPU-cache clean has nothing dirty to write back:
  CPU-cache coherency is now an unlikely cause.
- New: Xwayland re-imports the game's buffers ~40x/s (1219 GPUOBJ_IMPORT + 1239 GPUOBJ_FREE in 30 s, new gpuaddr each
  time; ~0.23 s per mapping). freedreno-kgsl submits carry no memobj list, so KGSL may unmap a buffer while a glamor
  copy still reads it. No kgsl_mmu_pagefault in a 15 s trace though. Next: why Xwayland drops/re-creates the DRI3
  pixmap's bo per present (bo cache / 0011 import path), and keep one import per dmabuf.
