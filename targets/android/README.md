# PowOS on Android

PowOS's KDE Plasma desktop and the PowOS layer (CLI, widgets, configs, AI agents) running **as an Android
app**: no root, no bootloader unlock, no proot. Android keeps the kernel and the hardware; a real Arch
Linux ARM system runs on top with the phone's GPU.

**Status: experimental, runs on a Samsung Galaxy S25 Ultra** (Android 16 / One UI 8.0, Snapdragon 8 Elite,
Adreno 830; locked bootloader, no root) since 2026-10-13: KDE Plasma with the PowOS layer, on the GPU, through
the stock Andromarchy app. Nothing here touches the desktop or Steam Deck image: this directory is purely
additive.

## How it works

It reuses [Andromarchy](https://github.com/lotfibennour/andromarchy) (GPL-3.0), which runs Omarchy
(Arch + Hyprland) the same way, and swaps its desktop:

| Part | From | PowOS changes |
|---|---|---|
| Android app (display, touch, keyboard, audio, rootfs install) | Andromarchy's APK, unmodified | none yet (see Hacks) |
| No-root runtime (patched glibc loader, fakechroot, fakeroot over TCP, seccomp trap, shims) | Andromarchy's engine | none |
| GPU: Mesa on KGSL (Adreno without `/dev/dri`) | lfdevs/mesa-for-android-container, via Andromarchy | none |
| Compositor | Hyprland on Andromarchy's aquamarine backend | **KWin with lfdevs's Anland backend** ([pkgs/kwin](pkgs/kwin)), ported from KWin 6.6.6 to Arch's 6.7.5: two lfdevs patches rebased, plus our patch 0008 for 6.7's new RenderDevice API. KWin renders EGL-only on the phone (no Vulkan: there's no DRM node to match a Vulkan device to) |
| Desktop | Omarchy | **KDE Plasma + the PowOS layer** ([install-powos-android.sh](install-powos-android.sh)) |
| On-screen keyboard | Squeekboard (Omarchy plugin) | **Android's own keyboard** (the app's IME path into KWin's Anland backend); Squeekboard isn't built |

**What PowOS is comes from PowOS itself.** The phone is the PowOS Steam Deck flavour minus its hardware:
after `build-test-publish` publishes `ghcr.io/powback/powos:deck`,
[phone-manifest.yml](../../.github/workflows/phone-manifest.yml) reads that image on the CI runner and
publishes a few MB as `ghcr.io/powback/powos-phone:deck` ([tools/emit-manifest.sh](tools/emit-manifest.sh)):
the image's top-level packages, its Flatpak list, and the architecture-independent files no package owns
(PowOS's layer, Bazzite's own files, Deck presets). The phone build fetches that
([tools/fetch-manifest.sh](tools/fetch-manifest.sh)), installs the packages' Arch Linux ARM equivalents and
unpacks the files. The only hand-written part is [phone-rules.conf](phone-rules.conf): Fedora→Arch name
differences and what can't exist on a phone (kernels, firmware, drivers, Deck hardware, systemd units). Each
build writes `/usr/share/powos/phone-report.txt`: what every PowOS package became, MISSING ones first.

On the phone, `/etc/powos/platform` reads `phone` (and the session exports `POWOS_PLATFORM=phone`), so
PowOS can tell where it runs. Commands that need a booted machine (bootc, rollback, ramboot, drivers,
distrobox/podman) can't work inside an app on any distro.

## Windows games (Proton) and Steam

**Status: verified in the lab and in phone-sim (the rootfs run exactly as the app runs it), not yet on the phone**
(2026-10-13; numbers, the walls found and the zero-copy analysis in [docs/windows-games.md](docs/windows-games.md)).
`powos-play` runs a Windows program through Proton **without Steam's container runtime** (pressure-vessel needs
user namespaces, which Android denies to apps); `powos-steam` runs **Valve's native ARM64 Steam client**:

```bash
powos-play --install-proton          # GE-Proton's aarch64 build (~600 MB download, ~2.1 GB), once
powos-play ~/Games/Foo/Foo.exe       # x86_64/i686 .exe: ARM64 Wine + FEX ARM64EC/WoW64, DXVK -> Turnip
powos-play --hud --log Foo.exe       # DXVK HUD + MangoHud CSV + Proton log in ~/.local/state/powos/play
powos-play --wayland Foo.exe         # Wine's Wayland driver (the zero-copy route) instead of Xwayland
powos-play --proton x86_64 Foo.exe   # fallback: x86_64 Proton with all of Wine under box64 (no 32-bit DXVK)
powos-steam                          # Steam (ARM64 client; first run ~110 MB + its own ~650 MB update)
powos-play --register-steam          # Proton for Steam games: compat tool "PowOS-GE-Proton..." without the runtime
```

Default is GE-Proton's **aarch64** build: Wine, DXVK and the Windows DLLs are native ARM64; only the game's own
x86 code is emulated, by FEX inside Wine. D3D9/D3D11 tests pass for x86_64, i686 and arm64 programs in both places;
~15% faster than all-box64 Proton in the lab, half the start time; under box64, 32-bit programs get no Vulkan
(BOX32 cannot load libvulkan), so no DXVK. Steam's client starts and connects in phone-sim; its web helper (the UI)
is still open there. Phone test: [tools/device-test.sh](tools/device-test.sh) (adb: probe, GPU/zero-copy checks,
the render tests, benchmarks, `--steam`, any `--exe`). Lab: [tools/lab/phone-sim.sh](tools/lab/phone-sim.sh).

### On the phone (once adb is reachable)

```bash
targets/android/tools/device-test.sh pair <host:port> <code>   # Wireless debugging > Pair with pairing code
targets/android/tools/device-test.sh connect <host:port>
targets/android/tools/device-test.sh push-rootfs               # then the app's first-launch form on the phone
targets/android/tools/device-test.sh wait-session
targets/android/tools/device-test.sh test --steam [--box64] [--exe <url>]
```

## Requirements

- Android 11+ with a Qualcomm **Adreno** GPU (Snapdragon). Target device: OnePlus Open (Adreno 740).
- About 15 GB free; the developer option "Disable child process restrictions" (Andromarchy's requirement).
- To build: an aarch64 Docker host. On this Mac Studio that's Colima, natively, no emulation.

## Build

```bash
targets/android/build-pkgs.sh         # our KWin (Anland backend) -> out/pkgs/   (~20-40 min)
targets/android/build-rootfs.sh       # rootfs -> out/powos-rootfs.tar.gz         (~1-2 h, mostly Mesa)
```

Both run in containers capped at 8 CPUs / 16 GB, because the Colima VM also serves the live PowStation
services. The rootfs is assembled on a Docker volume, not a macOS folder (Linux ownership, devices, links); when
the shared Docker disk has under 25 GB free (or with `POWOS_SCRATCH=image`), in a sparse ext4 image under
`out/work/` on the Mac's disk instead, loop-mounted in the build container.

## Install on a phone (test path)

1. Install the stock Andromarchy APK from its GitHub releases. Don't open it yet.
2. Push the rootfs where its installer looks for an offline copy:
   ```bash
   adb push targets/android/out/powos-rootfs.tar.gz \
     /sdcard/Android/data/andro.marchy/files/lotfix-rootfs.tar.gz
   ```
   (Open the app once first if `Android/data/andro.marchy` doesn't exist yet, then back out at the form.)
3. Open the app and go through the first-launch form. It installs our rootfs instead of downloading Omarchy.

## Hacks (and why)

Every workaround is marked `HACK:` at the spot in the code. Summary:

| Hack | Why | Real fix |
|---|---|---|
| Session launcher installed as `/usr/bin/Hyprland` ([session/Hyprland](session/Hyprland)) | Andromarchy's app hardcodes `exec /usr/bin/Hyprland` | App reads the session command from the rootfs (upstream PR or our own app) |
| Launcher touches `$XDG_RUNTIME_DIR/desktop-ready` itself | The app ends its splash only on seeing Omarchy's `quickshell` (2-min timeout otherwise) | App waits for the file alone |
| `first-boot.sh` at `/opt/lotfix/`, rootfs named `lotfix-rootfs.tar.gz` | The paths the app calls / looks for | Our own PowOS-branded app |
| `omarchy-dns`, `omarchy-toggle-idle`, `omarchy-lock-screen` ([shims](shims)) | Andromarchy's engine calls these Omarchy names | Neutral command names in the engine |
| `omarchy-lock-screen` does nothing | KDE's locker needs a PAM password the app user doesn't have (would lock you out); Android's lock screen protects the phone | Hand-off to Android's keyguard via the two-way bridge |
| Our KWin is `pkgname=kwin`, `pkgrel=3.1`, held with `IgnorePkg` | Satisfies every Plasma package's `depends=(kwin)` and keeps Arch's (which can't draw on Android) out | Anland backend upstream in KWin |
| `DisableSandbox` in pacman.conf of build containers | pacman 7's Landlock sandbox isn't permitted in Docker (Andromarchy's rootfs does the same on-device) | A container runtime that allows Landlock |
| `powos-play` runs Proton without the Steam Linux Runtime; `--register-steam` writes a compat tool whose manifest drops `require_tool_appid` ([play/powos-play](play/powos-play)) | pressure-vessel needs bubblewrap and user namespaces; Android gives an app neither | none on Android: the rootfs itself is the runtime |
| `powos-play` renames Proton's `wine-preloader` to `*.powos-disabled` | the static preloader opens Wine's loader with raw syscalls, outside fakechroot ("could not open"), for every Wine process | a preloader that resolves paths like fakechroot (or a real chroot) |
| box64 built with `box64-real-dl-functions.patch` ([recipes/box64.sh](recipes/box64.sh)) | box64's exported dlopen/dlsym hooks recursed through fakechroot (segfault before main) and bypassed fakechroot's dlopen (Vulkan ICD not found) | upstream box64 |
| `powos-steam`/`powos-play` add `$FAKECHROOT_BASE`-prefixed `LD_LIBRARY_PATH` entries | the dynamic loader is not fakechroot-aware: rootfs paths in LD_LIBRARY_PATH are ignored | fakechroot translating LD_LIBRARY_PATH on exec |
| Andromarchy patch 0004: SysV + named semaphores emulated in files, `get_robust_list(0)` answered in userspace, `nsroot.so` first in every `dlmopen` namespace | Android kills SysV IPC; glibc's sem_open needs /dev/shm; `set_robust_list` is neutralized; preloads don't reach dlmopen namespaces - all hit by Steam | upstream Andromarchy (or kernel-level fixes that aren't available to an app) |
| Session start removes `/tmp/.sysv` and `/tmp/.shm/sem.*` ([session/Hyprland](session/Hyprland)) | emulated semaphores outlive their processes (the kernel would drop them on reboot) | same as above |
| `gtk2` built from AUR (recipes.list) | Valve's ARM64 `steamui.so` links GTK 2, which Arch dropped | Steam without GTK 2 |
| `powos-play` sets `PROTON_NO_FSYNC=1` unless `POWOS_PLAY_FSYNC=1` | fsync's `futex_waitv` may be killed by Android's app seccomp filter; esync (eventfd) is safe | drop it once `powos-probe` shows `futex_waitv` allowed on the device |
| `powos-devtest-agent` in the session ([session/powos-devtest-agent](session/powos-devtest-agent)): runs scripts sent over `adb forward localabstract:powos-devtest`, only for peers with uid 2000/0 | the stock app has no command entry point and isn't debuggable (no `run-as`), so adb can't reach into the rootfs | the PowOS app's own adb-reachable command service |
| `setcap ... \|\| true` in the kwin PKGBUILD | The build container's filesystem may lack xattrs; the capability is irrelevant on Android | Build where xattrs work |

## Verified on device (S25 Ultra)

- KWin 6.7.5 + ported Anland patches draws through Andromarchy's display daemon and takes touch input.
- KWin 6.7's new GpuManager crashed without a udev monitor (apps can't open udev's netlink socket);
  fixed in patch 0008. Found with an LD_PRELOAD crash reporter.
- Plasma session comes up from the app's own session start; output scale set from the physical size
  (2.75x on the S25).
- The desktop's apps installed with pacman inside the running rootfs (now derived from the PowOS Deck image).

## Not done yet

- **Audio** through KWin's Anland audio path: not checked yet.
- **Proton and Steam on the device** (verified in phone-sim; Steam's web helper still open):
  `tools/device-test.sh test --steam` once the phone is reachable over adb.
- ARM gaps (`provide`/MISSING in the phone report): later, by the user.
- **powos CLI gating** on `/etc/powos/platform` (commands that can't work on a phone should say so).
- **PowOS-branded app** (`com.powos.app`) with its own download URL, removing the path hacks above.
- **Two-way Android bridge**: calendar, contacts, notifications to `powos android ...` and a local
  CalDAV source for KDE. Andromarchy's `android-request` is one-way today.
- **Omalauncher's home screen and widgets** (MIT) for the Android side.
