# PowOS native on phones — OnePlus Open bring-up

PowOS booting its **own mainline kernel** on the OnePlus Open (codename `xueying`, global model CPH2551,
Snapdragon 8 Gen 2 / SM8550), dual-booting with Android. No port of this phone exists anywhere, so this starts as
a bring-up: the first boots give a **USB shell, not a desktop**.

| file | what |
|---|---|
| `build-kernel.sh` | mainline kernel (kernel.org stable, default 7.2.10) + device trees, in Docker → `out/Image.gz`, `out/dtbs/` |
| `config/bringup.config` | built-in drivers for the USB shell (merged over arm64 defconfig) |
| `dts/sm8550-oneplus-xueying.dts` | the phone's device tree — from mainline's Galaxy Z Fold5 (same SoC, also a foldable); USB gadget only, **storage (UFS) disabled** |
| `dts/sm8550-oneplus-xueying-board.dtsi` | per-unit IDs + splash region, written by `phone.sh dump` (placeholders until then) |
| `build-initramfs.sh`, `initramfs/init` | busybox initramfs: USB network (CDC-NCM) + USB serial + telnet root shell |
| `make-bootimg.sh` | `out/boot-bringup.img` (boot header v2, DTB inside) — for `fastboot boot`, never flashed |
| `phone.sh` | `info`, `backup`, `dump`, `boot`, `shell` — **no verb writes to the phone** |

## Two rules that protect the phone

1. **Never downgrade firmware.** OnePlus phones blow anti-rollback eFuses: flashing an older build than the one
   installed can hard-brick the phone. Only ever flash images from the exact build that is on it.
2. **Back up before anything else** (`phone.sh backup`). `persist`, `modemst1`, `modemst2` and `fsg` hold the IMEI
   and modem calibration, are unique to the unit, and can't be downloaded anywhere.

## Day 1

1. **Before setting up Android:** Settings → About device → tap *Build number* 7× → Developer options →
   enable **OEM unlocking** and **USB debugging**. Note the build number (`./phone.sh info`).
2. **Unlock** (wipes the phone, which is why it comes before setup):
   `adb reboot bootloader`, then `fastboot flashing unlock`, confirm on the phone with the volume keys.
3. **Root once, for the backup:** get the full OTA zip of the **exact build installed**, extract `init_boot.img`
   (payload-dumper-go), patch it in the Magisk app, then `fastboot flash init_boot_<current slot> magisk_patched.img`.
   This is the only flash in the whole bring-up, and the stock `init_boot.img` from the same OTA undoes it.
4. `./phone.sh backup` → `backup/<serial>/` (every partition under 1 GiB, sha256-checked against the phone).
   Copy that folder to the NAS too.
5. `./phone.sh dump` → saves the stock device tree and writes the real `qcom,msm-id`/`qcom,board-id`/splash region
   into `dts/sm8550-oneplus-xueying-board.dtsi`.
6. `./build-kernel.sh && ./build-initramfs.sh && ./make-bootimg.sh`
7. `adb reboot bootloader`, `./phone.sh boot` — boots from RAM, nothing written. Wait ~30 s, then
   `./phone.sh shell` (USB serial via `screen`, or telnet to 172.16.42.1). Save `/run/dmesg.txt`.
   Back to Android: hold **power + volume down** until it restarts.

**If the first boot shows nothing on USB:** that is normal for a first bring-up. Things to try, in order:
the bootloader rejected the DTB (check `fastboot boot` output; compare msm-id/board-id with the dump), USB rails
(the regulator table is the Fold5's — see the HACK in the .dts), boot header offsets (compare with the stock
boot.img header: `unpack_bootimg` on `backup/<serial>/boot_<slot>.img`).

## After the shell works

Display (two DSC command-mode panels on dual DSI) → touch → storage (UFS, read-only first) → GPU (Adreno 740,
mainline freedreno/Turnip) → audio (TFA98xx amps) → hinge sensor → modem → PowOS rootfs on a partition or USB-C
SSD with Android kept in its own slot. Downstream source for each: OnePlusOSS `oneplus/sm8550_b_16.0.0_oneplus_open`,
LineageOS `android_device_oneplus_xueying`.

## Tested here (no phone yet)

- Kernel and both device trees build; the USB drivers are confirmed built in (`=y` in the final `.config`).
- The boot image packs and `unpack_bootimg` gives back the same kernel and DTB.
- The initramfs boots on QEMU `virt`: shell up, telnetd running, no hang when there is no USB controller.
- `tools/board-dtsi.py` turns a device-tree dump into the board include (tested on a synthetic dump).
- **Not testable without the phone:** the USB gadget itself, whether the bootloader accepts the image, the DTS.
