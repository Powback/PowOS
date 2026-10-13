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
services. The rootfs is assembled on a Docker volume, not a macOS folder (Linux ownership, devices, links).

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
- **Steam/Proton/FEX** and ARM gaps (`provide`/MISSING in the phone report): later, by the user.
- **powos CLI gating** on `/etc/powos/platform` (commands that can't work on a phone should say so).
- **PowOS-branded app** (`com.powos.app`) with its own download URL, removing the path hacks above.
- **Two-way Android bridge**: calendar, contacts, notifications to `powos android ...` and a local
  CalDAV source for KDE. Andromarchy's `android-request` is one-way today.
- **Omalauncher's home screen and widgets** (MIT) for the Android side.
