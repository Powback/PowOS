# Windows games on the phone (Proton without Steam's runtime)

Status: 2026-10-13. Lab-verified in an aarch64 container (Apple M4 Max under Colima, lavapipe for Vulkan);
**not yet run on the S25 Ultra**. [tools/device-test.sh](../tools/device-test.sh) runs everything below on
the phone and collects the logs.

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

GE-Proton ships an `-aarch64` build since GE-Proton11 (the same design as Valve's Proton 11 ARM64 for the
Steam Frame). This is the "Hangover" model: only the game's own x86 code is emulated; Wine, DXVK and every
Windows system DLL run natively.

The fallback is GE-Proton's x86_64 build with all of Wine under box64 (`powos-play --proton x86_64`): the
engine's exec hook hands every x86 program to box64 (patch 0002).

## Measured in the lab (observed)

Render tests (tools/wintest: a triangle for N frames, the centre pixel read back, PASS only on the right colour),
DXVK 3.1 on lavapipe, Xvfb:

| Proton build | x86_64 d3d11 | x86_64 d3d9 | i686 d3d11 | i686 d3d9 | arm64 d3d11 / d3d9 |
|---|---|---|---|---|---|
| GE-Proton11-7 aarch64 (FEX ARM64EC / WoW64) | PASS 563 fps | PASS 318 fps | PASS 488 fps | PASS 276 fps | PASS 568 / 319 fps |
| GE-Proton11-7 x86_64 under box64 0.4.4 | PASS 364 fps | PASS 282 fps | **FAIL**: no Vulkan | **FAIL** (crash) | - |

The box64 32-bit failure: Wine's 32-bit Unix side runs under BOX32, which cannot load `libvulkan.so.1`
(`err:vulkan:vulkan_init_once Failed to load libvulkan.so.1` -> `DxvkInstance: Failed to create Vulkan
instance`). So under full box64, 32-bit games get no DXVK at all. The aarch64 build has no 32-bit Unix side.

cpubench (tools/wintest/cpubench.c; ms, lower is better; same x86 binary across a column group). Lab CPU is an
Apple M4 Max core; expect larger gaps on the phone, but the ratios are what matter:

| path | startup via proton (s) | sieve | matmul | memcpy | win32 API calls | kernel objects | 4 threads | total |
|---|---|---|---|---|---|---|---|---|
| arm64 exe, aarch64 Proton (no emulation) | 2.25 | 201 | 146 | 107 | 4.2 | 264 | 81 | 802 |
| x86_64 exe, aarch64 Proton (FEX ARM64EC) | 2.30 | 204 | 145 | 85 | 36.1 | 301 | 81 | 853 |
| x86_64 exe, x86_64 Proton (box64) | 4.35 | 212 | 189 | 197 | 6.7 | 296 | 107 | 1007 |
| i686 exe, aarch64 Proton (FEX WoW64) | 2.27 | 187 | 139 | 58 | 8.7 | 308 | 97 | 798 |
| i686 exe, x86_64 Proton (BOX32) | 4.72 | 222 | 198 | 92 | 8.6 | 305 | 138 | 962 |
| x86_64 exe, Hangover 11.16 wine (FEX ARM64EC) | 0.05 (wine only) | 218 | 162 | 87 | 42.7 | 327 | 84 | 920 |
| i686 exe, Hangover (box64 wowbox64.dll) | 0.07-0.12 (wine only) | 232 | 197 | 84 | 11.5 | 323 | 136 | 985 |
| i686 exe, Hangover (FEX libwow64fex.dll) | 0.07 (wine only) | 201 | 162 | 95 | 11.9 | 292 | 100 | 861 |

Derived:
- ARM64 Proton is ~15% faster than full box64 on this mix and starts in half the time (2.3 s vs 4.4 s per launch
  through the proton script; the script itself is ~2.2 s of that, so Wine's own start under box64 is the ~2 s
  difference).
- ARM64EC's one cost is the x64 -> ARM64 call boundary: tiny Win32 API calls cost ~8x native (36 vs 4 ms for
  200k calls), box64 avoids it by emulating Wine's DLLs too. Real games make far fewer, heavier calls; the
  emulated-code win (memcpy 85 vs 197 ms, matmul 145 vs 189) dominates.
- Hangover and GE-Proton aarch64 are the same technology (FEX ARM64EC + WoW64); Hangover's box64-based
  wowbox64 is slower than FEX WoW64 for 32-bit code here. GE-Proton adds DXVK/VKD3D-Proton, protonfixes and the
  Steam integration, so it is the one shipped (downloaded by `powos-play --install-proton`). No Arch Linux ARM
  package exists for either (no `wine` at all in ALARM); Hangover's Debian debs do run in an Arch rootfs.

## Without the Steam runtime

Proton's `toolmanifest.vdf` names a Steam Linux Runtime (`require_tool_appid`), which Steam starts through
pressure-vessel -> bubblewrap -> user namespaces. Android gives apps none (the probe shows
`unshare(CLONE_NEWUSER)` = EPERM in the lab container as on Android). What `powos-play` does instead:

- runs `<dist>/proton run <exe>` itself, in umu's non-Steam mode (`UMU_ID`): Proton's script needs
  `STEAM_COMPAT_DATA_PATH`, `STEAM_COMPAT_CLIENT_INSTALL_PATH` and `SteamGameId` (its log file name), nothing
  from the runtime; the rootfs is a full Arch system with the libraries Wine dlopens;
- `--register-steam` writes a compatibility tool (symlinks into the GE dist) whose manifest has **no**
  `require_tool_appid`, with `powos-proton` as its command: Steam then runs Proton directly.
- Proton's Python script starts Wine with `posix_spawn` (Python 3.14): glibc's posix_spawn would bypass an
  `execve` interposer; the engine's android-compat.c already reimplements posix_spawn over its exec hook, and the
  lab shim (tools/lab/x86exec.c) does the same. Without it, x86_64 Wine never reaches box64.

## Zero-copy presentation (2c)

What exists already (KWin Anland, ours): KWin renders the desktop **into gralloc dma-bufs provided by the
display daemon** (imported as EGLImages on KGSL): no CPU copy from KWin to Android. `MESA_VK_WSI_DEBUG=sw`
(render, read back to `wl_shm`) belongs to the Omalauncher/Mali model, not to this path.

What decides whether a game's Vulkan frames reach KWin without a CPU copy (from the pinned lfdevs Mesa source,
`src/freedreno/vulkan/tu_knl_kgsl.cc`, `tu_wsi.cc`, `src/vulkan/wsi/wsi_common_wayland.c`, and our KWin patch
0002):

1. KWin advertises `zwp_linux_dmabuf_v1` without a DRM device (`dev_t 0` in the feedback tranches, patch 0002).
2. Mesa's Wayland WSI: with no DRM render node in `drm_info`, `same_gpu` stays true; per-surface feedback with
   `main_device == 0` is ignored and the display's format table is used. Turnip's KGSL WSI is not a software
   device and `can_present_on_device` returns true for KGSL: swapchains take the **dma-buf path** (no `sw`).
3. Swapchain images must be exportable: Turnip allocates shareable BOs from `/dev/dma_heap/system` (or legacy
   `/dev/ion`) and imports them into KGSL (`IOCTL_KGSL_GPUOBJ_IMPORT`). **If the app cannot open the heap**, export
   fails (`no dma-heap or ION fd available for shareable KGSL BO`) and swapchain creation fails, with no automatic
   fallback: then `MESA_VK_WSI_DEBUG=sw` is the only way (CPU copy).
4. KWin imports the client dma-buf as an EGLImage on freedreno/KGSL and composites it into the daemon's buffer
   (GPU blit, no CPU).

For Wine: `powos-play --wayland` (Proton's `PROTON_ENABLE_WAYLAND`, winewayland) is the direct route above. The
default X11 route goes through Xwayland: Mesa's X11 WSI uses DRI3 when Xwayland offers it (the lfdevs Mesa hands
the KGSL control fd to DRI3 clients, `XWAYLAND_FORCE_KGSL_SURFACELESS`), otherwise it falls back to
`xcb_put_image`/MIT-SHM, which is a CPU copy.

Verifiable only on the device (all in device-test.sh): the probe's `/dev/dma_heap/system` open + 1 MiB alloc;
`wayland-info` showing linux-dmabuf; vkcube's protocol log (`zwp_linux_buffer_params_v1` = dma-buf vs
`wl_shm_pool` = copy) and its fps with and without `MESA_VK_WSI_DEBUG=sw`; `xdpyinfo` DRI3; DXVK HUD fps of the
test programs on X11 vs `--wayland`. If the heap is closed to apps, the zero-copy design is: allocate the
swapchain's buffers on the Android side as AHardwareBuffers (the daemon already does this for KWin's output),
pass them as dma-buf fds (`AHardwareBuffer_sendHandleToUnixSocket` is public NDK), and give Turnip a WSI that
imports them (`VK_EXT_external_memory_dma_buf` import is supported by the KGSL backend).

## Open walls, in the order the phone will hit them (inferred)

1. **Android's app seccomp filter**: Proton's fsync calls `futex_waitv`; if the filter kills it, every game dies
   at start. `powos-play` defaults to esync (eventfd) until the probe says otherwise (`POWOS_PLAY_FSYNC=1`).
2. **Download/storage**: GE-Proton aarch64 is 615 MB compressed, ~2.1 GB unpacked, per version.
3. **dma-buf heap access** (above): decides zero-copy vs `MESA_VK_WSI_DEBUG=sw`.
4. **Steam**: the client is x86 (box64, BOX32 for the 32-bit bootstrap); its web helper normally runs inside the
   Steam Runtime container (pressure-vessel) - with no namespaces that path has to run uncontained
   (`-no-cef-sandbox`). Not run yet; device-test.sh `--steam` collects the logs.
