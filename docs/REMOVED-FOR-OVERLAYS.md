# What Was Removed from Base Images for Overlays

This document provides a comprehensive list of packages, services, and configurations that were **intentionally removed** from the PowOS base images and will be provided via **systemd-sysext overlays**.

## Rationale

PowOS follows a **base + overlay** architecture where:
- **Base images** contain only hardware-agnostic, essential components
- **Overlays** provide device-specific, optional, or form-factor-specific functionality

This reduces base image size, enables modular updates, and allows users to customize their system without reinstalling.

---

## 1. Handheld Hardware Support Packages

### Removed from Base → Moved to Device-Specific Overlays

#### Steam Deck Hardware (steamdeck-hw.raw overlay)
| Package | Purpose | Size | Detection |
|---------|---------|------|-----------|
| `jupiter-fan-control` | Steam Deck fan control daemon | ~200KB | DMI: Jupiter |
| `jupiter-hw-support-btrfs` | Steam Deck hardware support | ~100KB | DMI: Jupiter |
| `vpower` | Virtual power device for battery reporting | ~50KB | DMI: Jupiter/Galileo |
| `galileo-mura` | OLED display calibration | ~500KB | DMI: Galileo |
| `steamdeck-dsp` | Steam Deck audio DSP profiles | ~1MB | DMI: Jupiter/Galileo |
| `powerbuttond` | Power button handling daemon | ~100KB | DMI: Jupiter/Galileo |
| `steam_notif_daemon` | Steam notification integration | ~150KB | DMI: Jupiter/Galileo |
| `sdgyrodsu` | Gyroscope support daemon | ~200KB | DMI: Jupiter/Galileo |

**Total Saved:** ~2.3MB
**Activation:** Automatic when DMI matches "Jupiter" or "Galileo"

#### ROG Ally Hardware (rog-ally-hw.raw overlay)
| Component | Purpose | Size |
|-----------|---------|------|
| Audio profiles | Device-specific audio configurations | ~500KB |
| TDP control configs | Power limit management | ~50KB |
| Controller mappings | Device-specific button mappings | ~100KB |
| Panel orientation fixes | Display rotation fixes | ~50KB |

**Total Saved:** ~700KB
**Activation:** Automatic when DMI matches "ROG Ally"

#### Legion Go Hardware (legion-go-hw.raw overlay)
| Component | Purpose | Size |
|-----------|---------|------|
| Audio profiles | Device-specific audio configurations | ~500KB |
| TDP control configs | Power limit management | ~50KB |
| Controller mappings | Device-specific button mappings | ~100KB |

**Total Saved:** ~650KB
**Activation:** Automatic when DMI matches "Legion Go"

#### Framework Laptop Support (framework-hw.raw overlay)
| Package/Config | Purpose | Size |
|----------------|---------|------|
| Framework-specific kargs | Kernel arguments for hardware fixes | ~1KB |
| 3.5mm audio jack fixes | Audio jack detection fixes | ~50KB |
| Suspend/resume fixes | Power management fixes | ~100KB |
| GPIO pinctrl modules | Hardware control modules | ~200KB |

**Total Saved:** ~350KB
**Activation:** Automatic when DMI vendor = "Framework"

**Note:** `framework_tool` is kept in base as it's small and useful for generic debugging.

---

## 2. Gaming Mode / Deck UI Packages

### Removed from Base → Moved to gaming-mode.raw Overlay

| Package | Purpose | Size | Why Removed |
|---------|---------|------|-------------|
| `gamescope-session-plus` | Console-like gaming session | ~5MB | Not needed for desktop users |
| `gamescope-session-steam` | Steam Big Picture integration | ~2MB | Not needed for desktop users |
| `steamos-manager` | SteamOS-like system manager | ~1MB | Gaming mode only |
| `bootstrap_steam.tar.gz` | Pre-packaged Steam bootstrap | ~50MB | Gaming mode only |
| Auto-login configs | `/etc/sddm.conf.d/steamos.conf` | ~5KB | Privacy concern for desktop |
| Deck logind config | Power button = suspend | ~2KB | Conflicts with desktop behavior |

**Total Saved:** ~58MB (significant!)
**Activation:** Manual (`ujust enable-gaming-mode`) or automatic for detected handhelds

---

## 3. Device-Specific Tools

### Removed from Base → Moved to Conditional Overlays

#### AMD-Specific Tools (amd-tools.raw overlay)
| Package | Purpose | Size | Why Removed |
|---------|---------|------|-------------|
| `ryzenadj` | AMD Ryzen TDP adjustment | ~500KB | Only for AMD devices needing TDP control |
| RyzenAdj configs | `/etc/default/ryzenadj` | ~5KB | Device-specific |

**Total Saved:** ~505KB
**Activation:** Conditional (AMD CPU + device needs TDP control)

#### Framework-Specific Tools (framework-tools.raw overlay)
| Package | Purpose | Size | Why Removed |
|---------|---------|------|-------------|
| `fw-ectool` | Framework EC tool | ~200KB | Framework-only |
| `fw-fanctrl` | Framework fan control | ~150KB | Framework-only |

**Total Saved:** ~350KB
**Activation:** Automatic for Framework laptops

#### Input Remapper (input-remapper.raw overlay)
| Package | Purpose | Size | Why Removed |
|---------|---------|------|-------------|
| `input-remapper` | Desktop input remapping | ~2MB | Conflicts with handheld gaming mode |
| `input-remapper.service` | Input remapping service | ~5KB | Not needed in gaming mode |

**Total Saved:** ~2MB
**Activation:** Automatic for desktop, disabled for gaming mode

**Conflict:** Cannot run simultaneously with `hhd` (Handheld Daemon)

---

## 4. Handheld Daemon (Generic Handheld Support)

### Removed from Base → Moved to handheld-generic.raw Overlay

| Package | Purpose | Size | Why Removed |
|---------|---------|------|-------------|
| `hhd` / `hhd-git` | Handheld Daemon (universal controller support) | ~5MB | Only for handheld devices |
| `hhd-ui` | Handheld Daemon UI | ~1MB | Only for handheld devices |

**Total Saved:** ~6MB
**Activation:** Automatic for detected handhelds, manual for others

**Why separate from gaming-mode.raw?**
- Some users may want gaming mode without handheld controls (desktop big-screen mode)
- HHD is device-specific, gaming mode is a UI choice

---

## 5. Hybrid GPU Support

### Removed from Base → Moved to hybrid-gpu.raw Overlay

| Package | Purpose | Size | Why Removed |
|---------|---------|------|-------------|
| `supergfxctl` | Hybrid GPU switching daemon | ~1MB | Only for hybrid GPU laptops |
| `supergfxctl-plasmoid` | KDE widget for GPU switching | ~500KB | KDE + hybrid GPU only |
| `gnome-shell-extension-supergfxctl-gex` | GNOME extension for GPU switching | ~500KB | GNOME + hybrid GPU only |

**Total Saved:** ~2MB
**Activation:** Manual (`ujust enable-hybrid-gpu`)
**Service:** `supergfxd.service` (disabled by default in base)

**Why Manual?**
- Automatic GPU switching can cause issues
- User should opt-in when they have hybrid GPU setup
- Not needed for most desktop/laptop users

---

## 6. Audio Profiles

### Removed from Base → Moved to Per-Device Audio Overlays

Audio profiles are **device-specific** and can be large. Base image includes only generic Pipewire/WirePlumber.

| Device | Files | Size | Overlay |
|--------|-------|------|---------|
| Steam Deck | `/usr/share/pipewire/hardware-profiles/jupiter/` | ~1MB | `audio-steamdeck.raw` |
| ROG Ally | `/usr/share/wireplumber/hardware-profiles/rog-ally/` | ~800KB | `audio-rog-ally.raw` |
| Legion Go | `/usr/share/pipewire/hardware-profiles/legion-go/` | ~800KB | `audio-legion-go.raw` |
| GPD Win | `/usr/share/wireplumber/hardware-profiles/gpd-*/` | ~500KB | `audio-gpd-win.raw` |
| AOKZOE | Audio profiles | ~500KB | `audio-aokzoe.raw` |
| MSI Claw | Audio profiles | ~500KB | `audio-msi-claw.raw` |

**Total Saved (all devices):** ~4.1MB
**Activation:** Automatic based on DMI detection

**Why Removed?**
- Most users only have one device
- Shipping all profiles wastes space
- Profiles are easily updated independently

---

## 7. Variant-Specific System Files

### Desktop vs Deck System Files

Bazzite has separate `system_files/desktop/` and `system_files/deck/` directories. PowOS consolidates:

**Kept in Base:**
- `system_files/desktop/shared/` - Generic desktop configs
- `system_files/desktop/kinoite/` - KDE-specific configs
- `system_files/overrides/` - System-wide overrides

**Moved to Overlays:**
- `system_files/deck/shared/` → `gaming-mode.raw` overlay
- `system_files/deck/kinoite/` → `gaming-mode.raw` overlay
- Device-specific configs → Per-device overlays

| Component | Size | Destination |
|-----------|------|-------------|
| Deck systemd configs | ~50KB | `gaming-mode.raw` |
| Deck boot configs | ~20KB | `gaming-mode.raw` |
| Deck GRUB configs | ~10KB | `gaming-mode.raw` |
| Deck SDDM configs | ~5KB | `gaming-mode.raw` |

**Total Saved:** ~85KB

---

## 8. Systemd Services

### Services Removed / Modified in Base

| Service | Status in Base | Status in Overlay | Reason |
|---------|----------------|-------------------|--------|
| `input-remapper.service` | ❌ Removed | ✅ In input-remapper.raw | Conflicts with gaming mode |
| `hhd.service` | ❌ Removed | ✅ In handheld-generic.raw | Handheld-only |
| `jupiter-fan-control.service` | ❌ Removed | ✅ In steamdeck-hw.raw | Steam Deck only |
| `vpower.service` | ❌ Removed | ✅ In steamdeck-hw.raw | Steam Deck only |
| `bazzite-autologin.service` | ❌ Removed | ✅ In gaming-mode.raw | Gaming mode only |
| `steamos-manager.service` | ❌ Removed | ✅ In gaming-mode.raw | Gaming mode only |
| `return-to-gamemode.service` | ❌ Removed | ✅ In gaming-mode.raw | Gaming mode only |
| `wireplumber-workaround.service` | ❌ Removed | ✅ In steamdeck-hw.raw | Deck-specific audio fix |
| `pipewire-workaround.service` | ❌ Removed | ✅ In steamdeck-hw.raw | Deck-specific audio fix |
| `cec-onboot.service` | ✅ Kept | ✅ Enabled conditionally | Generic CEC support |
| `supergfxd.service` | ❌ Removed (NVIDIA base) | ✅ In hybrid-gpu.raw | Hybrid GPU only |
| `fw-fanctrl.service` | ❌ Removed | ✅ In framework-tools.raw | Framework only |
| `sdgyrodsu.service` | ❌ Removed | ✅ In steamdeck-hw.raw | Gyro support (Deck) |

---

## 9. GPU-Specific Packages

### Packages Specific to Mesa Base

| Package | Size | Why in Mesa Only |
|---------|------|------------------|
| `rocm-hip` | ~50MB | AMD GPU compute |
| `rocm-opencl` | ~30MB | AMD GPU compute |
| `rocm-clinfo` | ~1MB | AMD GPU info tool |
| `rocm-smi` | ~2MB | AMD GPU monitoring |

**Total:** ~83MB (not in NVIDIA base)

### Packages Specific to NVIDIA Base

| Package | Size | Why in NVIDIA Only |
|---------|------|-------------------|
| `nvidia-driver-*` | ~150MB | NVIDIA proprietary driver |
| `nvidia-settings` | ~5MB | NVIDIA control panel |
| `nvidia-container-toolkit` | ~10MB | GPU containers |
| `libnvidia-ml-*` | ~5MB | NVIDIA ML library |
| `supergfxctl` (base) | ~1MB | Hybrid GPU switching |
| `egl-wayland` / `egl-wayland2` | ~2MB | NVIDIA Wayland support |

**Total:** ~173MB (not in Mesa base)

**Why Separate?**
- Users only need one GPU stack
- Prevents conflicts between Mesa and NVIDIA
- Reduces base image size
- Enables per-GPU optimizations

---

## Total Space Savings

### Per Base Image (vs Bazzite All-in-One)

| Category | Size Saved |
|----------|------------|
| Handheld hardware packages | ~4MB |
| Gaming mode packages | ~58MB |
| Device-specific tools | ~3MB |
| Audio profiles (all devices) | ~4MB |
| Handheld Daemon | ~6MB |
| Hybrid GPU support | ~2MB |
| Unused GPU stack (NVIDIA vs AMD) | ~83-173MB |
| **TOTAL SAVINGS** | **~160-240MB per image** |

### Additional Benefits

Beyond size savings:
- **Modular updates:** Update overlays without touching base
- **User customization:** Enable/disable features at runtime
- **Community contributions:** Easy to add new device support
- **Faster downloads:** Smaller base images
- **Storage efficiency:** Share base, download only needed overlays

---

## Migration Path

### From Bazzite-Deck to PowOS

**Old (Bazzite-Deck):**
```
Base Image: bazzite-deck (all-in-one, ~4GB)
- Includes gaming mode
- Includes handheld hardware support
- Includes device-specific configs
```

**New (PowOS):**
```
Base Image: powos-base-mesa (~3.5GB)
+ Overlays:
  - steamdeck-jupiter.raw (~2.5MB)
  - gaming-mode.raw (~58MB)
  - audio-steamdeck.raw (~1MB)

Total: ~3.56GB (440MB smaller!)
```

### From Bazzite to PowOS (Desktop)

**Old (Bazzite Desktop):**
```
Base Image: bazzite (~3.8GB)
- Includes all handheld packages (unused)
- Includes gaming mode (unused)
- Includes device profiles (unused)
```

**New (PowOS):**
```
Base Image: powos-base-mesa (~3.5GB)
+ Overlays: None

Total: ~3.5GB (300MB smaller!)
```

---

## Overlay Activation Logic

### Automatic Activation (On Boot)

```bash
# /usr/libexec/powos-hardware-detect

# Detect GPU
GPU_VENDOR=$(lspci | grep VGA | grep -o "NVIDIA\|AMD\|Intel")

# Detect Device
DMI_PRODUCT=$(cat /sys/devices/virtual/dmi/id/product_name)

# Activate overlays based on detection
case "$DMI_PRODUCT" in
  "Jupiter")
    activate_overlay steamdeck-jupiter.raw
    activate_overlay gaming-mode.raw
    activate_overlay audio-steamdeck.raw
    enable_service jupiter-fan-control.service
    ;;
  "ROG Ally")
    activate_overlay rog-ally-hw.raw
    activate_overlay gaming-mode.raw
    activate_overlay audio-rog-ally.raw
    enable_service hhd.service
    ;;
  *)
    # Generic desktop, no overlays
    ;;
esac

# Refresh systemd-sysext
systemd-sysext refresh
```

### Manual Activation (User Choice)

```bash
# Enable gaming mode
ujust enable-gaming-mode
# → Activates gaming-mode.raw
# → Enables bazzite-autologin.service
# → Reboot required

# Enable hybrid GPU support
ujust enable-hybrid-gpu
# → Activates hybrid-gpu.raw
# → Enables supergfxd.service
# → Reboot required

# Enable handheld mode (non-Steam Deck)
ujust enable-handheld-mode
# → Activates handheld-generic.raw
# → Enables hhd.service
# → Reboot required
```

---

## Future Removals (Under Consideration)

### Candidates for Future Overlay Migration

| Package | Size | Reason to Move |
|---------|------|----------------|
| `waydroid` + `cage` | ~50MB | Not all users need Android |
| `qemu` + `libvirt` | ~100MB | Virtualization is optional |
| `snapper` + `btrfs-assistant` | ~10MB | Snapshot tools are optional |
| `cockpit-*` modules | ~20MB | Web UI is optional |

**Potential savings:** ~180MB additional

### Rationale
- Keep base minimal for core gaming
- Provide optional features via overlays
- Let users choose what they need

---

## Conclusion

By moving **160-240MB** of device-specific, optional, and form-factor-specific functionality to overlays, PowOS achieves:

1. **Smaller base images** (~3.5GB vs ~3.8GB Bazzite)
2. **Modular customization** (enable/disable features at runtime)
3. **Faster updates** (update base or overlays independently)
4. **Community extensibility** (easy to add new device support)
5. **Better user experience** (only install what you need)

This architecture enables PowOS's vision of a **portable, hardware-adaptive gaming OS** that works seamlessly across diverse hardware.

---

**See Also:**
- [OVERLAY-ARCHITECTURE.md](./OVERLAY-ARCHITECTURE.md) - Full overlay system design
- [BAZZITE-ANALYSIS.md](./BAZZITE-ANALYSIS.md) - Original Bazzite analysis
- [containers/README.md](../containers/README.md) - Build system documentation
