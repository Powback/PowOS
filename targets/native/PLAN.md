# OnePlus Open — plan

Device: OnePlus Open (`xueying`), CPH2551 **EEA**, serial `8e5d600d`, Snapdragon 8 Gen 2 (`kalama`), Adreno 740.
Firmware: OxygenOS **16.0.5.1301 (EX01)**, Android 16, security patch 2026-09-01, GKI kernel 5.15.197-android13-8.
Active slot: **b**.

## Decision (2026-10-16)
Root first, keep stock OxygenOS as the daily OS, add PowOS pieces on top later. The native-boot kit (PowOS booting on
its own in the other slot) is parked, not deleted — see the end.

## Done (how, step by step and every snag: [ROOTING.md](ROOTING.md))
| step | result |
|---|---|
| Bootloader unlock | unlocked (verified boot `orange`). Note: the confirmation prompt shows on the **inner** screen. |
| Stock images | `backup/8e5d600d/stock-16.0.5.1301-EX01/` — boot, init_boot, vendor_boot, vendor_dlkm, vbmeta, dtbo (from CruelKernel/oneplus_kernel_patcher's release of this build; `boot.img` verified byte-identical to the phone's `boot_b`) |
| Root | Magisk **v30.7** (official, sha256-checked); stock init_boot patched on the phone by Magisk's own script (`tools/magisk-patch.sh`) → flashed to `init_boot_b` |
| Backup | `ALL=1 ./phone.sh backup` → `backup/8e5d600d/`: every partition except `userdata` and the raw LUN nodes, each sha256-checked against the phone. Includes the irreplaceable `persist`, `modemst1`, `modemst2`, `fsg`. |

## Still to do
1. Finish the backup (super last), then verify `vbmeta`/`vendor_boot` against the downloaded stock images.
2. Copy `backup/8e5d600d/` off this Mac (NAS or external drive) — the Mac is nearly full, and a backup on one
   machine is not a backup.

## Rules for the phone from now on
- **Never install or flash anything older than 16.0.5.1301.** (Anti-rollback index on the Open's EU builds is 0 so far
  — Bartixxx32/OnePlus-antirollchecker — but newer OnePlus models brick on downgrade; don't test it.)
- **Automatic system updates off.** An OTA replaces init_boot (root gone). To update: take the OTA, then Magisk →
  Install → "Install to inactive slot (after OTA)" before rebooting.
- **Never back up / restore `userdata` raw**: it is encrypted with keys in the phone's TEE (lost on wipe/relock).
  User data goes through Android backups (Google/OnePlus, or Swift Backup with root).
- Undo root: `fastboot flash init_boot_b backup/8e5d600d/stock-16.0.5.1301-EX01/init_boot.img`.

## Base distros (decided 2026-10-16, revisit later)
Arch Linux ARM on phones (rooted + app), Bazzite (Fedora) on x86 PCs / laptop / Steam Deck. Discussed and deferred:
moving phones to Fedora aarch64 (one ecosystem) or everything to a lean Universal Blue Fedora Atomic base (Bazzite is
bloated). The PowOS layer (CLI, configs, desktop, agents) stays one source, platform-aware via /etc/powos/platform.

## Rooted mode and the no-root app: both supported
The no-root PowOS app (targets/android, e.g. the S25 Ultra) stays a first-class target. Rooted mode is an extra:
- ONE rootfs (`targets/android/out/powos-rootfs.tar.gz`) for both — the app runs it through the no-root engine,
  the rooted phone as a real chroot (`targets/android/rooted/`). Rooted-only bits never go into the rootfs;
  rootfs changes must keep the app working.
- ONE app, two modes (step 2): the PowOS app detects root → real chroot + direct GPU; no root → today's engine.
  Same APK, same PowApps updates.

## Next: PowOS on top (pick one at a time)
Easiest first:
1. PowOS CLI + configs and native Linux tools (root shell).
2. Full Arch Linux ARM environment with GPU (Mesa Turnip on KGSL) — real Linux desktop apps; FEX for x86 Steam/Proton.
3. The PowOS/KDE desktop as a full-screen session.
4. Android customization: launcher, theming, Magisk modules.

### Performance expectations (honest)
- PowOS and Linux apps: native (ARM64 binaries on the real CPU/GPU).
- PC games: GPU work near-native (Turnip + DXVK/VKD3D); CPU work translated x86→ARM (FEX/box64) — fine for older and
  mid-range games, the limit for CPU-heavy AAA. Kernel anti-cheat games: no.
- Upgrade path for favourite games: per-game static recompilation (EasyReverse, as done for Enter the Matrix) →
  native ARM64, no translation.
- Firmware blobs (modem, DSP, GPU microcode) are used as-is; reverse-engineering them gains nothing.

## Parked: native PowOS boot (dual-boot)
PowOS booting on its own (Android not running), from the other A/B slot, on OnePlus's own GKI kernel:
- `build-gki-kernel.sh` — OnePlusOSS android13-5.15 (b_16 branch, 5.15.180) + `config/gki/powos.config` (FHANDLE,
  DEVTMPFS, AUTOFS — KMI-safe only), Google's Clang r450784e. Phone runs 5.15.197: if `tools/kmi-check.py` against
  the phone's vendor_dlkm reports mismatches, build from Google's matching android13-5.15 source instead.
- `initramfs-native/` + `build-initramfs.sh` — loads first-stage vendor modules, mounts the `powos` partition,
  starts systemd; USB rescue shell on failure.
- Open questions: KWin on the downstream SDE display driver + Turnip/KGSL (untested anywhere), both panels, audio/
  Wi-Fi without Android daemons; slot B firmware must be copied from slot A first; Linux must mark boots successful.
- Mainline port (`build-kernel.sh`, `dts/`): long-term only.
