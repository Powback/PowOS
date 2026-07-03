# One USB, many machines: GPU variant auto-select at boot

Goal: a single x86-64 PowOS USB that boots cleanly on an NVIDIA desktop, an
AMD box, and a Steam Deck — auto-detecting the GPU at boot, or letting you pick
from the boot menu. (Scope is x86-64 only: desktops/laptops + Steam Deck + Intel
Macs. ARM targets — Apple Silicon, Android — are out; their firmware won't even
load the USB, so it can't be a menu choice.)

## The idea

The GPU driver stack is fixed by the base image (NVIDIA proprietary vs. mesa/open).
So the USB carries **more than one base variant** and we choose at boot:

```
USB (x86-64)
├── EFI                       one bootloader, offers: auto / NVIDIA-open / NVIDIA-closed / AMD-Intel
├── layers/
│   ├── base-nvidia-open/     NVIDIA open kernel modules (DEFAULT for NVIDIA)
│   ├── base-nvidia/          NVIDIA proprietary/closed (older Maxwell/Pascal)
│   ├── base-main/            mesa/open drivers (AMD, Intel, Deck, fallback)
│   ├── custom/  updates/     your persistent layers (shared across variants)
└── ...

boot → detect GPU → mount base-<variant> as the overlay base → run
```

- **Auto:** detect the GPU (`detect_gpu` from Chameleon Boot) → NVIDIA card picks
  `base-nvidia-open` (open drivers, the default), everything else picks `base-main`.
- **Manual:** the boot menu passes `rd.powos.variant=nvidia-open|nvidia|main|auto`.
  Pick `nvidia` for the closed proprietary driver (older cards, or if the open
  modules misbehave on your GPU).
- **Install inherits the choice:** `powos install-system` installs the variant you
  BOOTED (bootc installs the running image), so selecting the driver at the live
  boot menu carries through to the installed system.
- **Fallback:** if the detected variant isn't on the USB, fall back to `main`
  (mesa/open drivers run on any GPU).

**Open vs closed:** open kernel modules are the default — recommended for Turing
(GTX 16-series) and newer, required for RTX 50-series. Older NVIDIA (Maxwell/Pascal,
GTX 900/1000) need the closed `nvidia` variant.

## Status — what's built vs. what's next

**✅ Built + unit-tested (`lib/boot/variant-select.sh`, 16 tests):**
- `variant_from_gpu` — GPU → variant mapping (nvidia* → nvidia, else → main).
- `variant_select` — full precedence: manual override → GPU auto-detect →
  fallback to main → first available. Pure, unit-tested.
- `variant_cmdline_override` — parse `rd.powos.variant=` from the kernel cmdline.
- `variant_list_available` — discover `base-*/` variants present on the USB.
- `variant_select_main` — wire the above to real GPU/cmdline/USB inputs.

**🧩 Wired (code-complete, NOT hardware-validated — `TODO(hw)`):**
1. **Build multiple variants.** `./build/build-iso.sh variants` builds a base
   rootfs per variant (default `nvidia-open main`, override `POWOS_VARIANTS`) into
   `build/output/base-<variant>/`.
2. **USB layout.** `sudo ./build/install-to-usb.sh --variants /dev/sdX` copies each
   `base-<variant>/` onto the USB under `layers/base-<variant>/` (additive — assumes
   a base raw image is already written for kernel/ESP/initramfs).
3. **Dracut boot stage.** `ramboot-setup.sh` selects the base variant (GPU
   auto-detect + `rd.powos.variant=` override) — **guarded**: if no `base-*/` dirs
   exist, it keeps the single NEWROOT base, so existing single-variant USBs are
   unchanged. `module-setup.sh` adds `lspci` to the initramfs for detection.
4. **Boot menu entries.** `--variants` adds BLS entries `PowOS (auto|nvidia-open|
   nvidia|main)` via `rd.powos.variant=`.

**The workflow:**
```bash
./build/build-iso.sh variants                    # build base-nvidia-open/ + base-main/
sudo ./build/install-to-usb.sh /dev/sdX          # write a base image first (kernel/ESP)
sudo ./build/install-to-usb.sh --variants /dev/sdX   # add the variant rootfs + boot entries
```

⚠️ **All of this is boot-critical and unvalidated on hardware.** The selection
engine and single-variant fallback are unit-tested, but the multi-base overlay
assembly, rootfs export, and boot entries must be checked in a VM before trusting
them. Until then, a single-variant USB per machine (`POWOS_BASE_IMAGE`) is the
proven path.
