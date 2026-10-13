# Windows games on the phone (Proton without Steam's runtime)

Status: 2026-10-13. Verified in two places, **not yet on the S25 Ultra**:
- **lab**: a plain aarch64 Arch container (Apple M4 Max under Colima), lavapipe for Vulkan, Xvfb;
- **phone-sim** ([tools/lab/phone-sim.sh](../tools/lab/phone-sim.sh)): the built rootfs run the way the Andromarchy
  app runs it - a musl host (no glibc outside the rootfs, like Android), the rootfs at the app's own path,
  entered only through `lotfix-run` (the app's launcher: patched glibc loader + fakechroot + android-compat.so),
  an app-like uid, no capabilities, no user namespaces. Not simulated: KGSL (lavapipe/llvmpipe instead), Android's
  seccomp filter (the probe in [tools/device-test.sh](../tools/device-test.sh) covers it), KWin/Xwayland (Xvfb).

## The path

```
game.exe (x86_64 or i686)
  └ powos-play  ─ no Steam Linux Runtime / pressure-vessel / bwrap (Android gives apps no user namespaces)
     └ GE-Proton aarch64 build's own "proton" script (prefix, DLL overrides, DXVK/VKD3D-Proton)
        └ ARM64 Wine (native: its Linux side goes through glibc, so through fakechroot like every program)
           ├ x86_64 code: FEX as an ARM64EC DLL inside the process (libarm64ecfex.dll)
           ├ i686 code:   FEX as the WoW64 CPU DLL (libwow64fex.dll)
           └ DXVK / VKD3D-Proton built for ARM64 -> winevulkan -> Mesa Turnip (KGSL)
```

GE-Proton ships an `-aarch64` build since GE-Proton11 (the design of Valve's Proton 11 ARM64 for the Steam Frame).
This is the Hangover model: only the game's own x86 code is emulated; Wine, DXVK and the Windows DLLs are native.
Fallback: GE-Proton's x86_64 build with all of Wine under box64 (`powos-play --proton x86_64`), handed to box64 by
the engine's exec hook (Andromarchy patch 0002).

## Results (observed)

Render tests ([tools/wintest](../tools/wintest): a triangle for N frames, centre pixel read back, PASS only on the
right colour), DXVK 3.1 on lavapipe:

| Proton build | x86_64 d3d11 | x86_64 d3d9 | i686 d3d11 | i686 d3d9 | arm64 d3d11 / d3d9 |
|---|---|---|---|---|---|
| aarch64 (FEX ARM64EC / WoW64), lab | PASS | PASS | PASS | PASS | PASS / PASS |
| aarch64, **phone-sim** (with the preloader fix below) | PASS | PASS | PASS | PASS | PASS / PASS |
| x86_64 under box64 0.4.4, lab | PASS | PASS | FAIL: no Vulkan | FAIL (crash) | - |
| x86_64 under box64, **phone-sim** (with the box64 patch below) | PASS | PASS | FAIL | FAIL | - |

32-bit under box64: Wine's 32-bit Unix side runs under BOX32, which cannot load `libvulkan.so.1`
(`DxvkInstance: Failed to create Vulkan instance`), so 32-bit games get no DXVK there. The aarch64 build has no
32-bit Unix side and passes.

cpubench ([tools/wintest/cpubench.c](../tools/wintest/cpubench.c); ms, lower is better). Lab core = Apple M4 Max;
the phone's gaps will be larger, the ratios are what matter:

| path | startup via proton (s) | sieve | matmul | memcpy | 200k Win32 calls | kernel objects | 4 threads | total |
|---|---|---|---|---|---|---|---|---|
| arm64 exe, aarch64 Proton (no emulation) | 2.25 | 201 | 146 | 107 | 4.2 | 264 | 81 | 802 |
| x86_64 exe, aarch64 Proton (FEX ARM64EC) | 2.30 | 204 | 145 | 85 | 36.1 | 301 | 81 | 853 |
| x86_64 exe, x86_64 Proton (box64) | 4.35 | 212 | 189 | 197 | 6.7 | 296 | 107 | 1007 |
| i686 exe, aarch64 Proton (FEX WoW64) | 2.27 | 187 | 139 | 58 | 8.7 | 308 | 97 | 798 |
| i686 exe, x86_64 Proton (BOX32) | 4.72 | 222 | 198 | 92 | 8.6 | 305 | 138 | 962 |
| x86_64 exe, Hangover 11.16 (FEX ARM64EC) | 0.05 (wine only) | 218 | 162 | 87 | 42.7 | 327 | 84 | 920 |
| i686 exe, Hangover (box64 wowbox64.dll) | 0.07-0.12 (wine only) | 232 | 197 | 84 | 11.5 | 323 | 136 | 985 |
| i686 exe, Hangover (FEX libwow64fex.dll) | 0.07 (wine only) | 201 | 162 | 95 | 11.9 | 292 | 100 | 861 |

In phone-sim (same machine, the runtime's loader/fakechroot in every call): arm64 766, ARM64EC 856, WoW64 818,
box64 836 ms total; startup 2.0-2.2 s (aarch64) vs 4.0 s (box64); BOX32 failed.

Derived:
- ARM64 Proton: ~15% faster than full box64 on this mix in the lab, half the start time, and the only path with
  32-bit DXVK. The runtime itself costs little CPU (phone-sim totals within noise of the lab).
- ARM64EC's cost is the x64 -> ARM64 call boundary: tiny Win32 calls cost ~8x native (box64 avoids it by also
  emulating Wine's DLLs); emulated game code itself is close to native here.
- Hangover = the same technology (FEX ARM64EC + WoW64); its box64-based wowbox64 is slower than FEX WoW64 for
  32-bit code. GE-Proton adds DXVK/VKD3D-Proton, protonfixes and Steam integration, so it is the shipped path. Arch
  Linux ARM has no `wine` at all; Hangover's Debian debs do run in an Arch rootfs.

## Walls found in phone-sim, in the order hit, and their fixes

| # | Wall (observed) | Cause | Fix (where) |
|---|---|---|---|
| 1 | Every Proton launch: `<proton>/lib/wine/aarch64-unix/wine: could not open` | Wine's static `wine-preloader` opens the loader with raw syscalls, outside fakechroot; ntdll also execs it for every child process | `powos-play` disables the preloader in the Proton dist (Wine falls back to its loader) |
| 2 | `box64 --version` segfaults | box64 exports dlopen/dlsym hooks; finding the real ones walked `dl_iterate_phdr`, which fakechroot wraps through dlsym: unbounded recursion | `recipes/box64.sh` + `box64-real-dl-functions.patch` |
| 3 | box64 Wine: `vkCreateInstance: Found no drivers` | box64's dlopen hook reached libc past fakechroot: the Vulkan loader's ICD path was not rewritten | same patch: resolved from box64 itself so RTLD_NEXT reaches fakechroot's dlopen |
| 4 | (lab) x86 Steam under box64 spins at 100% CPU after self-update, no web helper | not chased: Valve's native ARM64 client exists | `powos-steam` (native linuxarm64 client) |
| 5 | Steam: `steamui.so ... libgtk-x11-2.0.so.0` | Arch dropped gtk2 | `gtk2` built from AUR (recipes.list) |
| 6 | Steam: `semaphore creation failed`, `Function not implemented` | glibc's sem_open uses /dev/shm internally; SysV semaphores are killed by Android's seccomp | Andromarchy patch 0004: emulated in the rootfs |
| 7 | Steam: `undefined symbol: SDL_TryLockJoysticks` | the dynamic loader is not fakechroot-aware: rootfs paths in LD_LIBRARY_PATH are ignored | `powos-steam`/`powos-play` add `$FAKECHROOT_BASE`-prefixed paths |
| 8 | Steam UI library cannot see the rootfs | glibc loads LD_PRELOAD only into the base namespace; Steam dlmopen's steamui.so | patch 0004: `nsroot.so` loaded first into each new namespace |
| 9 | Steam: `pthreads futex robust_list is corrupt` (deliberate crash) | `set_robust_list` neutralized, so `get_robust_list` returns NULL; Steam walks glibc's list | patch 0004: get_robust_list(0) answered from glibc's own list head |
| 10 | Steam web helper: `Stalled cross-thread pipe`, UI never drawn (phone-sim) | open: llvmpipe + Xvfb without the phone's GPU/Xwayland; process argv shows mangled in /proc | device test `--steam` |

With 1-9 fixed, Steam's client starts, self-updates, and reports `Connectivity test: result=Connected` in phone-sim.

## Without the Steam runtime

Proton's `toolmanifest.vdf` names a Steam Linux Runtime (`require_tool_appid`), which Steam starts through
pressure-vessel -> bubblewrap -> user namespaces. `powos-play` instead runs `<dist>/proton run <exe>` itself in
umu's non-Steam mode (`UMU_ID`; Proton needs `STEAM_COMPAT_DATA_PATH`, `STEAM_COMPAT_CLIENT_INSTALL_PATH`,
`SteamGameId`), and `--register-steam` writes a compatibility tool without `require_tool_appid`. Valve's ARM64
Steam client starts its web helper directly (`steamrtarm64/steamwebhelper.sh`, no sniper container), so Steam
itself needs no runtime either. Proton's Python starts Wine with `posix_spawn` (Python 3.14); the engine's
android-compat.c reimplements posix_spawn over its exec hook (the lab shim tools/lab/x86exec.c does the same).

## Zero-copy presentation

What exists (KWin Anland, ours): KWin renders the desktop **into gralloc dma-bufs provided by the display daemon**
(imported as EGLImages on KGSL): no CPU copy from KWin to Android. `MESA_VK_WSI_DEBUG=sw` (render, read back to
`wl_shm`) belongs to the Omalauncher/Mali model, not this path.

What decides whether a game's Vulkan frames reach KWin without a CPU copy (from the pinned lfdevs Mesa source:
`src/freedreno/vulkan/tu_knl_kgsl.cc`, `tu_wsi.cc`, `src/vulkan/wsi/wsi_common_wayland.c`; our KWin patch 0002):

1. KWin advertises `zwp_linux_dmabuf_v1` without a DRM device (`dev_t 0` in its feedback tranches, patch 0002).
2. Mesa's Wayland WSI: with no DRM render node, `same_gpu` stays true; per-surface feedback with `main_device == 0`
   is ignored and the display's format table is used. Turnip's KGSL WSI is not a software device and
   `can_present_on_device` returns true for KGSL, so swapchains take the **dma-buf path**.
3. Swapchain images must be exportable: Turnip allocates shareable BOs from `/dev/dma_heap/system` (or legacy
   `/dev/ion`) and imports them into KGSL (`IOCTL_KGSL_GPUOBJ_IMPORT`). If the app cannot open the heap, export
   fails (`no dma-heap or ION fd available for shareable KGSL BO`) and swapchain creation fails with no automatic
   fallback; then only `MESA_VK_WSI_DEBUG=sw` works (CPU copy).
4. KWin imports the client dma-buf as an EGLImage on freedreno/KGSL and composites it into the daemon's buffer.

For Wine: `powos-play --wayland` (`PROTON_ENABLE_WAYLAND`, winewayland) is the direct route. The default X11 route
goes through Xwayland: Mesa's X11 WSI uses DRI3 when Xwayland offers it (the lfdevs Mesa hands the KGSL control fd
to DRI3 clients, `XWAYLAND_FORCE_KGSL_SURFACELESS`), otherwise `xcb_put_image`/MIT-SHM, a CPU copy.

Verifiable only on the device (all in device-test.sh): the probe's `/dev/dma_heap/system` open + 1 MiB alloc;
`wayland-info` linux-dmabuf; vkcube's protocol log (`zwp_linux_buffer_params_v1` = dma-buf vs `wl_shm_pool` =
copy) and fps with and without `MESA_VK_WSI_DEBUG=sw`; `xdpyinfo` DRI3; DXVK HUD fps on X11 vs `--wayland`. If the
heap is closed to apps, the zero-copy design is: the Android side allocates the swapchain buffers as
AHardwareBuffers (the daemon already does this for KWin's output), passes them as dma-buf fds
(`AHardwareBuffer_sendHandleToUnixSocket` is public NDK), and a Turnip WSI imports them
(`VK_EXT_external_memory_dma_buf` import exists in the KGSL backend).

## Open, in the order the phone will hit them (inferred)

1. **Android's app seccomp filter** on what Wine/Proton/Steam call directly: `futex_waitv` (fsync; `powos-play`
   defaults to esync until the probe says otherwise), `userfaultfd`, `clone3`, `get_robust_list` (now answered in
   userspace). powos-probe reports each as ALLOWED or KILLED.
2. **Storage**: the rootfs is 6.8 GB compressed (FEX's x86 rootfs 2.7 GB and Bazzite's preloaded Steam bootstrap
   1.4 GB are the largest single items); GE-Proton aarch64 adds ~2.1 GB; Steam ~3 GB.
3. **dma-buf heap access** (above): zero-copy vs CPU copy.
4. **Steam's web helper** on the real GPU/Xwayland (wall 10).
