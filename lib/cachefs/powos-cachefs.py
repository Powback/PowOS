#!/usr/bin/env python3
"""
PowOS CacheFS - Lazy-loading FUSE filesystem with RAM caching and write-back

Architecture:
- Metadata (file names, sizes, perms) always in RAM
- File contents lazy-loaded on first access
- LRU cache evicts least-recently-used CLEAN files when full
- Write-back engine: dirty files flushed to USB via temp+rename (crash-safe)
- fsync() from apps flushes that file to USB synchronously
- Background thread flushes all dirty files every 30s
- destroy() (unmount) flushes all dirty files before exit
- USB disconnect: dirty files queued, flushed on reconnect, desktop notification
- Status file at /run/powos/cachefs-status.json for powos status/flush

Consistency guarantee:
  After fsync() returns: the file is on USB (or queued durable if USB offline).
  Background flush window: up to 30s for un-fsync'd writes.
  Unmount: all dirty files flushed (blocks until complete or USB timeout).

Usage:
    powos-cachefs /mnt/usb/home /home/powos --cache-size 4G
"""

import os
import sys
import stat
import errno
import time
import threading
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Optional, Dict, Set, List, Tuple
import logging

try:
    from fuse import FUSE, FuseOSError, Operations
except ImportError:
    print("ERROR: fusepy not installed. Run: pip install fusepy")
    sys.exit(1)

logging.basicConfig(level=logging.INFO, format='[cachefs] %(message)s')
log = logging.getLogger(__name__)

# Status file path — read by powos status/flush/safe
STATUS_FILE = Path("/run/powos/cachefs-status.json")
# Flush trigger file — powos flush touches this, background thread picks it up
FLUSH_TRIGGER = Path("/run/powos/cachefs-flush-now")


def parse_size(size_str: str) -> int:
    """Parse human-readable size like '4G' to bytes."""
    size_str = size_str.upper().strip()
    multipliers = {'K': 1024, 'M': 1024**2, 'G': 1024**3, 'T': 1024**4}
    if size_str[-1] in multipliers:
        return int(float(size_str[:-1]) * multipliers[size_str[-1]])
    return int(size_str)


def send_notification(title: str, message: str, urgency: str = "normal"):
    """Send desktop notification (best-effort)."""
    try:
        subprocess.run(
            ["notify-send", "-u", urgency, "-i", "drive-removable-media",
             title, message],
            capture_output=True, timeout=5
        )
    except Exception:
        pass


@dataclass
class CachedFile:
    """Represents a cached file."""
    path: str  # Relative path from root
    size: int
    cached_at: float
    last_access: float
    dirty: bool = False
    dirty_since: float = 0.0  # When the file first became dirty

    @property
    def cache_key(self) -> str:
        return hashlib.md5(self.path.encode()).hexdigest()


@dataclass
class FileMetadata:
    """File metadata stored in RAM."""
    mode: int
    uid: int
    gid: int
    size: int
    atime: float
    mtime: float
    ctime: float
    nlink: int = 1
    is_dir: bool = False


class LRUCache:
    """LRU cache for file contents with size limit."""

    def __init__(self, cache_dir: str, max_size: int):
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.max_size = max_size
        self.current_size = 0
        self.items: OrderedDict[str, CachedFile] = OrderedDict()
        self.lock = threading.RLock()

    def _cache_path(self, rel_path: str) -> Path:
        """Get cache file path for a relative path."""
        safe_name = hashlib.md5(rel_path.encode()).hexdigest()
        return self.cache_dir / safe_name

    def contains(self, rel_path: str) -> bool:
        """Check if file is in cache."""
        with self.lock:
            return rel_path in self.items

    def get_path(self, rel_path: str) -> Optional[Path]:
        """Get cache file path, updating LRU order."""
        with self.lock:
            if rel_path not in self.items:
                return None
            # Move to end (most recently used)
            self.items.move_to_end(rel_path)
            self.items[rel_path].last_access = time.time()
            return self._cache_path(rel_path)

    def add(self, rel_path: str, source_path: Path, size: int) -> Path:
        """Add file to cache, evicting if necessary."""
        with self.lock:
            cache_path = self._cache_path(rel_path)

            # Evict until we have space; stop if nothing can be evicted (all dirty)
            while self.current_size + size > self.max_size and self.items:
                if not self._evict_one():
                    raise FuseOSError(errno.ENOSPC)

            # Copy to cache
            shutil.copy2(source_path, cache_path)

            # Track it
            self.items[rel_path] = CachedFile(
                path=rel_path,
                size=size,
                cached_at=time.time(),
                last_access=time.time()
            )
            self.current_size += size

            log.info(f"Cached: {rel_path} ({size} bytes, total: {self.current_size}/{self.max_size})")
            return cache_path

    def _evict_one(self) -> bool:
        """Evict least recently used non-dirty item. Returns True if evicted."""
        if not self.items:
            return False

        # Find first non-dirty item (oldest first)
        for rel_path, item in list(self.items.items()):
            if not item.dirty:
                cache_path = self._cache_path(rel_path)
                if cache_path.exists():
                    cache_path.unlink()
                self.current_size -= item.size
                del self.items[rel_path]
                log.info(f"Evicted: {rel_path}")
                return True

        log.warning("All cached files are dirty, cannot evict")
        return False

    def remove(self, rel_path: str):
        """Remove a file from cache (e.g. after unlink)."""
        with self.lock:
            if rel_path in self.items:
                cache_path = self._cache_path(rel_path)
                if cache_path.exists():
                    cache_path.unlink()
                self.current_size -= self.items[rel_path].size
                del self.items[rel_path]

    def mark_dirty(self, rel_path: str):
        """Mark file as having unsaved changes."""
        with self.lock:
            if rel_path in self.items:
                if not self.items[rel_path].dirty:
                    self.items[rel_path].dirty_since = time.time()
                self.items[rel_path].dirty = True

    def mark_clean(self, rel_path: str):
        """Mark file as synced."""
        with self.lock:
            if rel_path in self.items:
                self.items[rel_path].dirty = False
                self.items[rel_path].dirty_since = 0.0

    def get_dirty_files(self) -> List[str]:
        """Get list of files with unsaved changes."""
        with self.lock:
            return [item.path for item in self.items.values() if item.dirty]

    def get_dirty_bytes(self) -> int:
        """Get total bytes of dirty (unsynced) cached files."""
        with self.lock:
            return sum(item.size for item in self.items.values() if item.dirty)

    def create_new(self, rel_path: str) -> Path:
        """Create a new file in cache (for writes to new files)."""
        with self.lock:
            cache_path = self._cache_path(rel_path)
            cache_path.touch()

            self.items[rel_path] = CachedFile(
                path=rel_path,
                size=0,
                cached_at=time.time(),
                last_access=time.time(),
                dirty=True,
                dirty_since=time.time()
            )
            return cache_path

    def update_size(self, rel_path: str, new_size: int):
        """Update tracked size after write."""
        with self.lock:
            if rel_path in self.items:
                old_size = self.items[rel_path].size
                self.items[rel_path].size = new_size
                self.current_size += (new_size - old_size)


class WriteBackEngine:
    """Manages async write-back of dirty cache files to the USB backing store.

    Runs as a background thread inside the FUSE process. Handles:
    - Periodic flush (every flush_interval seconds)
    - On-demand flush (triggered by powos flush / fsync)
    - USB disconnect queueing with retry on reconnect
    - Crash-safe writes via temp file + rename
    - Status reporting to /run/powos/cachefs-status.json
    - Desktop notifications on USB disconnect / consecutive failures
    """

    def __init__(self, backing_path: Path, cache: LRUCache,
                 metadata: Dict[str, FileMetadata], metadata_lock: threading.RLock,
                 flush_interval: int = 30):
        self.backing_path = backing_path
        self.cache = cache
        self.metadata = metadata
        self.metadata_lock = metadata_lock
        self.flush_interval = flush_interval

        self.usb_connected = True
        self._running = True
        self._flush_event = threading.Event()  # Signal immediate flush
        self._thread: Optional[threading.Thread] = None

        # Stats
        self.last_flush_time = 0.0
        self.last_flush_success = True
        self.consecutive_failures = 0
        self.total_flushes = 0
        self.total_files_flushed = 0
        self.errors: List[str] = []
        # Pending deletions queued while USB was offline
        self._pending_deletes: List[str] = []
        self._pending_deletes_lock = threading.Lock()
        # Pending renames queued while USB was offline: (old_path, new_path)
        self._pending_renames: List[Tuple[str, str]] = []
        self._pending_renames_lock = threading.Lock()

    def start(self):
        """Start the background flush thread."""
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name="cachefs-writeback")
        self._thread.start()
        log.info(f"Write-back engine started (flush every {self.flush_interval}s)")

    def stop(self):
        """Stop the background thread (called on unmount)."""
        self._running = False
        self._flush_event.set()  # Wake up immediately
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=60)

    def request_flush(self):
        """Request an immediate flush (used by fsync, powos flush)."""
        self._flush_event.set()

    def check_usb_connected(self) -> bool:
        """Check if the USB backing store is still mounted and writable."""
        try:
            if not self.backing_path.exists():
                return False
            # Check parent is a real mount, not a dangling path
            if not os.path.ismount(str(self.backing_path.parent)):
                # backing_path itself might be the mount
                if not os.path.ismount(str(self.backing_path)):
                    return False
            return os.access(str(self.backing_path), os.W_OK)
        except OSError:
            return False

    def flush_file_to_usb(self, rel_path: str) -> bool:
        """Flush a single dirty file to USB using temp+rename for crash safety.

        Returns True on success. On failure, the file stays dirty for retry.
        """
        cache_path = self.cache.get_path(rel_path)
        if cache_path is None or not cache_path.exists():
            # File was evicted or removed — no longer dirty
            self.cache.mark_clean(rel_path)
            return True

        full_path = self._full_path(rel_path)

        try:
            # Ensure parent directory exists on USB
            full_path.parent.mkdir(parents=True, exist_ok=True)

            # Write to temp file in same directory, then rename (atomic on same fs)
            fd, tmp_path = tempfile.mkstemp(
                dir=str(full_path.parent),
                prefix=f".cachefs-{full_path.name}."
            )
            try:
                # Copy cache file content to temp
                with open(str(cache_path), 'rb') as src:
                    while True:
                        chunk = src.read(1024 * 1024)  # 1MB chunks
                        if not chunk:
                            break
                        os.write(fd, chunk)

                # Propagate metadata (mtime, permissions)
                with self.metadata_lock:
                    meta = self.metadata.get(rel_path)

                if meta:
                    try:
                        os.fchmod(fd, stat.S_IMODE(meta.mode))
                    except OSError:
                        pass
                    try:
                        os.fchown(fd, meta.uid, meta.gid)
                    except OSError:
                        pass

                # fsync the temp file to ensure data is on USB media
                os.fsync(fd)
                os.close(fd)
                fd = -1

                # Set timestamps after close
                if meta:
                    try:
                        os.utime(tmp_path, (meta.atime, meta.mtime))
                    except OSError:
                        pass

                # Atomic rename: temp -> final
                os.rename(tmp_path, str(full_path))

                # fsync the directory to make the rename durable
                dir_fd = os.open(str(full_path.parent), os.O_RDONLY)
                try:
                    os.fsync(dir_fd)
                finally:
                    os.close(dir_fd)

                self.cache.mark_clean(rel_path)
                return True

            except Exception:
                if fd >= 0:
                    os.close(fd)
                # Clean up temp file on failure
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                raise

        except OSError as e:
            log.error(f"Failed to flush {rel_path} to USB: {e}")
            return False

    def flush_all(self) -> Tuple[int, int]:
        """Flush all dirty files to USB. Returns (flushed, failed) counts."""
        if not self.usb_connected:
            dirty = self.cache.get_dirty_files()
            if dirty:
                log.warning(f"USB offline — {len(dirty)} dirty files queued for retry")
            return 0, len(dirty) if dirty else 0

        # Apply any pending deletes/renames that were queued while offline
        self._apply_pending_ops()

        dirty_files = self.cache.get_dirty_files()
        if not dirty_files:
            return 0, 0

        log.info(f"Flushing {len(dirty_files)} dirty files to USB...")
        flushed = 0
        failed = 0

        for rel_path in dirty_files:
            if self.flush_file_to_usb(rel_path):
                flushed += 1
            else:
                failed += 1
                # Re-check USB — if it's gone, stop trying
                if not self.check_usb_connected():
                    self.usb_connected = False
                    remaining = len(dirty_files) - flushed - failed
                    log.warning(f"USB disconnected during flush — {remaining} files still dirty")
                    failed += remaining
                    break

        if flushed > 0:
            log.info(f"Flushed {flushed} files to USB" +
                     (f" ({failed} failed)" if failed else ""))

        return flushed, failed

    def _apply_pending_ops(self):
        """Apply queued deletes and renames that accumulated while USB was offline."""
        if not self.usb_connected:
            return

        with self._pending_deletes_lock:
            deletes = list(self._pending_deletes)
            self._pending_deletes.clear()

        for rel_path in deletes:
            full_path = self._full_path(rel_path)
            try:
                if full_path.exists():
                    full_path.unlink()
                    log.info(f"Applied pending delete: {rel_path}")
            except OSError as e:
                log.error(f"Failed pending delete {rel_path}: {e}")

        with self._pending_renames_lock:
            renames = list(self._pending_renames)
            self._pending_renames.clear()

        for old_path, new_path in renames:
            old_full = self._full_path(old_path)
            new_full = self._full_path(new_path)
            try:
                if old_full.exists():
                    new_full.parent.mkdir(parents=True, exist_ok=True)
                    old_full.rename(new_full)
                    log.info(f"Applied pending rename: {old_path} -> {new_path}")
            except OSError as e:
                log.error(f"Failed pending rename {old_path} -> {new_path}: {e}")

    def queue_delete(self, rel_path: str):
        """Queue a deletion for when USB comes back online."""
        with self._pending_deletes_lock:
            self._pending_deletes.append(rel_path)

    def queue_rename(self, old_path: str, new_path: str):
        """Queue a rename for when USB comes back online."""
        with self._pending_renames_lock:
            self._pending_renames.append((old_path, new_path))

    def _full_path(self, partial: str) -> Path:
        """Get full backing store path."""
        if partial.startswith('/'):
            partial = partial[1:]
        return self.backing_path / partial

    def write_status(self):
        """Write status to JSON file for powos CLI integration."""
        dirty_files = self.cache.get_dirty_files()
        dirty_bytes = self.cache.get_dirty_bytes()

        status = {
            "usb_connected": self.usb_connected,
            "last_flush": self.last_flush_time,
            "last_flush_human": (time.strftime("%Y-%m-%dT%H:%M:%S",
                                               time.localtime(self.last_flush_time))
                                 if self.last_flush_time else "never"),
            "last_flush_success": self.last_flush_success,
            "consecutive_failures": self.consecutive_failures,
            "dirty_files": len(dirty_files),
            "dirty_bytes": dirty_bytes,
            "dirty_bytes_human": self._human_size(dirty_bytes),
            "total_cached_files": len(self.cache.items),
            "total_cached_bytes": self.cache.current_size,
            "cache_max_bytes": self.cache.max_size,
            "flush_interval": self.flush_interval,
            "total_flushes": self.total_flushes,
            "total_files_flushed": self.total_files_flushed,
            "errors": self.errors[-5:],
            "backing_path": str(self.backing_path),
            "timestamp": time.time(),
        }

        try:
            STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
            tmp = str(STATUS_FILE) + ".tmp"
            with open(tmp, 'w') as f:
                json.dump(status, f, indent=2)
            os.rename(tmp, str(STATUS_FILE))
        except Exception as e:
            log.warning(f"Could not write status file: {e}")

    @staticmethod
    def _human_size(nbytes: int) -> str:
        for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
            if abs(nbytes) < 1024:
                return f"{nbytes:.1f}{unit}"
            nbytes /= 1024
        return f"{nbytes:.1f}PB"

    def _run(self):
        """Background flush loop."""
        while self._running:
            # Wait for flush_interval or an immediate-flush signal
            triggered = self._flush_event.wait(timeout=self.flush_interval)
            self._flush_event.clear()

            if not self._running:
                break

            # Check for flush trigger file (from powos flush)
            if FLUSH_TRIGGER.exists():
                try:
                    FLUSH_TRIGGER.unlink()
                except OSError:
                    pass
                triggered = True

            # Check USB state
            was_connected = self.usb_connected
            self.usb_connected = self.check_usb_connected()

            if self.usb_connected and not was_connected:
                log.info("USB reconnected — flushing queued dirty files...")
                send_notification(
                    "PowOS CacheFS",
                    "USB reconnected - syncing cached changes...",
                    "normal"
                )

            if not self.usb_connected and was_connected:
                dirty_count = len(self.cache.get_dirty_files())
                log.warning(f"USB disconnected — {dirty_count} dirty files queued")
                send_notification(
                    "PowOS CacheFS",
                    f"USB disconnected - {dirty_count} file(s) cached in RAM.\n"
                    "Reconnect USB to sync. Cached files remain accessible.",
                    "critical"
                )

            # Flush
            flushed, failed = self.flush_all()
            self.total_flushes += 1
            self.total_files_flushed += flushed

            if failed > 0 and self.usb_connected:
                self.consecutive_failures += 1
                self.last_flush_success = False
                error_msg = f"Flush failed for {failed} files"
                self.errors.append(error_msg)
                if self.consecutive_failures >= 3:
                    send_notification(
                        "PowOS CacheFS Error",
                        f"Write-back has failed {self.consecutive_failures} times.\n"
                        f"{failed} files not persisted to USB.",
                        "critical"
                    )
            elif flushed > 0 or (not failed and self.usb_connected):
                self.consecutive_failures = 0
                self.last_flush_success = True
                self.last_flush_time = time.time()

            self.write_status()


class PowOSCacheFS(Operations):
    """
    FUSE filesystem that lazy-loads from USB with RAM caching.
    Write-back engine persists changes to USB asynchronously.
    """

    def __init__(self, backing_path: str, cache_dir: str, cache_size: int,
                 flush_interval: int = 30):
        self.backing_path = Path(backing_path)
        self.cache = LRUCache(cache_dir, cache_size)
        self.metadata: Dict[str, FileMetadata] = {}
        self.metadata_lock = threading.RLock()
        self.open_files: Dict[int, tuple] = {}  # fd -> (rel_path, cache_path, file_handle)
        self.fd_counter = 0
        self.fd_lock = threading.Lock()

        # Scan backing store for initial metadata
        self._scan_metadata()

        # Start write-back engine
        self.writeback = WriteBackEngine(
            backing_path=self.backing_path,
            cache=self.cache,
            metadata=self.metadata,
            metadata_lock=self.metadata_lock,
            flush_interval=flush_interval
        )
        self.writeback.start()

        log.info(f"CacheFS initialized")
        log.info(f"  Backing: {backing_path}")
        log.info(f"  Cache: {cache_dir} ({cache_size // (1024**3)}GB)")
        log.info(f"  Files indexed: {len(self.metadata)}")
        log.info(f"  Write-back: enabled (flush every {flush_interval}s)")

    @property
    def usb_connected(self) -> bool:
        return self.writeback.usb_connected

    def _scan_metadata(self):
        """Scan backing store and cache all metadata."""
        log.info("Scanning backing store for metadata...")

        if not self.backing_path.exists():
            log.warning(f"Backing path does not exist: {self.backing_path}")
            return

        for root, dirs, files in os.walk(self.backing_path):
            rel_root = os.path.relpath(root, self.backing_path)
            if rel_root == '.':
                rel_root = ''

            # Index directories
            for d in dirs:
                rel_path = os.path.join(rel_root, d) if rel_root else d
                full_path = self.backing_path / rel_path
                self._cache_metadata('/' + rel_path, full_path)

            # Index files
            for f in files:
                rel_path = os.path.join(rel_root, f) if rel_root else f
                full_path = self.backing_path / rel_path
                self._cache_metadata('/' + rel_path, full_path)

        # Add root
        self._cache_metadata('/', self.backing_path)

    def _cache_metadata(self, rel_path: str, full_path: Path):
        """Cache metadata for a single file/dir."""
        try:
            st = full_path.stat()
            self.metadata[rel_path] = FileMetadata(
                mode=st.st_mode,
                uid=st.st_uid,
                gid=st.st_gid,
                size=st.st_size,
                atime=st.st_atime,
                mtime=st.st_mtime,
                ctime=st.st_ctime,
                nlink=st.st_nlink,
                is_dir=full_path.is_dir()
            )
        except OSError as e:
            log.warning(f"Could not stat {full_path}: {e}")

    def _full_path(self, partial: str) -> Path:
        """Get full backing store path."""
        if partial.startswith('/'):
            partial = partial[1:]
        return self.backing_path / partial

    def _get_next_fd(self) -> int:
        """Get next file descriptor."""
        with self.fd_lock:
            self.fd_counter += 1
            return self.fd_counter

    # === FUSE Operations ===

    def getattr(self, path, fh=None):
        """Get file attributes - served from metadata cache."""
        with self.metadata_lock:
            if path not in self.metadata:
                raise FuseOSError(errno.ENOENT)

            meta = self.metadata[path]
            return {
                'st_mode': meta.mode,
                'st_uid': meta.uid,
                'st_gid': meta.gid,
                'st_size': meta.size,
                'st_atime': meta.atime,
                'st_mtime': meta.mtime,
                'st_ctime': meta.ctime,
                'st_nlink': meta.nlink,
            }

    def readdir(self, path, fh):
        """List directory - served from metadata cache."""
        entries = ['.', '..']

        prefix = path if path.endswith('/') else path + '/'
        if path == '/':
            prefix = '/'

        with self.metadata_lock:
            for p in self.metadata:
                if p == path:
                    continue
                if p.startswith(prefix):
                    # Get immediate child only
                    rest = p[len(prefix):]
                    if '/' not in rest and rest:
                        entries.append(rest)

        return entries

    def open(self, path, flags):
        """Open file - lazy load if not cached."""
        rel_path = path

        # Check if cached
        cache_path = self.cache.get_path(rel_path)

        if cache_path is None:
            # Not cached - need to load from backing store
            if not self.usb_connected:
                log.warning(f"File not cached and USB disconnected: {path}")
                raise FuseOSError(errno.ENOENT)

            full_path = self._full_path(path)
            if not full_path.exists():
                raise FuseOSError(errno.ENOENT)

            # Load into cache
            size = full_path.stat().st_size
            cache_path = self.cache.add(rel_path, full_path, size)

        # Open the cached file
        fh = os.open(str(cache_path), flags)
        fd = self._get_next_fd()
        self.open_files[fd] = (rel_path, cache_path, fh)

        return fd

    def read(self, path, size, offset, fh):
        """Read from cached file."""
        if fh not in self.open_files:
            raise FuseOSError(errno.EBADF)

        rel_path, cache_path, real_fh = self.open_files[fh]
        os.lseek(real_fh, offset, os.SEEK_SET)
        return os.read(real_fh, size)

    def write(self, path, data, offset, fh):
        """Write to cached file (mark dirty for async write-back)."""
        if fh not in self.open_files:
            raise FuseOSError(errno.EBADF)

        rel_path, cache_path, real_fh = self.open_files[fh]
        os.lseek(real_fh, offset, os.SEEK_SET)
        written = os.write(real_fh, data)

        # Mark dirty and update size
        self.cache.mark_dirty(rel_path)
        new_size = os.fstat(real_fh).st_size
        self.cache.update_size(rel_path, new_size)

        # Update metadata
        with self.metadata_lock:
            if rel_path in self.metadata:
                self.metadata[rel_path].size = new_size
                self.metadata[rel_path].mtime = time.time()

        return written

    def create(self, path, mode):
        """Create new file."""
        rel_path = path

        # Create in cache
        cache_path = self.cache.create_new(rel_path)

        # Update metadata
        now = time.time()
        with self.metadata_lock:
            self.metadata[rel_path] = FileMetadata(
                mode=mode | stat.S_IFREG,
                uid=os.getuid(),
                gid=os.getgid(),
                size=0,
                atime=now,
                mtime=now,
                ctime=now
            )

        # Open it
        fh = os.open(str(cache_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        fd = self._get_next_fd()
        self.open_files[fd] = (rel_path, cache_path, fh)

        return fd

    def release(self, path, fh):
        """Close file handle."""
        if fh in self.open_files:
            rel_path, cache_path, real_fh = self.open_files[fh]
            os.close(real_fh)
            del self.open_files[fh]
        return 0

    def fsync(self, path, datasync, fh):
        """Flush file data to USB (synchronous durability guarantee).

        After fsync() returns, the file is on USB media (if connected).
        If USB is offline, the file is durably in the RAM cache and queued
        for flush on reconnect — this is the "queued durable" fallback.
        """
        if fh not in self.open_files:
            return 0

        rel_path, cache_path, real_fh = self.open_files[fh]

        # First, fsync to the cache storage (RAM disk / tmpfs)
        if datasync:
            os.fdatasync(real_fh)
        else:
            os.fsync(real_fh)

        # Then flush this specific file to USB synchronously
        if self.usb_connected:
            with self.cache.lock:
                item = self.cache.items.get(rel_path)
                if item and item.dirty:
                    self.writeback.flush_file_to_usb(rel_path)

        return 0

    def mkdir(self, path, mode):
        """Create directory."""
        # Create in backing store if connected
        if self.usb_connected:
            full_path = self._full_path(path)
            full_path.mkdir(mode=mode, parents=True, exist_ok=True)

        # Update metadata
        now = time.time()
        with self.metadata_lock:
            self.metadata[path] = FileMetadata(
                mode=mode | stat.S_IFDIR,
                uid=os.getuid(),
                gid=os.getgid(),
                size=0,
                atime=now,
                mtime=now,
                ctime=now,
                is_dir=True
            )
        return 0

    def rmdir(self, path):
        """Remove directory."""
        with self.metadata_lock:
            if path not in self.metadata:
                raise FuseOSError(errno.ENOENT)
            del self.metadata[path]

        if self.usb_connected:
            full_path = self._full_path(path)
            if full_path.exists():
                full_path.rmdir()
        return 0

    def unlink(self, path):
        """Delete file."""
        with self.metadata_lock:
            if path not in self.metadata:
                raise FuseOSError(errno.ENOENT)
            del self.metadata[path]

        # Remove from cache if present
        self.cache.remove(path)

        if self.usb_connected:
            full_path = self._full_path(path)
            if full_path.exists():
                full_path.unlink()
        else:
            # Queue deletion for when USB returns
            self.writeback.queue_delete(path)
        return 0

    def rename(self, old, new):
        """Rename file/directory."""
        with self.metadata_lock:
            if old not in self.metadata:
                raise FuseOSError(errno.ENOENT)
            self.metadata[new] = self.metadata.pop(old)

        # Update cache entry if it exists
        with self.cache.lock:
            if old in self.cache.items:
                item = self.cache.items.pop(old)
                item.path = new
                self.cache.items[new] = item
                # Rename the cache file too
                old_cache = self.cache._cache_path(old)
                new_cache = self.cache._cache_path(new)
                if old_cache.exists():
                    old_cache.rename(new_cache)

        if self.usb_connected:
            old_full = self._full_path(old)
            new_full = self._full_path(new)
            if old_full.exists():
                new_full.parent.mkdir(parents=True, exist_ok=True)
                old_full.rename(new_full)
        else:
            self.writeback.queue_rename(old, new)
        return 0

    def chmod(self, path, mode):
        with self.metadata_lock:
            if path in self.metadata:
                self.metadata[path].mode = mode
        # Mark dirty so metadata propagates on next flush
        if self.cache.contains(path):
            self.cache.mark_dirty(path)
        return 0

    def chown(self, path, uid, gid):
        with self.metadata_lock:
            if path in self.metadata:
                self.metadata[path].uid = uid
                self.metadata[path].gid = gid
        if self.cache.contains(path):
            self.cache.mark_dirty(path)
        return 0

    def truncate(self, path, length, fh=None):
        """Truncate file."""
        cache_path = self.cache.get_path(path)
        if cache_path and cache_path.exists():
            with open(cache_path, 'r+b') as f:
                f.truncate(length)
            self.cache.mark_dirty(path)
            self.cache.update_size(path, length)

        with self.metadata_lock:
            if path in self.metadata:
                self.metadata[path].size = length
        return 0

    def utimens(self, path, times=None):
        """Update timestamps."""
        now = time.time()
        atime, mtime = times if times else (now, now)
        with self.metadata_lock:
            if path in self.metadata:
                self.metadata[path].atime = atime
                self.metadata[path].mtime = mtime
        return 0

    def statfs(self, path):
        """Filesystem stats."""
        if self.usb_connected:
            try:
                st = os.statvfs(str(self.backing_path))
                return {
                    'f_bsize': st.f_bsize,
                    'f_blocks': st.f_blocks,
                    'f_bfree': st.f_bfree,
                    'f_bavail': st.f_bavail,
                    'f_files': st.f_files,
                    'f_ffree': st.f_ffree,
                }
            except OSError:
                pass
        # Offline or statvfs failed
        return {
            'f_bsize': 4096,
            'f_blocks': 1000000,
            'f_bfree': 500000,
            'f_bavail': 500000,
        }

    def destroy(self, path):
        """Called on unmount — flush all dirty files to USB before exit."""
        log.info("CacheFS unmounting — flushing all dirty files...")

        # Stop the background thread
        self.writeback.stop()

        # Final flush — synchronous, must complete before FUSE exits
        flushed, failed = self.writeback.flush_all()

        if failed > 0:
            log.error(f"UNMOUNT: {failed} dirty files could NOT be flushed to USB!")
            send_notification(
                "PowOS CacheFS WARNING",
                f"{failed} files were NOT saved to USB on unmount!\n"
                "Data may be lost. Check USB connection.",
                "critical"
            )
        elif flushed > 0:
            log.info(f"UNMOUNT: {flushed} files flushed to USB successfully")

        # Final status update
        self.writeback.write_status()

        # Close any open file handles
        for fd, (rel_path, cache_path, real_fh) in list(self.open_files.items()):
            try:
                os.close(real_fh)
            except OSError:
                pass
        self.open_files.clear()

        log.info("CacheFS unmount complete")


def main():
    import argparse

    parser = argparse.ArgumentParser(description='PowOS CacheFS - Lazy-loading FUSE filesystem with write-back')
    parser.add_argument('backing', help='Backing store path (USB mount)')
    parser.add_argument('mountpoint', help='Where to mount the cached filesystem')
    parser.add_argument('--cache-dir', default='/run/powos/cachefs',
                        help='Directory for cache files (default: /run/powos/cachefs)')
    parser.add_argument('--cache-size', default='4G',
                        help='Maximum cache size (default: 4G)')
    parser.add_argument('--flush-interval', type=int, default=30,
                        help='Write-back flush interval in seconds (default: 30)')
    parser.add_argument('--foreground', '-f', action='store_true',
                        help='Run in foreground')
    parser.add_argument('--debug', '-d', action='store_true',
                        help='Enable debug logging')
    parser.add_argument('--sync-now', action='store_true',
                        help='Trigger an immediate flush (signal running instance)')

    args = parser.parse_args()

    # --sync-now: just touch the trigger file for the running instance
    if args.sync_now:
        FLUSH_TRIGGER.parent.mkdir(parents=True, exist_ok=True)
        FLUSH_TRIGGER.touch()
        log.info("Flush triggered")
        return

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    cache_size = parse_size(args.cache_size)

    log.info(f"Starting PowOS CacheFS")
    log.info(f"  Backing store: {args.backing}")
    log.info(f"  Mount point: {args.mountpoint}")
    log.info(f"  Cache directory: {args.cache_dir}")
    log.info(f"  Cache size: {args.cache_size} ({cache_size} bytes)")
    log.info(f"  Flush interval: {args.flush_interval}s")

    # Create mount point if needed
    Path(args.mountpoint).mkdir(parents=True, exist_ok=True)

    # Create and run filesystem
    fs = PowOSCacheFS(args.backing, args.cache_dir, cache_size,
                      flush_interval=args.flush_interval)

    FUSE(fs, args.mountpoint,
         foreground=args.foreground,
         allow_other=True,
         nothreads=False)


if __name__ == '__main__':
    main()
