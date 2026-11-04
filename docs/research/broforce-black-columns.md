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

## Import cache (xwayland-kgsl 24.1.13-7, patch 0012, agent/xw-import-cache)
- Cause of the ~40 imports/s: lfdevs's 0003 `xwl_glamor_kgsl_refresh_dri3_pixmap` re-created the DRI3 pixmap's
  EGLImage before every Present copy and destroyed the previous one at once (its reason: stale sampling of a
  long-lived EGLImage on the proot path). 0012 keeps one import per client dma-buf (keyed by plane 0's st_dev+st_ino
  and the shape, shared across pixmaps, reused per present), freed only with its last pixmap and after glFinish.
- New 30 s line: `Xwayland KGSL: last 30s: client dma-buf imports N / reuses N / frees N`. Expect imports ~4 per
  swapchain, reuses ~ presents. Unit test: pkgs/xwayland-kgsl/test/run.sh (import-cache-test).
- Not claimed as the column fix: it removes the per-present map/unmap and the unmap under a running copy, which is
  one candidate. Check after install: the line's counts + the checkered-frame rate (bf-overlay-watch.sh). If frames
  freeze/stale (lfdevs's old symptom), the GL driver is not invalidating its caches between submits.
- Stronger lead in parallel (coordinator, 2026-11-03): dmesg of the same run has 738x `kgsl kgsl-3d0: CP: AHB bus
  error, CP_RL_ERROR_DETAILS_0:0x10008e07 CP_RL_ERROR_DETAILS_1:0x12144` - a protected register write in some
  command stream (Turnip or freedreno); agent cp-fault is decoding it. Count those per run next to 0012's line.

## Coherency override (bf-coherent, 2026-11-04)
- Origin of `tu_override_uncached_as_cache_coherent=true` in the game's environ and Mesa's "default value of option
  tu_override_uncached_as_cache_coherent overridden by environment": **FEX's WoW64 module**, not PowOS and not the
  user. Only `Proton Experimental (ARM64)/files/lib/wine/aarch64-windows/libwow64fex.dll` (and libarm64ecfex.dll)
  carry the string, next to `__wine_set_unix_env`: FEX sets it inside every Proton-ARM64 game process at start, so
  no PowOS env file can unset it (Mesa's env beats drirc too). Searched with no hit (2026-11-04, read-only):
  /etc, /usr/lib/environment.d, ~/.config (environment.d, powos/steam-env, proton-settings.json), Steam userdata
  launch options (274190 = only `unity-screen %command%`), Proton user_settings.py, pkgs/steam/steam-env,
  /usr/share/drirc.d, every branch of this repo (`git log -S tu_override_uncached --all`: only the evidence log).
  RimWorld's native Player.log (2026-10-17) prints it too: FEX sets it for x86 guests generally.
- Why FEX sets it (upstream FEX's reason, not measured here): x86 code expects normal cacheable memory; unaligned
  and atomic accesses that FEX emits on Arm fault or crawl on write-combined (Normal-NC) mappings of GPU memory.
- What it does (Mesa ef25369b tu_device.cc:1820-1830, tu_knl.cc:57-65): only when KGSL accepts IOCOHERENT
  (tu_knl_kgsl.cc:2020 probe; this phone's kgsl-smmu@3da0000 has `dma-coherent`), every HOST_VISIBLE|HOST_COHERENT
  uncached allocation becomes a WRITEBACK + KGSL_MEMFLAGS_IOCOHERENT BO (tu_knl_kgsl.cc:348-355). Coherency then
  rests on the SMMU snooping CPU caches; lfdevs's own comment (tu_device.cc:1802) says some Android KGSL kernels
  report IOCOHERENT while mappings still need cache maintenance, and the gfx3d_user context bank here carries only
  `qcom,iommu-dma` (no `dma-coherent`). If that is this phone, DXVK's CPU-written upload/constant buffers reach the
  GPU stale in 64-B lines = the 16-px black columns, and stale command data could explain the CP AHB bus errors.
  Not proven: no launch was made (games are not started by agents).
- Still exported with the new Turnip (vulkan-freedreno-kgsl 26.3.0-1 patched): yes - FEX sets it independently of
  the driver, and the installed /usr/lib/libvulkan_freedreno.so still has the option (and TU_KGSL_FORCE_NONCOHERENT).
- Measurement: `bf-checker.sh base noncoherent` (variant `noncoherent` = Proton env TU_KGSL_FORCE_NONCOHERENT=1:
  no cached-coherent type -> the override is a no-op, readback memory becomes cached non-coherent with explicit
  invalidates). Count black-column frames + `CP: AHB bus error` per variant. If noncoherent removes them: the real
  fix is in our Turnip (pkgs/vulkan-freedreno-kgsl) - treat KGSL's IOCOHERENT as unusable unless the user context
  bank is dma-coherent (or keep the cached BOs but clean/invalidate around submits), so FEX's override falls back to
  write-combined memory; not by unsetting FEX's flag, which FEX needs.
