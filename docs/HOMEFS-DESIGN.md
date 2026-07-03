# HomeFS - Lazy-Load Home Filesystem for PowOS

> **⚠️ HISTORICAL / CODE REMOVED:** The `lib/homefs/` implementation this
> document describes has been **deleted** (it was never installed and did not
> work). The only implementation of this idea is `lib/cachefs/` — opt-in,
> experimental, and with **write-back to USB not implemented** (must remain
> disabled). Kept as a design document only.

## Executive Summary

HomeFS is a FUSE-based filesystem that enables PowOS to run entirely from RAM while providing transparent, on-demand access to user files stored on a USB drive. Users can unplug the USB drive after boot, work from RAM, and reconnect to sync changes back.

## Requirements

### Functional Requirements

1. **Transparent Operation**: Applications see a normal `/home` filesystem
2. **Lazy Loading**: Files loaded from USB only when accessed
3. **Write Caching**: All writes go to RAM first, synced to USB when available
4. **Offline Operation**: Full functionality when USB is unplugged
5. **Sync on Reconnect**: Automatic writeback when USB reconnected
6. **LRU Eviction**: Intelligent cache management when RAM fills
7. **Metadata Always Available**: Directory listings work offline
8. **Conflict Resolution**: Handle concurrent changes gracefully

### Non-Functional Requirements

1. **Performance**: Minimal overhead for cached reads
2. **Reliability**: No data loss on expected operations
3. **Safety**: Clear "safe to unplug" indicators
4. **Recovery**: Graceful handling of crashes and errors
5. **Security**: Optional encryption of RAM cache
6. **Efficiency**: Minimal RAM usage for metadata

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         USER SPACE                               │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Applications (vim, browser, IDE, etc.)                   │  │
│  └───────────────┬───────────────────────────────────────────┘  │
│                  │ read/write /home/user/file.txt               │
│                  ▼                                               │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              FUSE: HomeFS Driver                          │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │ VFS Layer: getattr, read, write, readdir, etc.     │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │ Cache Layer: LRU eviction, hit/miss tracking       │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │ Journal Layer: Write-ahead log, pending ops        │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │ Sync Layer: USB detection, writeback manager       │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ FUSE protocol
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         KERNEL SPACE                             │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  FUSE Kernel Module (fuse.ko)                            │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        RAM (tmpfs)                               │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Metadata Cache (always loaded)                           │  │
│  │  - Inode table                                            │  │
│  │  - Directory trees                                        │  │
│  │  - File attributes (size, mode, mtime, etc.)             │  │
│  └───────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Content Cache (LRU managed)                              │  │
│  │  - Recently accessed files                                │  │
│  │  - Pinned files (user-marked)                            │  │
│  │  - Active files (open file handles)                      │  │
│  └───────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Write Journal (WAL)                                       │  │
│  │  - Pending writes                                         │  │
│  │  - Transaction log                                        │  │
│  │  - Sync checkpoints                                       │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ lazy load / writeback
                              ▼
                    ┌─────────────────────┐
                    │     USB SSD         │
                    │   /dev/sdb2         │
                    │  (can unplug!)      │
                    │                     │
                    │  /home/user/...     │
                    └─────────────────────┘
```

## Design Decisions

### 1. Implementation Choice: FUSE Filesystem

**Chosen: FUSE with Python (fusepy/refuse)**

#### Rationale

| Option | Pros | Cons | Score |
|--------|------|------|-------|
| **FUSE Filesystem** | Full control, userspace, easy debugging, portable | FUSE overhead (~5-10%) | ✅ **BEST** |
| OverlayFS + Daemon | Kernel performance, proven tech | Can't lazy-load, limited control | ❌ |
| bcachefs/bcache | Native kernel, excellent perf | No lazy-load, complex setup | ❌ |
| NFS-like caching | Proven technology | Server overhead, network stack | ❌ |

**Why FUSE wins:**
- **Lazy loading control**: Can intercept every file access
- **Write interception**: Full control over write buffering
- **Eviction policy**: Implement custom LRU with pinning
- **Debugging**: Userspace crashes don't kernel panic
- **Portability**: Works on any Linux with FUSE support
- **Development speed**: Python prototype, Rust later if needed

#### FUSE Performance Considerations

FUSE overhead is acceptable because:
- **Metadata cached**: Directory listings are RAM-only
- **Cached reads**: Near-native speed from RAM
- **Sequential writes**: Buffered efficiently
- **Small overhead**: 5-10% for uncached reads is acceptable for portability

### 2. Cache Architecture

#### Three-Tier Cache System

```
┌──────────────────────────────────────────────────────────────┐
│ Tier 1: Metadata Cache (Always in RAM)                      │
│  - Directory structure (small, ~1-10MB)                     │
│  - File attributes (inode, size, timestamps)                │
│  - Never evicted                                            │
│  - Enables offline directory browsing                       │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ Tier 2: Hot Content Cache (LRU managed)                     │
│  - Recently accessed files                                   │
│  - Configurable size (default: 4GB)                         │
│  - LRU eviction when full                                   │
│  - Pinned files protected from eviction                     │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ Tier 3: USB Storage (Persistent)                            │
│  - Full home directory                                       │
│  - Lazy-loaded on access                                    │
│  - Written to on sync                                        │
└──────────────────────────────────────────────────────────────┘
```

#### LRU Eviction Policy

**Eviction triggers:**
- Cache size exceeds configured limit
- System RAM pressure (monitor `/proc/meminfo`)

**Eviction candidates (in order):**
1. Unmodified files (no writeback needed)
2. Least recently accessed
3. Largest files first (free more space)

**Never evict:**
- Files with open handles
- Files in write journal (pending sync)
- User-pinned files
- Metadata

#### Cache Data Structures

```python
class CacheEntry:
    path: str
    inode: int
    size: int
    content: bytes | None  # None if evicted
    atime: float  # Last access time
    mtime: float  # Modification time
    dirty: bool   # Has pending writes
    pinned: bool  # Protected from eviction
    refcount: int # Open file handles

class MetadataCache:
    inodes: dict[int, InodeMetadata]
    dirs: dict[str, DirectoryEntry]

class ContentCache:
    entries: dict[str, CacheEntry]
    lru_list: deque[str]  # Ordered by access time
    total_size: int
    max_size: int
```

### 3. Write-Ahead Journal

#### Journal Format

```
Journal File: /var/lib/homefs/journal.wal

┌─────────────────────────────────────────────────────────────┐
│ Header                                                       │
│  - Magic: 0x484F4D45 ("HOME")                               │
│  - Version: 1                                               │
│  - Checksum: CRC32                                          │
│  - Transaction count                                        │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ Transaction 1                                               │
│  - TXN ID: UUID                                             │
│  - Timestamp: Unix timestamp                                │
│  - Operation: CREATE|WRITE|DELETE|RENAME|CHMOD|...          │
│  - Path: /home/user/file.txt                                │
│  - Old Path: (for rename)                                   │
│  - Offset: (for write)                                      │
│  - Length: (for write)                                      │
│  - Data: (actual bytes for writes)                          │
│  - Checksum: CRC32 of data                                  │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ Transaction 2                                               │
│  ...                                                        │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ Sync Checkpoint                                             │
│  - Checkpoint ID: Incrementing counter                      │
│  - Timestamp: When USB was last synced                      │
│  - Last synced TXN ID                                       │
└─────────────────────────────────────────────────────────────┘
```

#### Journal Operations

**Write path:**
1. Application writes to file
2. Write intercepted by FUSE
3. Data written to RAM cache
4. Transaction appended to journal
5. `write()` returns success
6. Background thread batches journal entries

**Sync path:**
1. USB reconnected (detected by udev)
2. Journal scanner reads pending transactions
3. Transactions replayed to USB in order
4. Checkpoint written after successful sync
5. Old journal entries before checkpoint truncated

**Recovery path:**
1. System crashes with pending writes
2. On next boot, journal replayed
3. Partial transactions discarded
4. Clean shutdown checkpoint found
5. State restored

### 4. USB Hotplug Detection

#### Udev Integration

```bash
# /etc/udev/rules.d/99-homefs-usb.rules
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="<homefs-uuid>", RUN+="/usr/local/bin/homefs-usb-notify connect"
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="<homefs-uuid>", RUN+="/usr/local/bin/homefs-usb-notify disconnect"
```

#### USB States

```
┌─────────────────┐
│  USB_UNKNOWN    │  Initial state
└────────┬────────┘
         │ Boot detection
         ▼
┌─────────────────┐
│ USB_CONNECTED   │  Filesystem mounted
└────────┬────────┘
         │ User unplugs
         ▼
┌─────────────────┐
│ USB_OFFLINE     │  Working from RAM
└────────┬────────┘
         │ User reconnects
         ▼
┌─────────────────┐
│  USB_SYNCING    │  Writeback in progress
└────────┬────────┘
         │ Sync complete
         ▼
┌─────────────────┐
│ USB_CONNECTED   │  Ready for next cycle
└─────────────────┘
```

### 5. Conflict Resolution

#### Conflict Scenarios

**Scenario 1: File modified on both RAM and USB**
- Example: User boots on machine A, unplugs USB, boots on machine B with same USB, modifies file, shuts down. Then returns to machine A still running.

**Detection:**
- Track mtime of files in journal
- Compare journal mtime vs USB mtime
- If USB mtime > journal mtime: conflict

**Resolution strategies:**

1. **Last-Write-Wins (Default)**
   - RAM version overwrites USB
   - USB original saved to `.homefs-conflicts/`
   - User notified of conflict

2. **Merge (for text files)**
   - Detect text files (MIME type)
   - Run diff3-style merge
   - Mark conflicts with `<<<<<<< RAM` markers

3. **Ask User (Interactive)**
   - Show diff dialog
   - User chooses RAM, USB, or manual merge

**Implementation:**
```python
class ConflictResolver:
    def detect_conflict(self, path: str) -> bool:
        journal_mtime = self.journal.get_mtime(path)
        usb_mtime = self.usb.get_mtime(path)
        return usb_mtime > journal_mtime

    def resolve(self, path: str, strategy: str):
        if strategy == "last-write-wins":
            self.save_usb_backup(path)
            self.write_ram_to_usb(path)
        elif strategy == "merge":
            self.three_way_merge(path)
        elif strategy == "ask":
            self.interactive_resolve(path)
```

### 6. RAM Pressure Handling

#### Memory Monitoring

```python
import psutil

class MemoryMonitor:
    def __init__(self):
        self.low_threshold = 0.8   # 80% RAM usage
        self.critical_threshold = 0.9  # 90% RAM usage

    def check_pressure(self) -> str:
        mem = psutil.virtual_memory()
        if mem.percent > self.critical_threshold * 100:
            return "CRITICAL"
        elif mem.percent > self.low_threshold * 100:
            return "HIGH"
        return "OK"
```

#### Eviction Strategies

**When RAM pressure is HIGH:**
- Evict unmodified files
- Reduce cache size by 25%
- Keep metadata and dirty files

**When RAM pressure is CRITICAL:**
- Force-sync dirty files to USB if available
- Evict all non-pinned, non-open files
- Reduce cache to minimum (metadata only)
- Warn user about degraded performance

**If USB unavailable at critical pressure:**
- Spill dirty files to `/var/tmp/homefs-overflow/`
- Use disk as temporary backing store
- Restore to RAM when pressure eases

### 7. Security Considerations

#### Encrypted RAM Cache (Optional)

For laptops that may suspend-to-disk, RAM contents could leak to swap.

**Options:**

1. **Disable swap entirely** (simplest)
   - RAM-only operation
   - No encryption needed

2. **Encrypt swap** (moderate)
   - Use dm-crypt for swap partition
   - Protects against cold boot attacks

3. **Encrypt cache files** (complex)
   - Use LUKS for tmpfs
   - Key stored in TPM or user keyring
   - Overhead ~10-15%

**Recommendation:** Disable swap for PowOS (already RAM-based), making encryption unnecessary.

#### File Permissions

- HomeFS preserves exact permissions from USB
- Metadata cache stores mode, uid, gid
- Permission checks done in FUSE layer

### 8. Large File Handling

#### Streaming Strategy

Large files (>100MB) should not fully cache:

```python
class StreamingFile:
    """Represents a file that's streamed from USB, not fully cached."""

    def __init__(self, path: str, size: int):
        self.path = path
        self.size = size
        self.chunks: dict[int, bytes] = {}  # Offset -> data
        self.chunk_size = 4 * 1024 * 1024  # 4MB chunks

    def read(self, offset: int, length: int) -> bytes:
        # Read only needed chunks from USB
        chunk_start = (offset // self.chunk_size) * self.chunk_size
        chunk_end = ((offset + length) // self.chunk_size + 1) * self.chunk_size

        # Fetch chunks from USB
        for chunk_offset in range(chunk_start, chunk_end, self.chunk_size):
            if chunk_offset not in self.chunks:
                self.chunks[chunk_offset] = self.read_from_usb(chunk_offset)

        # Assemble response
        return self.assemble_chunks(offset, length)
```

**Chunk eviction:**
- Keep only active chunks in RAM
- LRU evict old chunks
- Never cache entire file

**Write handling:**
- Buffer writes in chunks
- Flush chunks to journal
- Stream to USB on sync

## Implementation Plan

### Phase 1: Core FUSE Filesystem (Week 1)

**Deliverables:**
- `homefs.py`: Basic FUSE operations (getattr, read, readdir)
- `cache.py`: Simple in-memory cache
- Mount/unmount functionality
- Read-only mode initially

**Success criteria:**
- Can mount filesystem
- Can browse directories
- Can read files
- Performance within 20% of native reads

### Phase 2: Write Support (Week 2)

**Deliverables:**
- `journal.py`: Write-ahead journal implementation
- Write operations (write, create, unlink, rename)
- Dirty file tracking

**Success criteria:**
- Can create/modify/delete files
- Writes persisted to journal
- Crash recovery works

### Phase 3: USB Sync (Week 3)

**Deliverables:**
- `sync.py`: USB detection and writeback
- Udev integration
- Conflict resolution

**Success criteria:**
- Detects USB connect/disconnect
- Syncs pending writes
- Handles conflicts gracefully

### Phase 4: Cache Management (Week 4)

**Deliverables:**
- LRU eviction
- RAM pressure handling
- File pinning

**Success criteria:**
- Cache stays within size limits
- Eviction works correctly
- System doesn't OOM

### Phase 5: User Tools & Polish (Week 5)

**Deliverables:**
- `cli.py`: User-facing commands
- Status indicators
- Systemd integration
- Documentation

**Success criteria:**
- Easy to use
- Clear status display
- Systemd auto-mount works

## Testing Strategy

### Unit Tests

- Cache eviction logic
- Journal replay
- Conflict resolution
- LRU ordering

### Integration Tests

- Full mount/unmount cycle
- USB hotplug simulation
- Crash recovery
- Large file handling

### Performance Tests

- Benchmark vs native filesystem
- RAM usage under load
- Sync performance
- Cache hit rates

### Stress Tests

- Fill cache to capacity
- Rapid USB connect/disconnect
- Concurrent file access
- Large numbers of small files

## Performance Targets

| Operation | Target | Acceptable |
|-----------|--------|------------|
| Cached read | <5% overhead | <10% overhead |
| Cached write | <10% overhead | <20% overhead |
| Uncached read (USB) | Native speed | 0.8x native |
| Directory listing | <50ms | <100ms |
| Journal replay | >1000 TXN/sec | >500 TXN/sec |
| Cache eviction | <100ms | <500ms |
| Metadata load (boot) | <2 seconds | <5 seconds |

## Failure Modes & Recovery

### Scenario 1: System Crash with Pending Writes

**Failure:**
- Power loss during operation
- Journal has uncommitted transactions

**Recovery:**
1. On next boot, detect journal file
2. Verify journal integrity (checksums)
3. Replay transactions from last checkpoint
4. Discard incomplete transactions
5. If USB available, sync immediately
6. If USB unavailable, keep journal for later

**Data loss:** None for completed writes, possible loss for in-flight writes

### Scenario 2: USB Removed During Write

**Failure:**
- User unplugs USB while sync in progress

**Recovery:**
1. Detect USB removal (udev event)
2. Mark current transaction as incomplete
3. Return filesystem to OFFLINE mode
4. Keep incomplete transaction in journal
5. Retry on next USB connect

**Data loss:** None, transaction will retry

### Scenario 3: Corrupted Journal

**Failure:**
- Journal file corrupted (disk error, bug)

**Recovery:**
1. Detect checksum failures
2. Scan for last valid checkpoint
3. Replay up to last good checkpoint
4. Discard corrupted entries
5. Log error to system journal
6. Notify user of potential data loss

**Data loss:** Transactions after last checkpoint

### Scenario 4: Out of RAM

**Failure:**
- Cache eviction can't free enough space
- System approaching OOM

**Recovery:**
1. Detect critical RAM pressure
2. Force-evict all non-essential cache
3. If USB available, sync dirty files immediately
4. If USB unavailable, spill to `/var/tmp/homefs-overflow/`
5. Continue operation with degraded performance
6. Notify user to reconnect USB

**Data loss:** None, but performance degraded

### Scenario 5: Conflicting Changes

**Failure:**
- File modified on both RAM and USB
- Cannot auto-merge

**Recovery:**
1. Detect conflict (mtime comparison)
2. Save USB version to `.homefs-conflicts/<file>.<timestamp>`
3. Write RAM version to original path
4. Create conflict report in `.homefs-conflicts/CONFLICTS.log`
5. Notify user via desktop notification

**Data loss:** None, both versions preserved

## Configuration

### homefs.conf

```ini
[cache]
# Maximum cache size (supports K, M, G suffixes)
max_size = 4G

# Metadata cache size
metadata_size = 100M

# Large file threshold (files above this are streamed)
large_file_threshold = 100M

# Chunk size for streaming
chunk_size = 4M

[eviction]
# Enable automatic eviction
enabled = true

# RAM pressure thresholds
low_threshold = 0.8
critical_threshold = 0.9

[journal]
# Journal file path
path = /var/lib/homefs/journal.wal

# Maximum journal size before compaction
max_size = 1G

# Sync batch size
batch_size = 100

[usb]
# USB device UUID
uuid = auto-detect

# Sync strategy: immediate | batched | manual
sync_strategy = batched

# Batch interval (seconds)
batch_interval = 30

[conflict]
# Resolution strategy: last-write-wins | merge | ask
resolution = last-write-wins

# Backup conflicted files
backup_conflicts = true

[security]
# Encrypt cache (requires swap encryption)
encrypt_cache = false

# Secure erase on unmount
secure_erase = false
```

## Command-Line Interface

### homefs mount

```bash
# Mount homefs at /home
sudo homefs mount /dev/sdb2 /home

# Mount with custom cache size
sudo homefs mount /dev/sdb2 /home --cache-size=8G

# Mount read-only (no writes)
sudo homefs mount /dev/sdb2 /home --read-only

# Mount without USB (offline mode)
sudo homefs mount --offline /home
```

### homefs status

```bash
# Show filesystem status
homefs status

# Output:
# HomeFS Status
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# USB:           Connected (/dev/sdb2)
# Cache:         2.3G / 4.0G (57%)
# Pending:       12 transactions
# Last Sync:     2 minutes ago
# Safe to unplug: No (syncing...)
```

### homefs sync

```bash
# Force immediate sync
homefs sync

# Sync specific file
homefs sync /home/user/important.txt

# Dry-run (show what would sync)
homefs sync --dry-run
```

### homefs pin

```bash
# Pin file (prevent eviction)
homefs pin /home/user/project/config.json

# Unpin file
homefs unpin /home/user/project/config.json

# List pinned files
homefs pin --list
```

### homefs cache

```bash
# Show cache contents
homefs cache list

# Clear cache (evict all unpinned files)
homefs cache clear

# Show cache statistics
homefs cache stats
```

### homefs conflicts

```bash
# List conflicts
homefs conflicts list

# Resolve conflict (keep RAM version)
homefs conflicts resolve /home/user/file.txt --keep=ram

# Resolve conflict (keep USB version)
homefs conflicts resolve /home/user/file.txt --keep=usb

# Resolve conflict (manual merge)
homefs conflicts resolve /home/user/file.txt --merge
```

## Future Enhancements

### Phase 6: Advanced Features (Future)

1. **Differential Sync**
   - Only sync changed blocks, not entire files
   - Use rsync algorithm
   - Faster syncs for large files

2. **Multi-USB Support**
   - Multiple backup drives
   - Auto-sync to all connected drives
   - RAID-like redundancy

3. **Cloud Sync Integration**
   - Sync to S3/Dropbox/etc. when WiFi available
   - Encrypted cloud backup
   - Multi-device sync

4. **Compression**
   - Compress cached files
   - Transparent to applications
   - Save RAM

5. **Deduplication**
   - Content-addressed storage
   - Share common chunks
   - Save RAM and USB space

6. **Snapshots**
   - Point-in-time snapshots
   - Rollback to previous state
   - Uses journal for time-travel

7. **Performance Monitoring**
   - Cache hit rate tracking
   - Slow file detection
   - Performance dashboard

8. **Predictive Preloading**
   - Learn access patterns
   - Preload likely files
   - Improve cache hit rate

## Comparison to Alternatives

### vs. NFS Client Caching

| Feature | HomeFS | NFS |
|---------|--------|-----|
| Lazy loading | ✅ Full control | ⚠️ Limited |
| Offline operation | ✅ Full support | ❌ Requires server |
| Write caching | ✅ Custom journal | ⚠️ Basic |
| LRU eviction | ✅ Custom policy | ⚠️ Kernel default |
| USB hotplug | ✅ Native | ❌ Requires remount |

### vs. OverlayFS + tmpfs

| Feature | HomeFS | OverlayFS |
|---------|--------|-----------|
| Lazy loading | ✅ On-demand | ❌ Must mount lower |
| Write caching | ✅ Custom journal | ✅ tmpfs upper |
| Offline operation | ✅ Full support | ⚠️ Lower must mount |
| LRU eviction | ✅ Custom policy | ❌ No eviction |
| File-level control | ✅ Per-file | ❌ Layer-based |

### vs. bcachefs/bcache

| Feature | HomeFS | bcachefs |
|---------|--------|----------|
| Lazy loading | ✅ Custom | ❌ Block-level cache |
| Write caching | ✅ File-aware | ✅ Block-level |
| Offline operation | ✅ Full support | ⚠️ Needs device |
| User control | ✅ Rich CLI | ⚠️ Limited |
| Stability | ⚠️ New | ✅ Kernel-native |

**Conclusion:** HomeFS offers the best balance of control, features, and usability for PowOS's specific use case.

## Glossary

- **FUSE**: Filesystem in Userspace - framework for userspace filesystems
- **LRU**: Least Recently Used - cache eviction algorithm
- **WAL**: Write-Ahead Log - journaling technique for durability
- **Lazy Loading**: Fetching data only when needed, not upfront
- **Writeback**: Delayed writing to storage (vs. write-through)
- **Eviction**: Removing items from cache to free space
- **Pinning**: Marking items to prevent eviction
- **Conflict**: When same file modified in two places
- **Checkpoint**: Point in journal where state is known good
- **Streaming**: Reading/writing in chunks, not all at once

## References

- [FUSE Documentation](https://www.kernel.org/doc/html/latest/filesystems/fuse.html)
- [fusepy Python library](https://github.com/fusepy/fusepy)
- [CacheFS design](https://www.kernel.org/doc/html/latest/filesystems/caching/fscache.html)
- [Write-Ahead Logging](https://en.wikipedia.org/wiki/Write-ahead_logging)
- [LRU Cache Algorithms](https://en.wikipedia.org/wiki/Cache_replacement_policies)

---

**Document Version:** 1.0
**Last Updated:** 2025-12-12
**Author:** Claude (PowOS Architecture Team)
**Status:** Design Complete, Ready for Implementation
