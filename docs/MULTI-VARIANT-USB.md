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
├── EFI                       one bootloader, offers: auto / NVIDIA / AMD-Intel
├── layers/
│   ├── base-nvidia/          NVIDIA proprietary + CUDA build
│   ├── base-main/            mesa/open drivers (AMD, Intel, Deck, fallback)
│   ├── custom/  updates/     your persistent layers (shared across variants)
└── ...

boot → detect GPU → mount base-<variant> as the overlay base → run
```

- **Auto:** detect the GPU (`detect_gpu` from Chameleon Boot) → NVIDIA card picks
  `base-nvidia`, everything else picks `base-main` (open drivers boot anywhere).
- **Manual:** the boot menu passes `rd.powos.variant=nvidia|main|auto`.
- **Fallback:** if the detected variant isn't on the USB, fall back to `main`
  (open drivers run on any GPU, just without NVIDIA's proprietary perf/CUDA).

## Status — what's built vs. what's next

**✅ Built + unit-tested (`lib/boot/variant-select.sh`, 16 tests):**
- `variant_from_gpu` — GPU → variant mapping (nvidia* → nvidia, else → main).
- `variant_select` — full precedence: manual override → GPU auto-detect →
  fallback to main → first available. Pure, unit-tested.
- `variant_cmdline_override` — parse `rd.powos.variant=` from the kernel cmdline.
- `variant_list_available` — discover `base-*/` variants present on the USB.
- `variant_select_main` — wire the above to real GPU/cmdline/USB inputs.

**🚧 Not yet wired (needs build + boot-layout work, hardware validation):**
1. **Build multiple variants.** `build-iso.sh` builds one image; it needs to loop
   and produce both (`POWOS_BASE_IMAGE=bazzite-nvidia` and `=bazzite`) — the base
   image is already a build ARG.
2. **USB layout.** `install-to-usb.sh` must place each variant's root under
   `layers/base-<name>/` instead of a single root partition. This is the biggest
   change — today the "base" is the raw image's root, not a selectable layer.
3. **Dracut boot stage.** `ramboot-setup.sh` must call `variant_select_main` and
   use the chosen `base-<variant>` as the overlay `lowerdir` base.
4. **Boot menu entries.** Add BLS entries (like the installer entry) for
   `auto` / `nvidia` / `main` via `rd.powos.variant=`.

The decision engine is done and safe; the remaining work is boot-critical and
must be validated on real hardware / a VM before it can be trusted. Until then,
build a single-variant USB per machine with `POWOS_BASE_IMAGE`.
