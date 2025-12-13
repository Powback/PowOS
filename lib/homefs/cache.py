"""
Cache Manager for HomeFS

Implements LRU cache with intelligent eviction, pinning support,
and RAM pressure handling.
"""

import logging
import os
import time
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import psutil

logger = logging.getLogger(__name__)


@dataclass
class CacheEntry:
    """Represents a cached file entry."""

    path: str
    inode: int
    size: int
    content: Optional[bytes]
    atime: float  # Last access time
    mtime: float  # Modification time
    dirty: bool  # Has pending writes
    pinned: bool  # Protected from eviction
    refcount: int  # Open file handles
    is_streaming: bool  # Large file, use chunks
    chunks: dict = None  # For streaming files: offset -> bytes

    def __post_init__(self):
        if self.chunks is None:
            self.chunks = {}


@dataclass
class InodeMetadata:
    """File metadata (always kept in RAM)."""

    inode: int
    mode: int
    uid: int
    gid: int
    size: int
    atime: float
    mtime: float
    ctime: float
    nlink: int = 1


@dataclass
class DirectoryEntry:
    """Directory entry metadata."""

    name: str
    inode: int
    type: str  # 'file', 'dir', 'symlink'


class CacheManager:
    """
    Manages file content cache with LRU eviction.

    Features:
    - LRU eviction when cache is full
    - File pinning to prevent eviction
    - RAM pressure monitoring
    - Large file streaming (chunked)
    - Metadata always cached
    """

    def __init__(self, config: dict):
        """
        Initialize cache manager.

        Args:
            config: Configuration dict with keys:
                - max_size: Maximum cache size in bytes
                - metadata_size: Metadata cache size in bytes
                - large_file_threshold: Size threshold for streaming
                - chunk_size: Chunk size for streaming files
                - low_threshold: RAM pressure low threshold (0.0-1.0)
                - critical_threshold: RAM pressure critical threshold
        """
        self.max_size = config.get("max_size", 4 * 1024**3)  # 4GB default
        self.metadata_size = config.get("metadata_size", 100 * 1024**2)  # 100MB
        self.large_file_threshold = config.get("large_file_threshold", 100 * 1024**2)
        self.chunk_size = config.get("chunk_size", 4 * 1024**2)
        self.low_threshold = config.get("low_threshold", 0.8)
        self.critical_threshold = config.get("critical_threshold", 0.9)

        # Cache storage
        self.entries: OrderedDict[str, CacheEntry] = OrderedDict()
        self.inodes: dict[int, InodeMetadata] = {}
        self.dirs: dict[str, list[DirectoryEntry]] = {}

        # Cache statistics
        self.total_size = 0
        self.hits = 0
        self.misses = 0
        self.evictions = 0

        # Inode counter
        self.next_inode = 1

        logger.info(
            f"Cache initialized: max_size={self.max_size / 1024**3:.2f}GB, "
            f"large_file_threshold={self.large_file_threshold / 1024**2:.2f}MB"
        )

    def get_inode(self, path: str) -> Optional[int]:
        """Get inode number for path."""
        for inode, meta in self.inodes.items():
            # We need to maintain a path -> inode mapping separately
            # This is a simplified version
            pass
        return None

    def allocate_inode(self) -> int:
        """Allocate a new inode number."""
        inode = self.next_inode
        self.next_inode += 1
        return inode

    def add_metadata(self, path: str, metadata: InodeMetadata) -> None:
        """Add file metadata to cache."""
        self.inodes[metadata.inode] = metadata
        logger.debug(f"Added metadata for {path}: inode={metadata.inode}")

    def get_metadata(self, inode: int) -> Optional[InodeMetadata]:
        """Get file metadata by inode."""
        return self.inodes.get(inode)

    def add_directory(self, path: str, entries: list[DirectoryEntry]) -> None:
        """Add directory listing to cache."""
        self.dirs[path] = entries
        logger.debug(f"Cached directory {path} with {len(entries)} entries")

    def get_directory(self, path: str) -> Optional[list[DirectoryEntry]]:
        """Get cached directory listing."""
        return self.dirs.get(path)

    def get(self, path: str) -> Optional[CacheEntry]:
        """
        Get file from cache.

        Updates access time and moves to end of LRU list.
        """
        if path in self.entries:
            self.hits += 1
            entry = self.entries[path]
            entry.atime = time.time()

            # Move to end (most recently used)
            self.entries.move_to_end(path)

            logger.debug(f"Cache hit: {path}")
            return entry
        else:
            self.misses += 1
            logger.debug(f"Cache miss: {path}")
            return None

    def put(self, path: str, entry: CacheEntry) -> None:
        """
        Add file to cache.

        May trigger eviction if cache is full.
        """
        # Check if file should be streamed
        if entry.size > self.large_file_threshold and not entry.is_streaming:
            logger.info(f"Large file {path} ({entry.size / 1024**2:.2f}MB), enabling streaming")
            entry.is_streaming = True
            entry.content = None  # Don't cache full content

        # Calculate size to add
        size_to_add = entry.size if entry.content else 0

        # Evict if necessary
        while self.total_size + size_to_add > self.max_size:
            if not self._evict_one():
                logger.warning("Cannot evict more entries, cache may exceed limit")
                break

        # Add to cache
        if path in self.entries:
            # Update existing entry
            old_size = self.entries[path].size if self.entries[path].content else 0
            self.total_size -= old_size

        self.entries[path] = entry
        self.total_size += size_to_add
        self.entries.move_to_end(path)

        logger.debug(f"Cached {path}: size={size_to_add / 1024:.2f}KB, total={self.total_size / 1024**2:.2f}MB")

    def pin(self, path: str) -> bool:
        """Pin a file to prevent eviction."""
        if path in self.entries:
            self.entries[path].pinned = True
            logger.info(f"Pinned {path}")
            return True
        return False

    def unpin(self, path: str) -> bool:
        """Unpin a file."""
        if path in self.entries:
            self.entries[path].pinned = False
            logger.info(f"Unpinned {path}")
            return True
        return False

    def is_pinned(self, path: str) -> bool:
        """Check if file is pinned."""
        if path in self.entries:
            return self.entries[path].pinned
        return False

    def mark_dirty(self, path: str) -> None:
        """Mark file as modified (pending write)."""
        if path in self.entries:
            self.entries[path].dirty = True
            self.entries[path].mtime = time.time()

    def mark_clean(self, path: str) -> None:
        """Mark file as synced."""
        if path in self.entries:
            self.entries[path].dirty = False

    def get_dirty_files(self) -> list[str]:
        """Get list of files with pending writes."""
        return [path for path, entry in self.entries.items() if entry.dirty]

    def increment_refcount(self, path: str) -> None:
        """Increment open file handle count."""
        if path in self.entries:
            self.entries[path].refcount += 1

    def decrement_refcount(self, path: str) -> None:
        """Decrement open file handle count."""
        if path in self.entries:
            self.entries[path].refcount = max(0, self.entries[path].refcount - 1)

    def remove(self, path: str) -> None:
        """Remove file from cache."""
        if path in self.entries:
            entry = self.entries[path]
            if entry.content:
                self.total_size -= entry.size
            del self.entries[path]
            logger.debug(f"Removed {path} from cache")

    def clear(self, keep_dirty: bool = True, keep_pinned: bool = True) -> int:
        """
        Clear cache entries.

        Args:
            keep_dirty: Keep files with pending writes
            keep_pinned: Keep pinned files

        Returns:
            Number of entries cleared
        """
        cleared = 0
        to_remove = []

        for path, entry in self.entries.items():
            if keep_dirty and entry.dirty:
                continue
            if keep_pinned and entry.pinned:
                continue
            if entry.refcount > 0:
                continue

            to_remove.append(path)

        for path in to_remove:
            self.remove(path)
            cleared += 1

        logger.info(f"Cleared {cleared} cache entries")
        return cleared

    def _evict_one(self) -> bool:
        """
        Evict one entry from cache using LRU policy.

        Returns:
            True if an entry was evicted, False otherwise
        """
        # Find eviction candidate (first non-protected entry)
        for path, entry in self.entries.items():
            if self._can_evict(entry):
                logger.debug(
                    f"Evicting {path}: size={entry.size / 1024:.2f}KB, "
                    f"atime={time.time() - entry.atime:.1f}s ago"
                )
                self.remove(path)
                self.evictions += 1
                return True

        logger.warning("No eviction candidates found")
        return False

    def _can_evict(self, entry: CacheEntry) -> bool:
        """Check if entry can be evicted."""
        if entry.pinned:
            return False
        if entry.dirty:
            return False
        if entry.refcount > 0:
            return False
        return True

    def check_ram_pressure(self) -> str:
        """
        Check system RAM pressure.

        Returns:
            "OK", "HIGH", or "CRITICAL"
        """
        mem = psutil.virtual_memory()
        percent = mem.percent / 100.0

        if percent > self.critical_threshold:
            return "CRITICAL"
        elif percent > self.low_threshold:
            return "HIGH"
        return "OK"

    def handle_ram_pressure(self) -> None:
        """Handle RAM pressure by evicting entries."""
        pressure = self.check_ram_pressure()

        if pressure == "HIGH":
            logger.warning("RAM pressure HIGH, evicting 25% of cache")
            target_size = self.max_size * 0.75
            self._evict_to_size(target_size)

        elif pressure == "CRITICAL":
            logger.error("RAM pressure CRITICAL, aggressive eviction")
            # Only keep dirty, pinned, and open files
            self.clear(keep_dirty=True, keep_pinned=True)

    def _evict_to_size(self, target_size: int) -> None:
        """Evict entries until cache is below target size."""
        while self.total_size > target_size:
            if not self._evict_one():
                break

    def get_stats(self) -> dict:
        """Get cache statistics."""
        total_entries = len(self.entries)
        cached_entries = sum(1 for e in self.entries.values() if e.content)
        dirty_entries = sum(1 for e in self.entries.values() if e.dirty)
        pinned_entries = sum(1 for e in self.entries.values() if e.pinned)

        hit_rate = self.hits / (self.hits + self.misses) if (self.hits + self.misses) > 0 else 0

        return {
            "total_size": self.total_size,
            "max_size": self.max_size,
            "usage_percent": (self.total_size / self.max_size) * 100,
            "total_entries": total_entries,
            "cached_entries": cached_entries,
            "dirty_entries": dirty_entries,
            "pinned_entries": pinned_entries,
            "hits": self.hits,
            "misses": self.misses,
            "hit_rate": hit_rate,
            "evictions": self.evictions,
            "ram_pressure": self.check_ram_pressure(),
        }

    def read_chunk(self, entry: CacheEntry, offset: int, length: int) -> bytes:
        """
        Read chunk from streaming file.

        For large files, only requested chunks are cached.
        """
        if not entry.is_streaming:
            # Small file, return from content
            if entry.content:
                return entry.content[offset:offset + length]
            return b""

        # Calculate chunk range
        chunk_start = (offset // self.chunk_size) * self.chunk_size
        chunk_end = ((offset + length - 1) // self.chunk_size + 1) * self.chunk_size

        # Collect needed chunks
        result = b""
        for chunk_offset in range(chunk_start, chunk_end, self.chunk_size):
            if chunk_offset in entry.chunks:
                chunk_data = entry.chunks[chunk_offset]
            else:
                # Chunk not cached - this will trigger a USB read
                # For now, return empty (caller should load from USB)
                logger.debug(f"Chunk {chunk_offset} not cached for {entry.path}")
                return b""

            result += chunk_data

        # Extract requested portion
        local_offset = offset - chunk_start
        return result[local_offset:local_offset + length]

    def write_chunk(self, entry: CacheEntry, offset: int, data: bytes) -> None:
        """Write chunk to streaming file."""
        if not entry.is_streaming:
            # Small file, write to content
            if entry.content is None:
                entry.content = b"\x00" * entry.size

            # Expand if needed
            if offset + len(data) > len(entry.content):
                entry.content += b"\x00" * (offset + len(data) - len(entry.content))

            # Write data
            entry.content = (
                entry.content[:offset] +
                data +
                entry.content[offset + len(data):]
            )
        else:
            # Streaming file, write to chunks
            chunk_offset = (offset // self.chunk_size) * self.chunk_size
            local_offset = offset - chunk_offset

            # Get or create chunk
            if chunk_offset not in entry.chunks:
                entry.chunks[chunk_offset] = b"\x00" * self.chunk_size

            chunk = entry.chunks[chunk_offset]

            # Write to chunk
            entry.chunks[chunk_offset] = (
                chunk[:local_offset] +
                data +
                chunk[local_offset + len(data):]
            )

        self.mark_dirty(entry.path)
