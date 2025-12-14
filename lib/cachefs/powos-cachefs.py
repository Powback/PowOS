#!/usr/bin/env python3
"""
PowOS CacheFS - Lazy-loading FUSE filesystem with RAM caching

Architecture:
- Metadata (file names, sizes, perms) always in RAM
- File contents lazy-loaded on first access
- LRU cache evicts least-recently-used files when full
- Works offline (USB unplugged) for cached files
- Syncs writes back to USB when connected

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
from pathlib import Path
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Optional, Dict, Set
import logging

try:
    from fuse import FUSE, FuseOSError, Operations
except ImportError:
    print("ERROR: fusepy not installed. Run: pip install fusepy")
    sys.exit(1)

logging.basicConfig(level=logging.INFO, format='[cachefs] %(message)s')
log = logging.getLogger(__name__)


def parse_size(size_str: str) -> int:
    """Parse human-readable size like '4G' to bytes."""
    size_str = size_str.upper().strip()
    multipliers = {'K': 1024, 'M': 1024**2, 'G': 1024**3, 'T': 1024**4}
    if size_str[-1] in multipliers:
        return int(float(size_str[:-1]) * multipliers[size_str[-1]])
    return int(size_str)


@dataclass
class CachedFile:
    """Represents a cached file."""
    path: str  # Relative path from root
    size: int
    cached_at: float
    last_access: float
    dirty: bool = False  # Has unsaved changes

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

            # Evict until we have space
            while self.current_size + size > self.max_size and self.items:
                self._evict_one()

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

    def _evict_one(self):
        """Evict least recently used item."""
        if not self.items:
            return

        # Get oldest (first in OrderedDict)
        rel_path, item = next(iter(self.items.items()))

        # Don't evict dirty files
        if item.dirty:
            # Move to end and try next
            self.items.move_to_end(rel_path)
            # Find first non-dirty
            for path, itm in list(self.items.items()):
                if not itm.dirty:
                    rel_path, item = path, itm
                    break
            else:
                log.warning("All cached files are dirty, cannot evict")
                return

        # Remove from cache
        cache_path = self._cache_path(rel_path)
        if cache_path.exists():
            cache_path.unlink()

        self.current_size -= item.size
        del self.items[rel_path]
        log.info(f"Evicted: {rel_path}")

    def mark_dirty(self, rel_path: str):
        """Mark file as having unsaved changes."""
        with self.lock:
            if rel_path in self.items:
                self.items[rel_path].dirty = True

    def mark_clean(self, rel_path: str):
        """Mark file as synced."""
        with self.lock:
            if rel_path in self.items:
                self.items[rel_path].dirty = False

    def get_dirty_files(self) -> list:
        """Get list of files with unsaved changes."""
        with self.lock:
            return [item.path for item in self.items.values() if item.dirty]

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
                dirty=True
            )
            return cache_path

    def update_size(self, rel_path: str, new_size: int):
        """Update tracked size after write."""
        with self.lock:
            if rel_path in self.items:
                old_size = self.items[rel_path].size
                self.items[rel_path].size = new_size
                self.current_size += (new_size - old_size)


class PowOSCacheFS(Operations):
    """
    FUSE filesystem that lazy-loads from USB with RAM caching.
    """

    def __init__(self, backing_path: str, cache_dir: str, cache_size: int):
        self.backing_path = Path(backing_path)
        self.cache = LRUCache(cache_dir, cache_size)
        self.metadata: Dict[str, FileMetadata] = {}
        self.metadata_lock = threading.RLock()
        self.usb_connected = True
        self.open_files: Dict[int, tuple] = {}  # fd -> (rel_path, cache_path, file_handle)
        self.fd_counter = 0
        self.fd_lock = threading.Lock()

        # Scan backing store for initial metadata
        self._scan_metadata()

        log.info(f"CacheFS initialized")
        log.info(f"  Backing: {backing_path}")
        log.info(f"  Cache: {cache_dir} ({cache_size // (1024**3)}GB)")
        log.info(f"  Files indexed: {len(self.metadata)}")

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
        """Write to cached file (mark dirty for sync)."""
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
        """Close file."""
        if fh in self.open_files:
            rel_path, cache_path, real_fh = self.open_files[fh]
            os.close(real_fh)
            del self.open_files[fh]
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
        # (implementation detail - would need cache.remove())

        if self.usb_connected:
            full_path = self._full_path(path)
            if full_path.exists():
                full_path.unlink()
        return 0

    def rename(self, old, new):
        """Rename file/directory."""
        with self.metadata_lock:
            if old not in self.metadata:
                raise FuseOSError(errno.ENOENT)
            self.metadata[new] = self.metadata.pop(old)

        if self.usb_connected:
            old_full = self._full_path(old)
            new_full = self._full_path(new)
            if old_full.exists():
                old_full.rename(new_full)
        return 0

    def chmod(self, path, mode):
        with self.metadata_lock:
            if path in self.metadata:
                self.metadata[path].mode = mode
        return 0

    def chown(self, path, uid, gid):
        with self.metadata_lock:
            if path in self.metadata:
                self.metadata[path].uid = uid
                self.metadata[path].gid = gid
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
        # Return backing store stats if available
        if self.usb_connected:
            st = os.statvfs(str(self.backing_path))
            return {
                'f_bsize': st.f_bsize,
                'f_blocks': st.f_blocks,
                'f_bfree': st.f_bfree,
                'f_bavail': st.f_bavail,
                'f_files': st.f_files,
                'f_ffree': st.f_ffree,
            }
        else:
            # Fake stats when offline
            return {
                'f_bsize': 4096,
                'f_blocks': 1000000,
                'f_bfree': 500000,
                'f_bavail': 500000,
            }

    # === USB Connection Management ===

    def set_usb_connected(self, connected: bool):
        """Update USB connection state."""
        old_state = self.usb_connected
        self.usb_connected = connected

        if connected and not old_state:
            log.info("USB reconnected - syncing dirty files...")
            self.sync_to_backing()
        elif not connected and old_state:
            log.warning("USB disconnected - running in offline mode")

    def sync_to_backing(self):
        """Sync dirty cached files back to USB."""
        if not self.usb_connected:
            log.warning("Cannot sync - USB not connected")
            return

        dirty_files = self.cache.get_dirty_files()
        log.info(f"Syncing {len(dirty_files)} dirty files to USB...")

        for rel_path in dirty_files:
            cache_path = self.cache.get_path(rel_path)
            if cache_path and cache_path.exists():
                full_path = self._full_path(rel_path)
                full_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(cache_path, full_path)
                self.cache.mark_clean(rel_path)
                log.info(f"  Synced: {rel_path}")

        log.info("Sync complete")


def main():
    import argparse

    parser = argparse.ArgumentParser(description='PowOS CacheFS - Lazy-loading FUSE filesystem')
    parser.add_argument('backing', help='Backing store path (USB mount)')
    parser.add_argument('mountpoint', help='Where to mount the cached filesystem')
    parser.add_argument('--cache-dir', default='/run/powos/cachefs',
                        help='Directory for cache files (default: /run/powos/cachefs)')
    parser.add_argument('--cache-size', default='4G',
                        help='Maximum cache size (default: 4G)')
    parser.add_argument('--foreground', '-f', action='store_true',
                        help='Run in foreground')
    parser.add_argument('--debug', '-d', action='store_true',
                        help='Enable debug logging')

    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    cache_size = parse_size(args.cache_size)

    log.info(f"Starting PowOS CacheFS")
    log.info(f"  Backing store: {args.backing}")
    log.info(f"  Mount point: {args.mountpoint}")
    log.info(f"  Cache directory: {args.cache_dir}")
    log.info(f"  Cache size: {args.cache_size} ({cache_size} bytes)")

    # Create mount point if needed
    Path(args.mountpoint).mkdir(parents=True, exist_ok=True)

    # Create and run filesystem
    fs = PowOSCacheFS(args.backing, args.cache_dir, cache_size)

    FUSE(fs, args.mountpoint,
         foreground=args.foreground,
         allow_other=True,
         nothreads=False)


if __name__ == '__main__':
    main()
