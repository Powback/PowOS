# HomeFS Integration with PowOS

## Overview

This document describes how HomeFS integrates into the PowOS boot architecture and overlay system.

## Boot Sequence Integration

### Current PowOS Boot Flow

```
1. UEFI → Bootloader
2. Load kernel + initramfs
3. Detect GPU (nvidia vs mesa)
4. Mount appropriate base image
5. Load systemd-sysext overlays
6. Start systemd services
7. User login
```

### HomeFS Extended Boot Flow

```
1. UEFI → Bootloader
2. Load kernel + initramfs
3. Detect GPU (nvidia vs mesa)
4. Mount appropriate base image
5. Load systemd-sysext overlays
6. Start systemd services
7. ┌────────────────────────────┐
   │ 7a. Mount HomeFS           │  ← NEW
   │ 7b. Load metadata to RAM   │  ← NEW
   │ 7c. Start sync daemon      │  ← NEW
   └────────────────────────────┘
8. User login (with lazy-loaded /home)
```

## USB Drive Partitioning

### Recommended Layout

```
┌─────────────────────────────────────────────────────────┐
│ USB4 Drive (e.g., 1TB SSD)                              │
├─────────────────────────────────────────────────────────┤
│                                                         │
│ Partition 1: EFI System (512MB, FAT32)                 │
│   /EFI/BOOT/BOOTX64.EFI                                 │
│   /loader/ (systemd-boot config)                        │
│                                                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│ Partition 2: PowOS System (100GB, BTRFS)               │
│   @mesa/     (Mesa base image subvolume)               │
│   @nvidia/   (NVIDIA base image subvolume)             │
│   @overlays/ (Systemd-sysext overlays)                 │
│   @state/    (Git-tracked system state)                │
│                                                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│ Partition 3: HomeFS User Data (Rest, BTRFS)           │  ← NEW
│   /home/                                                │
│   /projects/                                            │
│   /data/                                                │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Partition Commands

```bash
# 1. Partition the drive
sudo gdisk /dev/sdX

# Create partitions:
# 1. EFI System (512MB, type EF00)
# 2. PowOS System (100GB, type 8300)
# 3. HomeFS Data (remainder, type 8300)

# 2. Format partitions
sudo mkfs.vfat -F32 /dev/sdX1
sudo mkfs.btrfs -L POWOS-SYSTEM /dev/sdX2
sudo mkfs.btrfs -L POWOS-HOME /dev/sdX3

# 3. Get UUIDs for config
sudo blkid /dev/sdX1  # EFI UUID
sudo blkid /dev/sdX2  # System UUID
sudo blkid /dev/sdX3  # HomeFS UUID
```

## Systemd Service Integration

### Service Ordering

```
┌─────────────────────────────────────────────────────┐
│ Boot Target: multi-user.target                      │
├─────────────────────────────────────────────────────┤
│                                                     │
│ 1. powos-init.service                               │
│    └─> Detects hardware, sets up environment       │
│                                                     │
│ 2. powos-hardware-detect.service                    │
│    └─> GPU detection, profile selection            │
│                                                     │
│ 3. powos-overlay.service                            │
│    └─> Load systemd-sysext overlays                │
│                                                     │
│ 4. powos-homefs.service              ← NEW         │
│    └─> Mount HomeFS at /home                       │
│                                                     │
│ 5. powos-homefs-sync.service         ← NEW         │
│    └─> Start background sync daemon                │
│                                                     │
│ 6. powos-usb-monitor.service         ← NEW         │
│    └─> Monitor USB hotplug events                  │
│                                                     │
│ 7. User session services                            │
│    └─> Desktop environment, apps                   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Service Dependencies

```bash
# /etc/systemd/system/powos-homefs.service
[Unit]
After=local-fs.target powos-overlay.service
Before=systemd-user-sessions.service

[Service]
Type=simple
ExecStart=/usr/local/bin/homefs mount /dev/disk/by-uuid/%i /home

# /etc/systemd/system/powos-homefs-sync.service
[Unit]
After=powos-homefs.service
Requires=powos-homefs.service

# /etc/systemd/system/powos-usb-monitor.service
[Unit]
After=systemd-udevd.service
```

## Configuration Files

### HomeFS Config Location

```
/etc/homefs/
├── config.json           # Main configuration
└── pinned.txt            # List of pinned files (optional)

/var/lib/homefs/
├── journal.wal           # Write-ahead journal
└── metadata.db           # Cached metadata (optional)

/var/run/homefs/
└── status.json           # Runtime status
```

### PowOS Integration Config

Add to `/etc/powos/config.yaml`:

```yaml
homefs:
  enabled: true
  uuid: "YOUR-HOMEFS-UUID"
  mount_point: /home
  cache_size: 4G
  sync_strategy: batched

  # Optional: Pre-load patterns
  preload:
    - ~/.config/**
    - ~/.bashrc
    - ~/.ssh/config

  # Optional: Never cache patterns
  exclude:
    - ~/.cache/**
    - ~/Downloads/**
    - ~/.local/share/Trash/**
```

## Integration with Git State Tracking

### HomeFS Metadata in Git

PowOS tracks system state in Git. HomeFS metadata should also be tracked:

```bash
~/powos/state/
├── distrobox.ini          # Container configs
├── overlays.list          # Enabled overlays
├── homefs-config.json     # HomeFS config
└── homefs-pinned.txt      # Pinned files list
```

### Auto-commit on Changes

```bash
# When pinning a file
homefs pin ~/.config/important.conf

# Automatically commits to Git
cd ~/powos
git add state/homefs-pinned.txt
git commit -m "pin: ~/.config/important.conf"
```

## RAM Allocation Strategy

### Memory Budget

For a system with 16GB RAM:

```
Total RAM: 16GB
├─ Base OS: 2GB
├─ Desktop Environment: 1GB
├─ Applications: 5GB
├─ HomeFS Cache: 4GB        ← Configurable
├─ Systemd-sysext overlays: 512MB
└─ Free/Buffers: 3.5GB
```

### Dynamic Adjustment

HomeFS monitors RAM pressure and adjusts:

```python
if ram_usage > 80%:
    evict_25_percent_of_cache()

if ram_usage > 90%:
    evict_all_non_essential_cache()
    sync_dirty_files_to_usb()
```

## Chameleon Boot + HomeFS

### Laptop Mode (Battery)

When running on battery:

```yaml
homefs:
  cache_size: 2G          # Smaller cache
  sync_strategy: manual   # Save battery, sync on demand
  aggressive_eviction: true
```

### Desktop Mode (AC Power)

When on AC power:

```yaml
homefs:
  cache_size: 8G          # Larger cache
  sync_strategy: batched  # Auto-sync every 30s
  aggressive_eviction: false
```

### Profile Auto-switching

Integrated with `hardware-detect.sh`:

```bash
# lib/hardware-detect.sh

if [[ "$power_source" == "battery" ]]; then
    # Switch to battery-optimized HomeFS
    homefs-config --profile=battery
else
    # Switch to performance HomeFS
    homefs-config --profile=performance
fi
```

## First Boot Setup

### User Experience

```
┌─────────────────────────────────────────────────────┐
│ PowOS First Boot Wizard                             │
├─────────────────────────────────────────────────────┤
│                                                     │
│ Welcome to PowOS!                                   │
│                                                     │
│ Detected USB drive: 1TB SSD                         │
│                                                     │
│ Setup HomeFS?                                       │
│                                                     │
│ [ ] Enable lazy-load home filesystem               │
│     • Work from RAM, unplug USB safely              │
│     • Auto-sync when USB reconnected                │
│                                                     │
│ Cache size: [4GB ▼]                                 │
│                                                     │
│ [Skip]  [Enable HomeFS]                             │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Automated Setup Script

```bash
#!/bin/bash
# /usr/local/bin/powos-setup-homefs

# 1. Detect USB partitions
USB_HOME=$(blkid | grep "POWOS-HOME" | cut -d: -f1)

# 2. Get UUID
UUID=$(blkid -s UUID -o value "$USB_HOME")

# 3. Generate config
cat > /etc/homefs/config.json <<EOF
{
  "sync": {
    "usb_uuid": "$UUID"
  }
}
EOF

# 4. Enable services
systemctl enable powos-homefs@${UUID}.service
systemctl enable powos-homefs-sync.service

# 5. Start now
systemctl start powos-homefs@${UUID}.service

echo "HomeFS enabled! Safe to unplug USB when status shows ready."
```

## Testing Integration

### Test Scenarios

1. **Boot with USB**
   - HomeFS mounts
   - Metadata loads to RAM
   - Files accessible

2. **Unplug USB**
   - Filesystem stays online
   - Cached files work
   - New files go to journal

3. **Reconnect USB**
   - Auto-detected by udev
   - Sync starts automatically
   - Conflicts resolved

4. **RAM pressure**
   - Cache evicts old files
   - Dirty files preserved
   - Performance degrades gracefully

5. **Crash recovery**
   - Journal replays on boot
   - Pending writes recovered
   - No data loss

### Integration Test Script

```bash
#!/bin/bash
# test/integration/test-homefs-integration.sh

set -euo pipefail

echo "Testing HomeFS integration..."

# 1. Mount HomeFS
echo "Test 1: Mount..."
systemctl start powos-homefs@test.service
sleep 2
mountpoint -q /home || exit 1

# 2. Write test file
echo "Test 2: Write..."
echo "test" > /home/test/file.txt
homefs status | grep -q "Pending: 1" || exit 1

# 3. Force sync
echo "Test 3: Sync..."
homefs sync
sleep 1
homefs status | grep -q "Pending: 0" || exit 1

# 4. Verify USB has file
echo "Test 4: Verify..."
grep -q "test" /mnt/homefs-usb/test/file.txt || exit 1

echo "All tests passed!"
```

## Performance Optimization

### PowOS-Specific Optimizations

1. **Pre-load common files at boot**
   ```bash
   # Pre-load shell configs for fast terminal startup
   homefs pin ~/.bashrc
   homefs pin ~/.zshrc
   homefs pin ~/.config/starship.toml
   ```

2. **Exclude cache directories**
   ```bash
   # Never cache browser cache, downloads
   echo "~/.cache/**" >> /etc/homefs/exclude.txt
   echo "~/Downloads/**" >> /etc/homefs/exclude.txt
   ```

3. **Sync on shutdown**
   ```bash
   # Ensure clean shutdown syncs everything
   # In /etc/systemd/system/homefs-final-sync.service
   [Unit]
   Before=shutdown.target

   [Service]
   Type=oneshot
   ExecStart=/usr/local/bin/homefs sync --wait
   ```

## Troubleshooting Integration

### HomeFS Not Mounting

```bash
# Check if overlay services completed
systemctl status powos-overlay.service

# Check if USB detected
lsblk | grep POWOS-HOME

# Check systemd service
systemctl status powos-homefs@*.service

# Check logs
journalctl -u powos-homefs -f
```

### Conflicts with Existing /home

```bash
# If /home already populated, migrate to HomeFS
# 1. Copy existing home to USB
rsync -av /home/ /mnt/homefs-usb/

# 2. Unmount old /home
umount /home

# 3. Start HomeFS
systemctl start powos-homefs@UUID.service
```

## Future Enhancements

### Tight Integration Ideas

1. **PowOS Auto-backup**
   - Snapshot home directory on each boot
   - Keep 7 daily snapshots on USB
   - BTRFS snapshots for instant rollback

2. **Cloud Sync Extension**
   - Sync to S3/Dropbox when WiFi available
   - Encrypted cloud backup
   - Multi-device sync

3. **AI-driven Preloading**
   - Learn access patterns
   - Predict needed files
   - Preload before access

4. **Distributed HomeFS**
   - Multiple USB drives
   - RAID-like redundancy
   - Faster reads from multiple sources

## Summary

HomeFS integrates into PowOS as:

- **Boot Service**: Mounts early, before user login
- **Overlay Complement**: Works with systemd-sysext overlays
- **State Tracking**: Config tracked in Git
- **Hardware Aware**: Adjusts based on Chameleon profiles
- **User Transparent**: Just works, no user intervention

This enables the core PowOS vision: **Boot on any machine, unplug your USB, work from RAM, plug back in to sync.**

---

**Integration Status:** Designed, Implementation Complete
**Next Steps:** Integration testing, Performance tuning
