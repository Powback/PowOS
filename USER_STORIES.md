# PowOS User Stories

> **How I Use This OS** - The definitive acceptance criteria for the Container-Native Workstation

---

## Epic 1: The "Chameleon" Boot (Hardware Adaptation)

**Focus:** One drive, any machine, zero configuration.

### Story 1.1: Desktop Dock

**As a** user booting on my primary rig (Dual RTX 3090s),
**I want** the OS to automatically detect the GPUs and load the proprietary Nvidia drivers and "High Performance" scheduler,
**So that** I get maximum framerates and CUDA performance without manually toggling settings.

**Acceptance Criteria:**
- [ ] Boot completes without manual intervention
- [ ] `nvidia-smi` shows both 3090s active
- [ ] System76-Scheduler running in "Performance" mode
- [ ] GPU fans respond to load (via `nvidia-settings` or `coolbits`)

---

### Story 1.2: Laptop Drift

**As a** user plugging into a random Intel/AMD laptop,
**I want** the OS to automatically sleep the Nvidia drivers and load the Intel Media Driver + Battery Saver (TLP) profile,
**So that** I don't get a black screen or drain the battery in 30 minutes, without having to maintain a separate "Laptop Image."

**Acceptance Criteria:**
- [ ] Boot completes on Intel/AMD hardware without black screen
- [ ] `lsmod | grep nvidia` returns empty (drivers slept)
- [ ] TLP service active (`tlp-stat -s`)
- [ ] Hardware video decode works (`vainfo` shows Intel/AMD)
- [ ] Battery life comparable to native Linux install

---

### Story 1.3: Hot-Plug Adaptation

**As a** user who occasionally docks the laptop to an eGPU,
**I want** the OS to detect the Thunderbolt GPU connection and switch to hybrid mode,
**So that** I can leverage external GPU acceleration without rebooting.

**Acceptance Criteria:**
- [ ] eGPU detected within 5 seconds of connection
- [ ] Applications can render to external GPU via `DRI_PRIME` or `prime-run`
- [ ] Graceful fallback when eGPU disconnected

---

## Epic 2: The "Recorder" Workflow (Installing Software)

**Focus:** Interactive terminal usage that creates permanent infrastructure code.

### Story 2.1: Instant Tool Install

**As a** developer who needs `ripgrep` immediately,
**I want** to type `pinstall ripgrep` in the terminal and have it available instantly,
**So that** I don't have to wait for a full OS rebuild just to use a small CLI tool.

**Acceptance Criteria:**
- [ ] `pinstall ripgrep` completes in < 30 seconds
- [ ] `rg --version` works immediately after
- [ ] Tool persists across terminal sessions
- [ ] Tool available in all Distrobox containers

---

### Story 2.2: Automatic Config Capture

**As a** system architect,
**I want** the `pinstall` command to automatically append `ripgrep` to my `distrobox.ini` file and commit it to Git,
**So that** if I lose my drive tomorrow, my infrastructure code knows exactly what tools I had installed.

**Acceptance Criteria:**
- [ ] `distrobox.ini` updated with new package
- [ ] Git commit created with message `install: ripgrep`
- [ ] `git log` shows installation history
- [ ] `just hydrate` on fresh system installs all recorded tools

---

### Story 2.3: Bulk Tool Install

**As a** developer setting up a new project,
**I want** to run `pinstall node python go rust` to install multiple tools at once,
**So that** I can bootstrap my dev environment quickly.

**Acceptance Criteria:**
- [ ] All tools installed in parallel where possible
- [ ] Single git commit: `install: node python go rust`
- [ ] All tools functional after install

---

### Story 2.4: Tool Removal

**As a** user cleaning up unused tools,
**I want** to run `premove python` to uninstall and remove from config,
**So that** my infrastructure code stays lean.

**Acceptance Criteria:**
- [ ] Tool removed from runtime environment
- [ ] Tool removed from `distrobox.ini`
- [ ] Git commit: `remove: python`

---

## Epic 3: The "Frankenstein" Mod (System Overlay)

**Focus:** Modifying read-only system files safely.

### Story 3.1: Source Hack

**As a** power user who hates the default KDE Dolphin borders,
**I want** to edit the C++ source code in `~/powos/sources/dolphin` and run `just build dolphin`,
**So that** the system compiles my custom binary and injects it into the RAM Overlay (systemd-sysext), replacing the system default instantly.

**Acceptance Criteria:**
- [ ] Source code editable in `~/powos/sources/dolphin`
- [ ] `just build dolphin` compiles without manual dependency hunting
- [ ] Modified binary appears in `~/powos/extensions/`
- [ ] Running `dolphin` launches the custom version
- [ ] Original system binary untouched

---

### Story 3.2: Reboot Persistence

**As a** user rebooting the machine,
**I want** my custom Dolphin binary to be re-applied automatically via the overlay service,
**So that** my "Frankenstein" modifications feel like a native part of the OS.

**Acceptance Criteria:**
- [ ] Overlay service starts at boot
- [ ] Custom binaries active before user login
- [ ] `which dolphin` points to overlay version
- [ ] No manual intervention required

---

### Story 3.3: Overlay Rollback

**As a** user whose custom build broke something,
**I want** to run `just disable-overlay dolphin` to temporarily use the stock version,
**So that** I can debug without a full rebuild.

**Acceptance Criteria:**
- [ ] Single command disables specific overlay
- [ ] System binary immediately available
- [ ] `just enable-overlay dolphin` restores custom version
- [ ] No reboot required

---

### Story 3.4: Multiple Overlays

**As a** power user with multiple customizations,
**I want** to maintain overlays for Dolphin, Konsole, and Plasma Shell simultaneously,
**So that** I can customize the entire DE experience.

**Acceptance Criteria:**
- [ ] Multiple overlay sources in `~/powos/sources/`
- [ ] `just build-all` compiles everything
- [ ] Overlays don't conflict with each other
- [ ] Individual enable/disable per overlay

---

## Epic 4: The Self-Healing Update

**Focus:** Surviving upstream changes without manual maintenance.

### Story 4.1: Conflict Detection

**As a** maintainer running a system update (`just update`),
**I want** the build system to detect if my custom Dolphin patch conflicts with the new upstream source code,
**So that** I am alerted to the breakage before it hits my production desktop.

**Acceptance Criteria:**
- [ ] Update process checks overlay compatibility
- [ ] Clear error message on patch failure
- [ ] Update continues for non-conflicting components
- [ ] Failed overlays disabled automatically (fallback to stock)

---

### Story 4.2: AI Patch Engineer

**As a** lazy developer,
**I want** the update process to automatically invoke the Local AI (Ollama) to rewrite my broken patch for the new code structure,
**So that** I don't have to manually debug C++ merge conflicts every time Fedora updates a package.

**Acceptance Criteria:**
- [ ] AI invoked automatically on patch failure
- [ ] AI has access to: old patch, new source, error messages
- [ ] AI-generated patch presented for review (not auto-applied)
- [ ] Option to accept, reject, or manually edit
- [ ] Works offline using local Ollama on 3090s

---

### Story 4.3: Update Dry Run

**As a** cautious user,
**I want** to run `just update --dry-run` to preview what will change,
**So that** I can assess risk before committing.

**Acceptance Criteria:**
- [ ] Shows list of package updates
- [ ] Shows overlay compatibility status
- [ ] No changes applied
- [ ] Estimated download size shown

---

## Epic 5: The Desktop Hardware Fix

**Focus:** Integrating the legacy Z270 rig with modern peripherals.

### Story 5.1: Fan Control

**As a** user with a Z270 motherboard but modern Corsair fans,
**I want** to control my AIO Pump and Fans via `liquidctl` (or OpenRGB) inside the OS,
**So that** I can set quiet curves for coding and aggressive curves for ML training, utilizing the NZXT Hub connection we built.

**Acceptance Criteria:**
- [ ] `liquidctl` detects NZXT Hub and Corsair devices
- [ ] Fan curves configurable via CLI or GUI
- [ ] Profiles: "Silent", "Balanced", "Performance"
- [ ] Profile persists across reboots
- [ ] Real-time temperature monitoring

---

### Story 5.2: RGB Control

**As a** user who wants the rig to look cool,
**I want** to control RGB on fans, GPU, and motherboard from a single interface,
**So that** I can set a unified theme.

**Acceptance Criteria:**
- [ ] OpenRGB detects all RGB devices
- [ ] Single profile applies to all devices
- [ ] Profiles saved and restored at boot
- [ ] No Windows software required

---

### Story 5.3: ML Training Mode

**As a** user starting a long ML training job,
**I want** to run `just mode training` to maximize cooling and disable sleep,
**So that** the system stays stable during 48-hour runs.

**Acceptance Criteria:**
- [ ] Fans set to aggressive curve
- [ ] Sleep/hibernate disabled
- [ ] Screen saver disabled
- [ ] GPU power limits set to maximum
- [ ] Notification sent when training completes

---

## Epic 6: Disaster Recovery (The "15-Minute Rule")

**Focus:** Total loss of physical hardware.

### Story 6.1: Phoenix Protocol

**As a** user who dropped their Lexar drive in a lake,
**I want** to flash a generic Bazzite ISO to a new drive, clone my repo, and run `just hydrate`,
**So that** my entire OS—including tools, secrets, custom compiled binaries, and wallpapers—is restored exactly as it was in less than 15 minutes.

**Acceptance Criteria:**
- [ ] Fresh Bazzite ISO boots
- [ ] `git clone` + `just hydrate` restores everything
- [ ] All tools from `distrobox.ini` installed
- [ ] All overlays compiled and applied
- [ ] Desktop customizations (wallpaper, themes) restored
- [ ] Total time under 15 minutes (excluding download)

---

### Story 6.2: Secrets Restoration

**As a** user with API keys and SSH keys,
**I want** `just hydrate` to securely restore my secrets from an encrypted backup,
**So that** I can immediately push to GitHub and access cloud services.

**Acceptance Criteria:**
- [ ] Secrets stored encrypted (age, sops, or similar)
- [ ] Decryption key stored separately (password, hardware key)
- [ ] SSH keys restored to `~/.ssh/`
- [ ] GPG keys restored
- [ ] API tokens restored to appropriate locations
- [ ] No secrets in plaintext in repo

---

### Story 6.3: Partial Hydration

**As a** user setting up a minimal workstation on borrowed hardware,
**I want** to run `just hydrate --minimal` to get a basic dev environment without 50GB of ML tools,
**So that** I can be productive on limited hardware/bandwidth.

**Acceptance Criteria:**
- [ ] Core tools installed (git, editor, shell config)
- [ ] Optional: `--with ml` adds ML stack
- [ ] Optional: `--with gaming` adds Steam, Proton
- [ ] Minimal hydration completes in < 5 minutes

---

## Epic 7: Daily Workflow

**Focus:** The mundane tasks that should just work.

### Story 7.1: Morning Boot

**As a** user starting my workday,
**I want** to boot the system and have everything ready in under 60 seconds,
**So that** I can start coding immediately.

**Acceptance Criteria:**
- [ ] Boot to usable desktop < 60 seconds
- [ ] Browser opens to last session (optional)
- [ ] Terminal opens in last working directory
- [ ] No update prompts blocking workflow

---

### Story 7.2: Container Development

**As a** developer working on multiple projects,
**I want** to have isolated development environments via Distrobox,
**So that** Node 18 project doesn't conflict with Node 20 project.

**Acceptance Criteria:**
- [ ] Multiple Distrobox containers defined in `containers/`
- [ ] Each container has specific tool versions
- [ ] Easy switching: `distrobox enter node18`
- [ ] GUI apps work from containers (VS Code, etc.)

---

### Story 7.3: Seamless Updates

**As a** user who doesn't want to think about maintenance,
**I want** updates to happen in the background and apply on next boot,
**So that** I'm always current without interruption.

**Acceptance Criteria:**
- [ ] Updates download in background
- [ ] No forced reboots
- [ ] "Staged" update applied on next natural boot
- [ ] Rollback available if update breaks things

---

## Epic 8: The Build System

**Focus:** The `justfile` that orchestrates everything.

### Story 8.1: Single Entry Point

**As a** user,
**I want** `just` to show me all available commands,
**So that** I don't have to remember arcane incantations.

**Acceptance Criteria:**
- [ ] `just` (no args) shows categorized command list
- [ ] Commands have descriptions
- [ ] Tab completion works

---

### Story 8.2: Build Image

**As a** maintainer,
**I want** to run `just build-image` to create a new base OS image from my Containerfile,
**So that** I can test infrastructure changes.

**Acceptance Criteria:**
- [ ] Builds Docker image from `Containerfile`
- [ ] Tags with version and `latest`
- [ ] Pushes to container registry (optional)
- [ ] Build time < 10 minutes for incremental changes

---

### Story 8.3: Deploy to Hardware

**As a** maintainer,
**I want** to run `just deploy` to flash the new image to my USB4 drive,
**So that** I can test on real hardware.

**Acceptance Criteria:**
- [ ] Safely unmounts target drive
- [ ] Flashes image with progress indicator
- [ ] Verifies write integrity
- [ ] Ready to boot after completion

---

## Summary: The Command Vocabulary

| Command | Action |
|---------|--------|
| `pinstall <pkg>` | Install tool + record in config |
| `premove <pkg>` | Remove tool + update config |
| `just build <component>` | Compile overlay component |
| `just build-all` | Compile all overlays |
| `just update` | System update with overlay checks |
| `just update --dry-run` | Preview updates |
| `just hydrate` | Full system restoration |
| `just hydrate --minimal` | Basic restoration |
| `just mode <profile>` | Switch system profile |
| `just build-image` | Build base OS image |
| `just deploy` | Flash image to drive |

---

## Epic 9: The "Unplugged" Resilience (Hot-Swap Storage)

**Focus:** Survive temporary disk disconnection without data loss.

### Story 9.1: Graceful Disconnect

**As a** user who accidentally unplugs the USB drive (or has a loose USB-C connection),
**I want** the OS to continue running from RAM cache,
**So that** I don't immediately crash or lose my work.

**Acceptance Criteria:**
- [ ] System detects USB drive disconnect event
- [ ] Active processes continue running (from memory)
- [ ] Writes cached to RAM (tmpfs overlay)
- [ ] Clear visual indicator: "Storage Disconnected - Running in Cache Mode"
- [ ] Warning if RAM cache exceeds threshold (e.g., 2GB pending writes)

---

### Story 9.2: State Sync on Reconnect

**As a** user who replugs the drive,
**I want** all cached changes to automatically sync back to persistent storage,
**So that** nothing is lost and I can continue working normally.

**Acceptance Criteria:**
- [ ] Drive reconnection detected within 2 seconds
- [ ] Cached writes flushed to disk in order
- [ ] Progress indicator during sync
- [ ] "Storage Reconnected - Sync Complete" notification
- [ ] Verification that no data was lost

---

### Story 9.3: Alternative Cache Target

**As a** user with a secondary internal SSD,
**I want** to configure that drive as a cache target instead of RAM,
**So that** I can survive longer disconnections without running out of memory.

**Acceptance Criteria:**
- [ ] Config option: `POWOS_CACHE_DEVICE=/dev/nvme0n1p4`
- [ ] Writes go to cache device when primary disconnected
- [ ] Larger cache capacity (10GB+)
- [ ] Automatic sync when primary reconnected
- [ ] Cache cleared after successful sync

---

### Story 9.4: Extended Disconnect Mode

**As a** user who needs to intentionally disconnect the drive (e.g., to plug into another machine for file transfer),
**I want** to run `powos-cache enable` before unplugging,
**So that** the system pre-configures for extended disconnection.

**Acceptance Criteria:**
- [ ] Command prepares system for intentional disconnect
- [ ] All pending writes flushed before disconnect
- [ ] Extended cache mode enabled
- [ ] Safe to unplug indicator
- [ ] `powos-cache sync` forces sync on replug

---

### Story 9.5: Boot Without Primary Drive

**As a** user whose drive is temporarily unavailable at boot,
**I want** the system to boot into a degraded "cache-only" mode from the internal drive,
**So that** I can still use the machine while waiting for my USB drive.

**Acceptance Criteria:**
- [ ] Fallback boot from internal cache partition
- [ ] Limited functionality (cached tools/configs only)
- [ ] Clear indication this is degraded mode
- [ ] Full functionality restored when drive connected
- [ ] User data from last sync available

---

## Epic 10: Multi-Machine State Sync

**Focus:** One drive, multiple machines, consistent state.

### Story 10.1: Machine-Specific Configs

**As a** user who plugs the drive into different machines,
**I want** machine-specific configs (monitor layout, GPU settings) stored separately,
**So that** each machine gets appropriate settings without overwriting others.

**Acceptance Criteria:**
- [ ] Machine ID detected at boot (hardware fingerprint)
- [ ] Per-machine config directory: `/var/lib/powos/machines/<id>/`
- [ ] Display, GPU, and network configs per-machine
- [ ] Common configs shared (dotfiles, tools)

---

### Story 10.2: Cross-Machine Sync

**As a** user with multiple workstations,
**I want** changes to shared configs to sync when I plug into each machine,
**So that** my editor settings and shell aliases are consistent everywhere.

**Acceptance Criteria:**
- [ ] Shared configs in git-tracked location
- [ ] Auto-pull on boot (if network available)
- [ ] Conflict resolution for simultaneous edits
- [ ] Machine-specific overrides respected

---

## Architecture: Cache Layer Implementation

```
┌─────────────────────────────────────────────────────────────────┐
│                     Normal Operation                             │
│                                                                  │
│  [Applications] → [VFS] → [OverlayFS] → [USB4 Drive]            │
│                             ↓                                    │
│                      /home/powos                                 │
│                      /var/lib/powos                              │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                     Disconnected Mode                            │
│                                                                  │
│  [Applications] → [VFS] → [OverlayFS] → [RAM tmpfs]             │
│                             ↓            (or cache SSD)          │
│                      Upperdir: /run/powos-cache                  │
│                      Lowerdir: (last known state)                │
│                                                                  │
│  udev rule triggers on USB disconnect:                           │
│  → Remount overlay with tmpfs upperdir                           │
│  → Start cache monitor daemon                                    │
│  → Show disconnect notification                                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                     Reconnect & Sync                             │
│                                                                  │
│  udev rule triggers on USB reconnect:                            │
│  → Verify drive integrity                                        │
│  → rsync /run/powos-cache → USB drive                           │
│  → Remount overlay with USB upperdir                             │
│  → Clear cache                                                   │
│  → Show sync complete notification                               │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | File | Purpose |
|-----------|------|---------|
| Disconnect handler | `systemd/powos-cache-disconnect.service` | Triggered by udev on USB removal |
| Cache daemon | `bin/powos-cache-daemon` | Monitors cache size, handles sync |
| Reconnect handler | `systemd/powos-cache-reconnect.service` | Triggered by udev on USB insert |
| Config | `/etc/powos/cache.conf` | Cache device, size limits, policies |
| Cache mount | `/run/powos-cache` | tmpfs or block device mount point |

### udev Rules

```bash
# /etc/udev/rules.d/99-powos-cache.rules

# USB drive disconnect - switch to cache mode
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_SERIAL}=="Lexar_NM790*", \
    RUN+="/usr/lib/powos/powos-cache-disconnect"

# USB drive reconnect - sync and restore
ACTION=="add", SUBSYSTEM=="block", ENV{ID_SERIAL}=="Lexar_NM790*", \
    RUN+="/usr/lib/powos/powos-cache-reconnect"
```

---

*Last Updated: 2025-12-13*
