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
- Fix (turnip-noncoherent, vulkan-freedreno-kgsl 26.3.0-2, patch 0002): Turnip's KGSL backend trusts the IOCOHERENT
  probe only when `/sys/firmware/devicetree/base/soc/qcom,kgsl-iommu@*/gfx3d_user/dma-coherent` exists (no readable DT:
  distrusted on `gpu_model` Adreno740*). On this phone it doesn't, so the physical device takes the
  TU_KGSL_FORCE_NONCOHERENT path: no cached-coherent type, FEX's override is a no-op, and Turnip's own internal BOs
  (command streams, tu_bo_init_new: cached-coherent whenever the probe passed, override or not) are write-combined
  too - the second suspect for the CP AHB bus errors. Each process logs one `turnip: KGSL accepts IOCOHERENT but the
  gfx3d_user context bank isn't dma-coherent` warning. `TU_KGSL_TRUST_IOCOHERENT=1` restores the kernel's answer for
  an A/B. Still to measure on a game run: black-column frames + AHB errors with 26.3.0-2 vs `TU_KGSL_TRUST_IOCOHERENT=1`.

## Turnip pin (turnip-latest, 2026-11-04)
- **Why it was old:** ef25369b (2026-10-04) was Andromarchy's validated Mesa: the tip of lfdevs's termux-va topic
  branch `test/add-va-bridge`, 32 VA-bridge commits on a ~2026-09-29 upstream merge. 56007a05 (10-13) pinned it as a
  commit archive because lfdevs rewrote that branch and `clone -b ... && checkout ef25369b9c` broke - a pin for
  reproducibility, never meant as "current". Nothing ever moved it: no task owned "keep Turnip current", and the
  26.3.0 pkgver (from the tree's 26.3.0-devel VERSION) read like a release, so it didn't look stale.
- **adreno-main is not the code branch.** `compare ef25369b...adreno-main` = diverged, 45 ahead / 8938 behind: the 45
  are all README/CI/workflow/FUNDING commits (2026-04-04..10-30) on a 26.1.0-devel tree from 2026-04-04 - moving
  there would have been a 6-month DOWNGRADE. None of the 45 touches turnip, kgsl, a7xx, coherency, caches or BV/BR.
  lfdevs's Mesa source lives on **dev/adreno-main** (VERSION 27.0.0-devel; release mesa-27.0.0-devel-20261025-r1 is
  built from it): eb3e7fd4 (2026-10-29), 4031 commits ahead of ef25369b, 32 behind (the old termux-va commits,
  re-landed there in rewritten form: src/termux-va, tva_bridge.c and TU_KGSL_FORCE_NONCOHERENT are all present).
- **Relevant fixes between ef25369b and eb3e7fd4** (159 commits in src/freedreno/vulkan, 57 common/registers, 83 gallium
  freedreno). Nothing for the CP AHB bus error (no commit touches RB_CCU_CNTL emission or CP_SET_THREAD in
  tu_init_hw) and nothing for uncached/IOCOHERENT memory (only the fork's own debug env + TU_KGSL_FORCE_NONCOHERENT,
  which we already had). Worth having:
  - KGSL sync/fence correctness (09-30..10-01): `tu/kgsl: Correctly merge timestamps and sync files` 1da50a1b,
    `Handle FD-only waits in wait_any` 2e30bbd3, `Select the earliest timestamp for wait-any` 59c291f6,
    `Correctly interpret poll result` 9dea49d1, `Prevent indefinite wait times for 0 timeout waits` e984ef29,
    `Always round up the wait timeout` 6cb65e61, `Prevent overflow in kgsl_queue_wait_fence` b889ab52,
    syncobj error propagation 7e0a2b88/11b1a235, OOB in kgsl_syncobj_foreach_state 9a6269f6 - the present/acquire
    fence path every DXVK frame goes through.
  - `tu/kgsl: Fix BDA capture/replay failures due to deferred VA frees` a1e9f888 (10-21); dmabuf import / user-map
    error handling + missing munmap c4aa23ef/d498e083 (09-14).
  - Cache/flush: `tu: Use SUBPASS(_SLICE)_FENCE for GMEM invalidation` 99200197 + by-region deps cc1cf17c + SLICE_FENCE
    flush 10b1ef46 + `Don't hardcode feedback_invalidate flushes` b280f888 (09-04); `tu: Fix bindless descriptor
    invalidate sequence` c88b6ebd (10-05); `tu/a6xx: Invalidate shared consts before disabling them` cadc7e42;
    `CopyQueryPoolResult should wait for mem writes` 3a35704e, XFB query writes 48614ecf.
  - `tu: Workaround 32B rollover bug in GPU firmware` 118ec7f4 (08-24); `freedreno/registers: Sync xml from kernel`
    81fae858; `tu: Make CmdClearAttachments record TU_ACCESS_BLIT_WRITE_GMEM access` a995eaed; LRZ fixes ea3bfc00,
    1f8c5d43, 0cd184e9.
- **Upstream Mesa main after the fork's last merge** (gitlab, src/freedreno/vulkan since 10-20): `tu: Add
  QCTDD08049535_numnonposvar_alignment for a7xx gen1/gen2` 2fae1d0d (10-27, Adreno 740 = gen2: odd FS varying slot
  counts give garbage varyings, "Fixes rendering corruption in Devil May Cry 5") - cherry-picked as our 0003. The
  rest is other GPUs (A635 macrotile, a630 binning, A8xx draws) or query/CTS behaviour.
- **Our patches:** 0001 (RB_CCU_CNTL + RB magic regs on BR only) and 0002 (distrust IOCOHERENT unless gfx3d_user is
  dma-coherent) are in neither the fork nor Mesa main; both applied to eb3e7fd4 with offsets only (regenerated).
- **New:** vulkan-freedreno-kgsl 27.0.0_devel.20261029.geb3e7fd4-1 (pkgver = VERSION + commit date + sha, not a
  release), 0001-0003; rootfs-in-container.sh MESA_SRC_COMMIT = the same eb3e7fd4 (Gallium freedreno matches; its
  source cache is now keyed by commit - the old fixed `mesa-src.tar.gz` name would have kept serving ef25369b).
  How to move the pin next time: the PKGBUILD header.

## Which driver the game runs (bf-which-driver, 2026-11-04) - NOT ours
- **Broforce runs on x86 Proton, not Proton ARM64.** config.vdf CompatToolMapping 274190 = `proton_experimental`;
  compatdata/274190/config_info = `Proton - Experimental` 11.0-100 (powos-steam-compat mode "kept": the prefix predates
  arm64). All of Wine runs under Valve's FEX compat tool (steamapps/common/FEX-Emu) inside SteamLinuxRuntime_4 (x86).
- **Live maps (tools/phone/verify/bf-driver.sh, job 20261104-154019-5508, ~/.cache/powos-verify/bfd-2026-11-04_1540/):**
  Broforce_beta.exe, explorer.exe and xalia.exe (exe = FEX) all map `/run/gfx/main/usr/lib64/libvulkan_freedreno.so`
  inode **270485** = `/usr/share/fex-emu/RootFS/Fedora_44/usr/lib64/libvulkan_freedreno.so` (FEX's fetched x86_64
  RootFS, Mesa 26.2.0 git-9f0a761020, 2026-08-12, KGSL-capable, owned by no package) plus its x86 loader
  libvulkan.so.1.4.341 (270478). Our package's file is inode 414382 - mapped by nothing. No libvulkan-guest/host.so:
  FEX's Vulkan thunk is NOT active (ThunksDB overlays only `@PREFIX_LIB@/libvulkan.so.1`; inside pressure-vessel the
  guest loads the loader from `/usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu/` -> `/run/gfx/main/...`).
- How: pressure-vessel's graphics provider for x86 is FEX's RootFS (`/usr/share/guestos/fex-mesa` -> Fedora_44, set by
  pkgs/steam/steam.install), mounted at /run/gfx/main; its x86_64 ICD jsons go into VK_ICD_FILENAMES/VK_DRIVER_FILES.
  The aarch64 json (`/run/host/usr/lib/libvulkan_freedreno.so` = ours) is listed too but an x86_64 loader skips it.
- So every Turnip change so far (26.3.0-1/-2, 27.0.0 -1/-2: 0001 RB_CCU_CNTL, 0002 IOCOHERENT distrust, 0003
  varyings) never reached this game; X7.44% vs 6.82% is noise between two runs of the SAME x86 Turnip 26.2.0. It
  also runs Turnip itself emulated under FEX (CPU cost on the CPU-bound main thread). Our 0002 warning can't appear:
  `tu_override_uncached_as_cache_coherent=true` is in the env and 26.2.0 honours it.
- Side finding: KWin (pid 11413, started before the 14:23 install) maps `/usr/lib/libvulkan_freedreno.so (deleted)`,
  inode 719257 - the pre-install Turnip, until KWin restarts. Not the game's path.

## Who emits the CP AHB bus errors (same day)
- dmesg since boot (12:09 UTC): the first error at 8182 s = 14:25:32 UTC, the last at 8283 s = 14:27:13 - exactly the
  15:24 checker's game window (15:25:34-15:27:14 local); none in the 2h16m of KWin + Xwayland (rootfs gallium
  freedreno) before it, 0 in 10 s idle after. During the bf-driver run: 40 in 20 s = the printk ratelimit's cap
  (10 per 5 s, "N callbacks suppressed"), so the true rate is higher. KGSL doesn't name the context; the errors come
  and go with the game's process, whose Turnip is FEX's unpatched 26.2.0 (no RB_CCU_CNTL-on-BR fix) - consistent
  with 0001's diagnosis. Rootfs gallium (KWin/Xwayland) is not the source.

## Fix at the cause (next step)
Make x86 games use our Turnip. Two ways, the first preferred:
1. **FEX Vulkan thunk inside pressure-vessel**: the guest's libvulkan.so.1 becomes FEX's libvulkan-guest.so, Vulkan
   goes to the host aarch64 loader -> /run/host/usr/lib/libvulkan_freedreno.so (ours, patched, native - no emulated
   driver on the CPU-bound main thread). Needs the ThunksDB overlay to match the pressure-vessel override path
   (`/usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu/libvulkan.so.1`) or the x86 provider's
   `/run/gfx/main/usr/lib64/libvulkan.so.1*`, and check what FEX_APP_CONFIG (/tmp/fex-app-config-*.json in the
   container) sets for thunks.
2. Or our x86_64 Turnip (the same eb3e7fd4 + 0001-0003, cross-built) installed into the FEX RootFS over Fedora's
   (a package owning those files, so the RootFS fetcher / protect hook can't silently swap it back).
Or move Broforce to `powos-steam-compat set 274190 arm64` (native Wine, aarch64 winevulkan -> our driver) - a
per-game workaround; x86-Proton games still need 1 or 2.
Check: `queue.sh add <task> tools/phone/verify/bf-driver.sh` - PASS needs the game's map inode = the package's.

## ARM64 A/B + FEX Vulkan thunk (fex-vulkan-thunk, 2026-11-04)
- **A/B, Proton ARM64 (native Wine + our Turnip):** `bf-coldstart.sh cfg:arm64 keep cold` (window 43.5 s, first frame
  52.9 s), bf-driver.sh: Broforce_beta.exe/explorer/xalia (exe = wine-preloader aarch64) map
  `/run/host/usr/lib/libvulkan_freedreno.so` inode 414382 = OUR package; **CP AHB bus errors 0 in 20 s** (x86 runs:
  40/20 s = the ratelimit cap). bf-checker base: **X 7.87% / S 1.03%** (x86: 6.82-7.44%, same day 7.95%). So the AHB
  errors were FEX RootFS's unpatched x86 Turnip 26.2.0 (0001's RB_CCU_CNTL fix works once the game runs ours), but
  **the black checker is not the game's Turnip**: same % on our patched native driver. Restored to the user's
  pinned x86 (not clearly better on the checker; the arm64 prefix stays as compatdata/274190.powos-arm64).
- **Why x86 games never got the thunk (two causes):**
  1. Steam's client sets `STEAM_COMPAT_FEX_CONFIG` itself per game (its own FEX setting: empty), over /usr/bin/steam's
     export - fex-compat-tool's printenv log `/tmp/fex-compat-tool-<pid>.log` shows `STEAM_COMPAT_FEX_CONFIG=` while
     the client's own environ has `...ThunksDB_Vulkan:1`; so the generated FEX_APP_CONFIG had an empty ThunksDB.
     Fix: steam-env `FEX_THUNKCONFIG=/usr/lib/powos-steam/fex-thunks.json` (FEX option from the environment; FEX maps
     it to /run/host/... in pressure-vessel). Alone it did NOT help (16:01 run: env present, inode 270485, AHB 40).
  2. Valve's FEX-2607 builds overlay paths from `@PREFIX_LIB@` with a multiarch test on its RootFS, which is empty in
     the container -> Fedora layout (`/usr/lib/pressure-vessel/overrides/lib64/...`), while pressure-vessel's x86_64
     loader is `/usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu/libvulkan.so.1`. FEX-2610 adds those prefixes
     under FEX_STEAM_SUPPORT (diff of FileManagement.cpp 37265b10 vs FEX-2610). Fix: our ThunksDB.json with the
     container paths, in each compatdata/<id>/fex-emu/ (FEX's user config dir = FEX_APP_CONFIG_LOCATION), written by
     /usr/bin/steam at start (steam 1.0.0.87-31).
