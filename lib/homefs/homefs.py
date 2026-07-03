"""
HomeFS - FUSE Filesystem Implementation

Main FUSE filesystem that implements lazy-loading and write caching.
"""

import errno
import logging
import os
import stat as stat_module
import time
from pathlib import Path
from threading import Lock
from typing import Optional

from fuse import FUSE, FuseOSError, Operations, LoggingMixIn

from .cache import CacheManager, CacheEntry, InodeMetadata, DirectoryEntry
from .journal import Journal, OpType
from .sync import SyncManager

logger = logging.getLogger(__name__)


class HomeFS(LoggingMixIn, Operations):
    """
    HomeFS FUSE Filesystem.

    Implements a lazy-loading filesystem that caches files in RAM
    and syncs to USB when available.

    Features:
    - Lazy loading from USB
    - Write caching in RAM
    - LRU eviction
    - Offline operation
    - Automatic sync on USB connect
    """

    def __init__(self, usb_root: str, config: dict):
        """
        Initialize HomeFS.

        Args:
            usb_root: Path to USB storage (when mounted)
            config: Configuration dictionary
        """
        self.usb_root = Path(usb_root)
        self.config = config

        # Initialize components
        self.cache = CacheManager(config.get("cache", {}))
        self.journal = Journal(
            journal_path=config.get("journal", {}).get("path", "/var/lib/homefs/journal.wal"),
            max_size=config.get("journal", {}).get("max_size", 1024**3),
        )
        self.sync = SyncManager(
            config=config.get("sync", {}),
            journal=self.journal,
            cache=self.cache,
        )

        # File handle management
        self.next_fh = 1
        self.fh_lock = Lock()
        self.file_handles: dict[int, dict] = {}

        # Path to inode mapping
        self.path_to_inode: dict[str, int] = {}
        self.inode_to_path: dict[int, str] = {}

        # Load metadata from USB
        self._load_metadata()

        # Start sync manager
        self.sync.start()

        logger.info(f"HomeFS initialized: usb_root={usb_root}")

    def _load_metadata(self) -> None:
        """Load file metadata from USB into cache."""
        logger.info("Loading metadata from USB")

        if not self.usb_root.exists():
            logger.warning(f"USB root {self.usb_root} does not exist")
            return

        # Walk directory tree
        for root, dirs, files in os.walk(self.usb_root):
            rel_root = os.path.relpath(root, self.usb_root)
            if rel_root == ".":
                rel_root = "/"
            else:
                rel_root = "/" + rel_root

            # Load directory entries
            entries = []

            for dir_name in dirs:
                dir_path = os.path.join(root, dir_name)
                st = os.lstat(dir_path)
                inode = self._get_or_create_inode(os.path.join(rel_root, dir_name))

                entries.append(DirectoryEntry(
                    name=dir_name,
                    inode=inode,
                    type="dir",
                ))

                # Add metadata
                self.cache.add_metadata(
                    os.path.join(rel_root, dir_name),
                    InodeMetadata(
                        inode=inode,
                        mode=st.st_mode,
                        uid=st.st_uid,
                        gid=st.st_gid,
                        size=st.st_size,
                        atime=st.st_atime,
                        mtime=st.st_mtime,
                        ctime=st.st_ctime,
                        nlink=st.st_nlink,
                    )
                )

            for file_name in files:
                file_path = os.path.join(root, file_name)
                st = os.lstat(file_path)
                inode = self._get_or_create_inode(os.path.join(rel_root, file_name))

                entries.append(DirectoryEntry(
                    name=file_name,
                    inode=inode,
                    type="file",
                ))

                # Add metadata
                self.cache.add_metadata(
                    os.path.join(rel_root, file_name),
                    InodeMetadata(
                        inode=inode,
                        mode=st.st_mode,
                        uid=st.st_uid,
                        gid=st.st_gid,
                        size=st.st_size,
                        atime=st.st_atime,
                        mtime=st.st_mtime,
                        ctime=st.st_ctime,
                        nlink=st.st_nlink,
                    )
                )

            # Cache directory
            self.cache.add_directory(rel_root, entries)

        logger.info(f"Loaded {len(self.path_to_inode)} entries from USB")

    def _get_or_create_inode(self, path: str) -> int:
        """Get existing inode or create new one for path."""
        if path in self.path_to_inode:
            return self.path_to_inode[path]

        inode = self.cache.allocate_inode()
        self.path_to_inode[path] = inode
        self.inode_to_path[inode] = path
        return inode

    def _get_usb_path(self, path: str) -> Path:
        """Get USB filesystem path for virtual path."""
        return self.usb_root / path.lstrip("/")

    def _load_file_from_usb(self, path: str) -> Optional[bytes]:
        """Load file content from USB."""
        usb_path = self._get_usb_path(path)

        try:
            if usb_path.exists():
                return usb_path.read_bytes()
        except Exception as e:
            logger.error(f"Failed to load {path} from USB: {e}")

        return None

    # =========================================================================
    # FUSE Operations
    # =========================================================================

    def getattr(self, path: str, fh=None):
        """Get file attributes."""
        logger.debug(f"getattr: {path}")

        # Get inode
        inode = self.path_to_inode.get(path)
        if not inode:
            raise FuseOSError(errno.ENOENT)

        # Get metadata
        metadata = self.cache.get_metadata(inode)
        if not metadata:
            raise FuseOSError(errno.ENOENT)

        return {
            "st_mode": metadata.mode,
            "st_ino": metadata.inode,
            "st_nlink": metadata.nlink,
            "st_uid": metadata.uid,
            "st_gid": metadata.gid,
            "st_size": metadata.size,
            "st_atime": metadata.atime,
            "st_mtime": metadata.mtime,
            "st_ctime": metadata.ctime,
        }

    def readdir(self, path: str, fh):
        """Read directory entries."""
        logger.debug(f"readdir: {path}")

        # Get cached directory
        entries = self.cache.get_directory(path)
        if entries is None:
            raise FuseOSError(errno.ENOENT)

        # Return entries
        dirents = [".", ".."]
        dirents.extend([e.name for e in entries])

        return dirents

    def open(self, path: str, flags):
        """Open file."""
        logger.debug(f"open: {path}, flags={flags}")

        # Check if file exists
        inode = self.path_to_inode.get(path)
        if not inode:
            raise FuseOSError(errno.ENOENT)

        # Allocate file handle
        with self.fh_lock:
            fh = self.next_fh
            self.next_fh += 1

            self.file_handles[fh] = {
                "path": path,
                "inode": inode,
                "flags": flags,
            }

        # Increment refcount
        self.cache.increment_refcount(path)

        return fh

    def read(self, path: str, size: int, offset: int, fh):
        """Read file data."""
        logger.debug(f"read: {path}, size={size}, offset={offset}")

        # Check cache
        entry = self.cache.get(path)

        if entry is None:
            # Cache miss - load from USB
            logger.debug(f"Loading {path} from USB")
            content = self._load_file_from_usb(path)

            if content is None:
                raise FuseOSError(errno.EIO)

            # Get metadata
            inode = self.path_to_inode[path]
            metadata = self.cache.get_metadata(inode)

            # Create cache entry
            entry = CacheEntry(
                path=path,
                inode=inode,
                size=len(content),
                content=content,
                atime=time.time(),
                mtime=metadata.mtime,
                dirty=False,
                pinned=False,
                refcount=1,
                is_streaming=len(content) > self.cache.large_file_threshold,
            )

            # Add to cache
            self.cache.put(path, entry)

        # Read from cache
        if entry.is_streaming:
            data = self.cache.read_chunk(entry, offset, size)
        else:
            data = entry.content[offset:offset + size] if entry.content else b""

        return data

    def write(self, path: str, data: bytes, offset: int, fh):
        """Write file data."""
        logger.debug(f"write: {path}, size={len(data)}, offset={offset}")

        # Get or create cache entry
        entry = self.cache.get(path)

        if entry is None:
            # Load from USB first
            content = self._load_file_from_usb(path)

            if content is None:
                content = b""

            inode = self.path_to_inode[path]
            metadata = self.cache.get_metadata(inode)

            entry = CacheEntry(
                path=path,
                inode=inode,
                size=len(content),
                content=content,
                atime=time.time(),
                mtime=time.time(),
                dirty=False,
                pinned=False,
                refcount=1,
                is_streaming=len(content) > self.cache.large_file_threshold,
            )

            self.cache.put(path, entry)

        # Write to cache
        if entry.is_streaming:
            self.cache.write_chunk(entry, offset, data)
        else:
            # Expand if needed
            if entry.content is None:
                entry.content = b""

            if offset + len(data) > len(entry.content):
                entry.content += b"\x00" * (offset + len(data) - len(entry.content))

            # Write data
            entry.content = (
                entry.content[:offset] +
                data +
                entry.content[offset + len(data):]
            )

        # Update size
        entry.size = max(entry.size, offset + len(data))

        # Mark dirty
        self.cache.mark_dirty(path)

        # Update metadata
        metadata = self.cache.get_metadata(entry.inode)
        if metadata:
            metadata.size = entry.size
            metadata.mtime = time.time()

        # Journal the write
        self.journal.create_transaction(
            op_type=OpType.WRITE,
            path=path,
            offset=offset,
            length=len(data),
            data=data,
        )

        return len(data)

    def create(self, path: str, mode: int, fi=None):
        """Create new file."""
        logger.debug(f"create: {path}, mode={oct(mode)}")

        # Check if already exists
        if path in self.path_to_inode:
            raise FuseOSError(errno.EEXIST)

        # Create inode
        inode = self._get_or_create_inode(path)

        # Create metadata
        now = time.time()
        metadata = InodeMetadata(
            inode=inode,
            mode=stat_module.S_IFREG | mode,
            uid=os.getuid(),
            gid=os.getgid(),
            size=0,
            atime=now,
            mtime=now,
            ctime=now,
        )
        self.cache.add_metadata(path, metadata)

        # Create cache entry
        entry = CacheEntry(
            path=path,
            inode=inode,
            size=0,
            content=b"",
            atime=now,
            mtime=now,
            dirty=True,
            pinned=False,
            refcount=0,
            is_streaming=False,
        )
        self.cache.put(path, entry)

        # Add to parent directory
        parent = os.path.dirname(path) or "/"
        parent_entries = self.cache.get_directory(parent)
        if parent_entries is not None:
            parent_entries.append(DirectoryEntry(
                name=os.path.basename(path),
                inode=inode,
                type="file",
            ))

        # Journal the create
        self.journal.create_transaction(
            op_type=OpType.CREATE,
            path=path,
            mode=mode,
            data=b"",
        )

        # Allocate file handle
        with self.fh_lock:
            fh = self.next_fh
            self.next_fh += 1

            self.file_handles[fh] = {
                "path": path,
                "inode": inode,
                "flags": os.O_CREAT | os.O_WRONLY,
            }

        return fh

    def unlink(self, path: str):
        """Delete file."""
        logger.debug(f"unlink: {path}")

        # Check if exists
        if path not in self.path_to_inode:
            raise FuseOSError(errno.ENOENT)

        # Remove from cache
        self.cache.remove(path)

        # Remove from parent directory
        parent = os.path.dirname(path) or "/"
        parent_entries = self.cache.get_directory(parent)
        if parent_entries:
            parent_entries[:] = [e for e in parent_entries if e.name != os.path.basename(path)]

        # Remove inode mapping
        inode = self.path_to_inode.pop(path)
        self.inode_to_path.pop(inode, None)

        # Remove metadata
        del self.cache.inodes[inode]

        # Journal the delete
        self.journal.create_transaction(
            op_type=OpType.DELETE,
            path=path,
        )

    def release(self, path: str, fh):
        """Release file handle."""
        logger.debug(f"release: {path}, fh={fh}")

        # Remove file handle
        with self.fh_lock:
            if fh in self.file_handles:
                del self.file_handles[fh]

        # Decrement refcount
        self.cache.decrement_refcount(path)

    def truncate(self, path: str, length: int, fh=None):
        """Truncate file to length."""
        logger.debug(f"truncate: {path}, length={length}")

        # Get or create entry
        entry = self.cache.get(path)

        if entry is None:
            # Load from USB
            content = self._load_file_from_usb(path)

            if content is None:
                raise FuseOSError(errno.ENOENT)

            inode = self.path_to_inode[path]
            metadata = self.cache.get_metadata(inode)

            entry = CacheEntry(
                path=path,
                inode=inode,
                size=len(content),
                content=content,
                atime=time.time(),
                mtime=time.time(),
                dirty=False,
                pinned=False,
                refcount=0,
                is_streaming=False,
            )

            self.cache.put(path, entry)

        # Truncate
        if entry.content:
            if length < len(entry.content):
                entry.content = entry.content[:length]
            else:
                entry.content += b"\x00" * (length - len(entry.content))

        entry.size = length
        self.cache.mark_dirty(path)

        # Update metadata
        metadata = self.cache.get_metadata(entry.inode)
        if metadata:
            metadata.size = length
            metadata.mtime = time.time()

        # Journal
        self.journal.create_transaction(
            op_type=OpType.TRUNCATE,
            path=path,
            size=length,
        )

    def chmod(self, path: str, mode: int):
        """Change file permissions."""
        logger.debug(f"chmod: {path}, mode={oct(mode)}")

        inode = self.path_to_inode.get(path)
        if not inode:
            raise FuseOSError(errno.ENOENT)

        metadata = self.cache.get_metadata(inode)
        if not metadata:
            raise FuseOSError(errno.ENOENT)

        # Update mode (preserve file type bits)
        file_type = stat_module.S_IFMT(metadata.mode)
        metadata.mode = file_type | (mode & 0o777)
        metadata.ctime = time.time()

        # Journal
        self.journal.create_transaction(
            op_type=OpType.CHMOD,
            path=path,
            mode=mode,
        )

    def destroy(self, path):
        """Clean up filesystem."""
        logger.info("Destroying HomeFS")

        # Stop sync manager
        self.sync.stop()

        # Final sync if USB available
        if self.sync.state.value == "connected":
            self.sync.sync()


def mount_homefs(usb_root: str, mount_point: str, config: dict) -> None:
    """
    Mount HomeFS at mount_point.

    Args:
        usb_root: Path to USB storage
        mount_point: Where to mount filesystem
        config: Configuration dictionary
    """
    logger.info(f"Mounting HomeFS: {usb_root} -> {mount_point}")

    # Create HomeFS instance
    fs = HomeFS(usb_root, config)

    # Mount with FUSE
    FUSE(
        fs,
        mount_point,
        nothreads=False,
        foreground=True,
        allow_other=True,
    )
