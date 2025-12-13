# HomeFS - Lazy-Load Home Filesystem for PowOS

**Status:** Prototype Implementation

HomeFS is a FUSE-based filesystem that enables PowOS to run entirely from RAM while providing transparent access to user files stored on USB. Users can unplug the USB drive after boot, work from RAM, and reconnect to sync changes back.

## Features

- **Lazy Loading**: Files loaded from USB only when accessed
- **Write Caching**: All writes go to RAM first, synced to USB later
- **Offline Operation**: Full functionality when USB is unplugged
- **LRU Eviction**: Intelligent cache management when RAM fills
- **Crash Recovery**: Write-ahead journal protects against data loss
- **Conflict Resolution**: Handles concurrent changes gracefully
- **USB Hotplug**: Automatic detection and sync on USB reconnect

## Architecture

```
┌─────────────────────────────────────────┐
│         Applications                     │
│  (vim, browser, IDE, etc.)              │
└────────────┬────────────────────────────┘
             │ FUSE
             ▼
┌─────────────────────────────────────────┐
│         HomeFS Driver                    │
│  ┌────────────────────────────────────┐ │
│  │ Cache: LRU, Pinning, Eviction     │ │
│  ├────────────────────────────────────┤ │
│  │ Journal: WAL, Recovery            │ │
│  ├────────────────────────────────────┤ │
│  │ Sync: Hotplug, Writeback          │ │
│  └────────────────────────────────────┘ │
└────────────┬────────────────────────────┘
             │
             ▼
       ┌──────────┐
       │  USB SSD │
       │ (removable)│
       └──────────┘
```

## Quick Start

### Installation

```bash
# Install dependencies
sudo dnf install -y python3-pip python3-fuse fuse

# Install Python packages
pip3 install fusepy pyudev psutil rich

# Install HomeFS
cd /projects/ML/Private/PowOS/lib/homefs
sudo python3 setup.py install

# Or use directly from source
sudo ln -s $(pwd)/cli.py /usr/local/bin/homefs
```

### Configuration

```bash
# Copy example config
sudo mkdir -p /etc/homefs
sudo cp config.example.json /etc/homefs/config.json

# Find your USB UUID
sudo blkid /dev/sdX2

# Edit config with your UUID
sudo nano /etc/homefs/config.json
# Replace "YOUR-USB-UUID-HERE" with actual UUID
```

### Mount Filesystem

```bash
# Manual mount
sudo homefs mount /dev/sdb2 /home

# Or use systemd
sudo systemctl enable powos-homefs@YOUR-UUID.service
sudo systemctl start powos-homefs@YOUR-UUID.service
```

### Check Status

```bash
# Show status
homefs status

# Output:
# HomeFS Status
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# USB:           ● Connected
# Safe to unplug: Yes
# Cache:         2.3G / 4.0G (57%)
# Pending:       None
# Last Sync:     2 minutes ago
```

## Usage

### Basic Operations

Files work exactly as normal - just read/write as usual:

```bash
# These all work transparently
echo "Hello" > /home/user/test.txt
cat /home/user/test.txt
vim /home/user/document.md
```

### Pin Important Files

Keep files in cache to prevent eviction:

```bash
# Pin a file
homefs pin /home/user/project/config.json

# List pinned files
homefs pin --list

# Unpin a file
homefs unpin /home/user/project/config.json
```

### Manual Sync

Force sync to USB:

```bash
# Sync everything
homefs sync

# Sync specific file
homefs sync /home/user/important.txt

# Dry run (show what would sync)
homefs sync --dry-run
```

### Cache Management

```bash
# Show cache contents
homefs cache list

# Show detailed statistics
homefs cache stats

# Clear cache (keeps dirty files)
homefs cache clear
```

### Conflict Resolution

If files are modified both on RAM and USB:

```bash
# List conflicts
homefs conflicts list

# Resolve conflict - keep RAM version
homefs conflicts resolve /home/user/file.txt --strategy=ram

# Resolve conflict - keep USB version
homefs conflicts resolve /home/user/file.txt --strategy=usb

# Manual merge
homefs conflicts resolve /home/user/file.txt --strategy=merge
```

## Workflow

### Boot on New Machine

1. **Boot PowOS** from USB
2. **HomeFS loads** metadata into RAM
3. **Unplug USB** (when status shows "Safe to unplug")
4. **Work normally** - files load on-demand
5. **Plug USB back in** when ready to sync
6. **Automatic sync** happens in background
7. **Wait for "Safe to unplug"** before removing USB

### Typical Session

```bash
# 1. Boot machine
# (HomeFS auto-mounts)

# 2. Check status
homefs status
# Safe to unplug: Yes

# 3. Unplug USB
# (Now running from RAM)

# 4. Work on files
vim ~/project/code.py
make build
git commit -am "Changes"

# 5. Reconnect USB when ready
# (Sync happens automatically)

# 6. Check sync status
homefs status
# Pending: 12 transactions
# Safe to unplug: No (syncing...)

# Wait a moment...
homefs status
# Pending: None
# Safe to unplug: Yes

# 7. Safe to unplug USB again
```

## Configuration

### Cache Settings

```json
"cache": {
  "max_size": "4G",           // Maximum cache size
  "metadata_size": "100M",    // Metadata cache (always in RAM)
  "large_file_threshold": "100M",  // Stream files above this
  "chunk_size": "4M",         // Chunk size for streaming
  "low_threshold": 0.8,       // RAM pressure warning
  "critical_threshold": 0.9   // RAM pressure critical
}
```

### Sync Settings

```json
"sync": {
  "usb_uuid": "abc-123...",   // Your USB UUID
  "sync_strategy": "batched", // immediate, batched, or manual
  "batch_interval": 30,       // Seconds between syncs
  "conflict_resolution": "last-write-wins",
  "backup_conflicts": true
}
```

### Strategies

**Sync Strategy:**
- `immediate`: Sync every write instantly (slow, safe)
- `batched`: Sync every N seconds (default: 30)
- `manual`: Only sync on `homefs sync` command

**Conflict Resolution:**
- `last-write-wins`: RAM version overwrites USB (default)
- `keep-both`: Save both versions with timestamps
- `merge`: Attempt 3-way merge (text files only)
- `ask`: Interactive resolution (GUI required)

## Performance

### Expected Performance

| Operation | Performance |
|-----------|-------------|
| Cached read | ~95% of native speed |
| Cached write | ~90% of native speed |
| Uncached read | ~80% of native speed |
| Directory listing | <50ms (always cached) |
| Cache eviction | <100ms |

### Tuning

**For maximum performance:**
```json
"cache": {
  "max_size": "8G",  // Use more RAM
  "large_file_threshold": "500M"  // Cache bigger files
}
```

**For low RAM machines:**
```json
"cache": {
  "max_size": "1G",  // Use less RAM
  "large_file_threshold": "50M"  // Stream earlier
}
```

**For immediate safety:**
```json
"sync": {
  "sync_strategy": "immediate",  // Sync every write
  "batch_interval": 1
}
```

## Troubleshooting

### USB Not Detected

```bash
# Check if USB is connected
lsblk

# Check UUID
sudo blkid /dev/sdX2

# Verify udev rule
cat /etc/udev/rules.d/99-homefs-usb.rules

# Reload udev
sudo udevadm control --reload-rules
```

### Sync Not Working

```bash
# Check status
homefs status

# Check logs
sudo journalctl -u powos-homefs -f

# Force sync
homefs sync

# Check USB mount
mount | grep homefs
```

### High RAM Usage

```bash
# Check cache stats
homefs cache stats

# Clear cache
homefs cache clear

# Reduce cache size in config
sudo nano /etc/homefs/config.json
# Set smaller "max_size"

# Restart
sudo systemctl restart powos-homefs
```

### File Not Found

File might not be cached yet:

```bash
# Check if USB is connected
homefs status

# Try accessing file
# (Will load from USB automatically)
cat /home/user/missing-file.txt

# If USB offline, reconnect it
```

### Journal Corruption

If journal is corrupted:

```bash
# Stop HomeFS
sudo systemctl stop powos-homefs

# Backup journal
sudo cp /var/lib/homefs/journal.wal /var/lib/homefs/journal.wal.backup

# Remove journal (will be recreated)
sudo rm /var/lib/homefs/journal.wal

# Restart
sudo systemctl start powos-homefs
```

## Development

### Project Structure

```
lib/homefs/
├── __init__.py         # Package initialization
├── homefs.py           # Main FUSE filesystem
├── cache.py            # LRU cache implementation
├── journal.py          # Write-ahead journal
├── sync.py             # USB sync manager
├── cli.py              # Command-line interface
├── config.example.json # Example configuration
└── README.md           # This file
```

### Running Tests

```bash
# Unit tests
python3 -m pytest tests/

# Integration test
sudo python3 tests/integration/test_mount.py

# Stress test
sudo python3 tests/stress/test_cache_eviction.py
```

### Development Mode

```bash
# Run directly from source
export PYTHONPATH=/projects/ML/Private/PowOS/lib
python3 -m homefs.cli mount /tmp/usb /tmp/home --cache-size=512M

# Enable debug logging
export HOMEFS_DEBUG=1
python3 -m homefs.cli mount /tmp/usb /tmp/home
```

## Security

### Disk Encryption

For encrypted USB drives:

```bash
# Use LUKS-encrypted USB
cryptsetup luksFormat /dev/sdb2
cryptsetup open /dev/sdb2 homefs-encrypted

# Mount encrypted device
homefs mount /dev/mapper/homefs-encrypted /home
```

### RAM Encryption

To protect against cold boot attacks:

```json
"security": {
  "encrypt_cache": true  // Encrypts RAM cache
}
```

**Warning:** 10-15% performance overhead.

### Secure Erase

Clear cache on shutdown:

```json
"security": {
  "secure_erase": true  // Wipes cache on unmount
}
```

## Limitations

### Current Limitations

1. **No symbolic links**: Not yet implemented
2. **No extended attributes**: Not yet implemented
3. **No inotify**: File change notifications limited
4. **Single-user**: No multi-user support yet
5. **No ACLs**: Access control lists not supported

### Future Enhancements

- Differential sync (rsync-like)
- Multi-USB support (redundancy)
- Cloud sync integration
- Compression
- Deduplication
- Snapshots
- Performance monitoring dashboard

## FAQ

**Q: What happens if I lose power with pending writes?**

A: The write-ahead journal protects you. On next boot, pending transactions are replayed from the journal.

**Q: Can I use multiple USBs?**

A: Not yet, but multi-USB support is planned.

**Q: What if my USB dies?**

A: Any pending writes in RAM will be lost when you shutdown. Make sure to sync regularly.

**Q: Does this work with encrypted USB?**

A: Yes! Just mount the decrypted LUKS device.

**Q: Can I access the same USB from multiple machines?**

A: Not simultaneously. HomeFS doesn't support concurrent access yet.

**Q: What's the overhead vs normal filesystem?**

A: ~5-10% for FUSE overhead. Cached operations are nearly native speed.

**Q: How much RAM do I need?**

A: Minimum 4GB. Recommended 8GB+ for 4GB cache.

## License

MIT License - See LICENSE file

## Contributing

Contributions welcome! See CONTRIBUTING.md

## References

- [FUSE Documentation](https://www.kernel.org/doc/html/latest/filesystems/fuse.html)
- [Write-Ahead Logging](https://en.wikipedia.org/wiki/Write-ahead_logging)
- [LRU Cache Design](https://en.wikipedia.org/wiki/Cache_replacement_policies)
- [PowOS Main Documentation](../../README.md)

---

**Version:** 0.1.0
**Status:** Prototype
**Last Updated:** 2025-12-12
