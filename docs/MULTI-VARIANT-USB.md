# One USB, many machines: every variant on the stick

**Status (2026-10-20): SHIPPED as ostree deployments — see "How it works now".**
The layered design below it (`layers/base-<variant>/` swapped under one kernel
at RAM boot) is retained for history but is **superseded**: it never reached a
stick, and it cannot work on today's media — the live medium boots its bootc
root directly (no `rd.powos.ramboot=1`, so `ramboot-setup.sh`'s selector never
runs), and the variants do not share a kernel (deck 7.2.0-ogc6.1, main and
nvidia-open 7.2.9-ogc3.1), so a rootfs swapped under the deck kernel has no
modules for it. On an NVIDIA desktop the deck image fell to nouveau and this
kernel's nouveau panicked at 13 s (NULL deref in
`nouveau_abi16_ioctl_get_zcull_info`, fixed upstream 2026-08, not in the OGC
kernel yet).

## How it works now

`build/install-to-usb.sh --with-variants STORE --live-variants "deck main nvidia-open"`
(what `build/burn.sh` runs):

1. The raw image is written as before (one deployment: deck).
2. Each other variant is pulled from the **offline OCI store** already on the
   medium's host side (`build/fetch-variants.sh`) into the stick's ostree repo
   and deployed with `ostree admin deploy --retain` — its own kernel, initramfs
   and BLS entry. (`ostree container image deploy` would prune to two.)
3. Each deployment's origin names the **registry** image
   (`ostree-unverified-registry:ghcr.io/powback/powos:<variant>`), so
   `powos upgrade` on the stick updates that variant exactly like an installed
   system.
4. The default variant (`LIVE_DEFAULT`, `nvidia-open`) is deployed **last**.
   ostree numbers the newest deployment highest, and both menu-default writers
   (`install-to-usb.sh`, `bin/powos-boot-entries`) pick the highest — one rule.
5. Entries are titled by variant: *PowOS Live — NVIDIA (nvidia-open)*,
   *— Steam Deck (deck)*, *— AMD / Intel (main)*. PowOS's own entries (Install,
   basic graphics, Recovery) template from an entry as before.

Cost: the three share the Bazzite userland; the root grows from 9.5 to 17 GiB
of 26.8. Verified: each entry boots to SDDM under QEMU through a throwaway
overlay of the real stick (nvidia-open with no GPU present loads `nvidia` and
backs off cleanly).

**Selection is the menu.** Auto-detect would need a GPU test inside GRUB, which
GRUB does not have; the default is the variant that boots everywhere, and
nvidia-open on an AMD/Intel box is mesa with an unused driver. A later
refinement can let the booted system record the right default in `grubenv`.

**Secure Boot:** every variant's kernel is signed with the Universal Blue key
(`CN=ublue kernel`); a machine with Secure Boot on needs it enrolled
(`ujust enroll-secure-boot-key`, password `universalblue`) or Secure Boot off —
otherwise GRUB stops at "bad shim signature / you need to load the kernel first".

---

## The earlier design (superseded, kept for the record)


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
