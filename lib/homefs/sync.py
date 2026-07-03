"""
USB Sync Manager for HomeFS

Handles USB hotplug detection, writeback synchronization,
and conflict resolution.
"""

import logging
import os
import shutil
import subprocess
import time
from enum import Enum
from pathlib import Path
from threading import Thread, Event, Lock
from typing import Optional, Callable

import pyudev

logger = logging.getLogger(__name__)


class USBState(Enum):
    """USB connection states."""

    UNKNOWN = "unknown"
    CONNECTED = "connected"
    OFFLINE = "offline"
    SYNCING = "syncing"
    ERROR = "error"


class ConflictStrategy(Enum):
    """Conflict resolution strategies."""

    LAST_WRITE_WINS = "last-write-wins"
    MERGE = "merge"
    ASK = "ask"
    KEEP_BOTH = "keep-both"


class SyncManager:
    """
    Manages USB synchronization for HomeFS.

    Features:
    - USB hotplug detection via udev
    - Automatic writeback on connect
    - Conflict detection and resolution
    - Batch synchronization
    - Progress tracking
    """

    def __init__(self, config: dict, journal, cache):
        """
        Initialize sync manager.

        Args:
            config: Configuration dict with keys:
                - usb_uuid: UUID of USB filesystem
                - usb_mount_point: Where USB is mounted
                - sync_strategy: 'immediate', 'batched', or 'manual'
                - batch_interval: Seconds between batches
                - conflict_resolution: ConflictStrategy value
                - backup_conflicts: Whether to backup conflicted files
            journal: Journal instance
            cache: CacheManager instance
        """
        self.usb_uuid = config.get("usb_uuid")
        self.usb_mount_point = Path(config.get("usb_mount_point", "/mnt/homefs-usb"))
        self.sync_strategy = config.get("sync_strategy", "batched")
        self.batch_interval = config.get("batch_interval", 30)
        self.conflict_resolution = ConflictStrategy(
            config.get("conflict_resolution", "last-write-wins")
        )
        self.backup_conflicts = config.get("backup_conflicts", True)

        self.journal = journal
        self.cache = cache

        # State
        self.state = USBState.UNKNOWN
        self.state_lock = Lock()
        self.last_sync = None
        self.sync_in_progress = False

        # Threading
        self.stop_event = Event()
        self.monitor_thread: Optional[Thread] = None
        self.sync_thread: Optional[Thread] = None

        # Callbacks
        self.on_connect_callbacks: list[Callable] = []
        self.on_disconnect_callbacks: list[Callable] = []
        self.on_sync_complete_callbacks: list[Callable] = []

        # Statistics
        self.sync_count = 0
        self.conflict_count = 0
        self.bytes_synced = 0

        logger.info(
            f"Sync manager initialized: strategy={self.sync_strategy}, "
            f"uuid={self.usb_uuid}"
        )

    def start(self) -> None:
        """Start USB monitoring and sync threads."""
        if self.monitor_thread and self.monitor_thread.is_alive():
            logger.warning("Sync manager already started")
            return

        self.stop_event.clear()

        # Start USB monitor thread
        self.monitor_thread = Thread(target=self._monitor_usb, daemon=True)
        self.monitor_thread.start()

        # Start sync thread if batched mode
        if self.sync_strategy == "batched":
            self.sync_thread = Thread(target=self._sync_loop, daemon=True)
            self.sync_thread.start()

        logger.info("Sync manager started")

    def stop(self) -> None:
        """Stop USB monitoring and sync threads."""
        self.stop_event.set()

        if self.monitor_thread:
            self.monitor_thread.join(timeout=5)

        if self.sync_thread:
            self.sync_thread.join(timeout=5)

        logger.info("Sync manager stopped")

    def _monitor_usb(self) -> None:
        """Monitor USB connection via udev."""
        context = pyudev.Context()
        monitor = pyudev.Monitor.from_netlink(context)
        monitor.filter_by(subsystem='block')

        logger.info("USB monitor started")

        # Initial detection
        self._detect_usb_state()

        # Monitor for changes
        for device in iter(monitor.poll, None):
            if self.stop_event.is_set():
                break

            # Check if this is our USB device
            if self.usb_uuid and device.get('ID_FS_UUID') == self.usb_uuid:
                if device.action == 'add':
                    logger.info(f"USB device connected: {device.device_node}")
                    self._on_usb_connect(device.device_node)
                elif device.action == 'remove':
                    logger.info("USB device disconnected")
                    self._on_usb_disconnect()

    def _detect_usb_state(self) -> None:
        """Detect initial USB state."""
        if not self.usb_uuid:
            logger.warning("No USB UUID configured, cannot detect state")
            self._set_state(USBState.UNKNOWN)
            return

        # Check if USB is mounted
        if self.usb_mount_point.exists() and self._is_usb_mounted():
            logger.info("USB already mounted at boot")
            self._set_state(USBState.CONNECTED)
        else:
            # Try to find and mount USB
            device = self._find_usb_device()
            if device:
                self._mount_usb(device)
            else:
                logger.info("USB not connected at boot")
                self._set_state(USBState.OFFLINE)

    def _find_usb_device(self) -> Optional[str]:
        """Find USB device by UUID."""
        try:
            result = subprocess.run(
                ["blkid", "-U", self.usb_uuid],
                capture_output=True,
                text=True,
                check=False
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except Exception as e:
            logger.error(f"Failed to find USB device: {e}")

        return None

    def _is_usb_mounted(self) -> bool:
        """Check if USB is currently mounted."""
        try:
            result = subprocess.run(
                ["mountpoint", "-q", str(self.usb_mount_point)],
                check=False
            )
            return result.returncode == 0
        except Exception as e:
            logger.error(f"Failed to check mount point: {e}")
            return False

    def _mount_usb(self, device: str) -> bool:
        """
        Mount USB device.

        Args:
            device: Device path (e.g., /dev/sdb2)

        Returns:
            True if mounted successfully
        """
        try:
            # Create mount point if needed
            self.usb_mount_point.mkdir(parents=True, exist_ok=True)

            # Mount
            subprocess.run(
                ["mount", device, str(self.usb_mount_point)],
                check=True
            )

            logger.info(f"Mounted {device} at {self.usb_mount_point}")
            return True

        except Exception as e:
            logger.error(f"Failed to mount USB: {e}")
            return False

    def _unmount_usb(self) -> bool:
        """Unmount USB device."""
        try:
            subprocess.run(
                ["umount", str(self.usb_mount_point)],
                check=True
            )
            logger.info(f"Unmounted {self.usb_mount_point}")
            return True

        except Exception as e:
            logger.error(f"Failed to unmount USB: {e}")
            return False

    def _on_usb_connect(self, device: str) -> None:
        """Handle USB connection event."""
        with self.state_lock:
            if self.state == USBState.CONNECTED:
                return

            # Mount USB
            if self._mount_usb(device):
                self._set_state(USBState.CONNECTED)

                # Trigger callbacks
                for callback in self.on_connect_callbacks:
                    try:
                        callback()
                    except Exception as e:
                        logger.error(f"Connect callback failed: {e}")

                # Trigger sync if immediate mode
                if self.sync_strategy == "immediate":
                    self.sync()

    def _on_usb_disconnect(self) -> None:
        """Handle USB disconnection event."""
        with self.state_lock:
            if self.state == USBState.OFFLINE:
                return

            self._set_state(USBState.OFFLINE)

            # Trigger callbacks
            for callback in self.on_disconnect_callbacks:
                try:
                    callback()
                except Exception as e:
                    logger.error(f"Disconnect callback failed: {e}")

    def _set_state(self, state: USBState) -> None:
        """Set USB state."""
        old_state = self.state
        self.state = state
        logger.info(f"USB state: {old_state.value} -> {state.value}")

    def _sync_loop(self) -> None:
        """Background sync loop for batched mode."""
        logger.info(f"Sync loop started: interval={self.batch_interval}s")

        while not self.stop_event.wait(self.batch_interval):
            if self.state == USBState.CONNECTED:
                self.sync()

    def sync(self, force: bool = False) -> bool:
        """
        Synchronize pending changes to USB.

        Args:
            force: Force sync even if already syncing

        Returns:
            True if sync completed successfully
        """
        if self.sync_in_progress and not force:
            logger.warning("Sync already in progress")
            return False

        if self.state != USBState.CONNECTED:
            logger.warning(f"Cannot sync: USB state is {self.state.value}")
            return False

        self.sync_in_progress = True
        self._set_state(USBState.SYNCING)

        try:
            # Get pending transactions
            pending = self.journal.get_pending_transactions()

            if not pending:
                logger.info("No pending transactions to sync")
                return True

            logger.info(f"Syncing {len(pending)} transactions")

            # Apply transactions to USB
            synced_count = 0
            last_txn_id = None

            for txn in pending:
                try:
                    self._apply_transaction(txn)
                    synced_count += 1
                    last_txn_id = txn.txn_id
                except Exception as e:
                    logger.error(f"Failed to sync transaction {txn.txn_id}: {e}")
                    # Continue with next transaction

            # Create checkpoint
            if last_txn_id:
                self.journal.checkpoint(last_txn_id)

            # Update statistics
            self.sync_count += 1
            self.last_sync = time.time()

            logger.info(f"Sync completed: {synced_count}/{len(pending)} transactions")

            # Trigger callbacks
            for callback in self.on_sync_complete_callbacks:
                try:
                    callback(synced_count, len(pending))
                except Exception as e:
                    logger.error(f"Sync complete callback failed: {e}")

            return True

        finally:
            self.sync_in_progress = False
            self._set_state(USBState.CONNECTED)

    def _apply_transaction(self, txn) -> None:
        """
        Apply single transaction to USB storage.

        Handles conflict detection and resolution.
        """
        usb_path = self.usb_mount_point / txn.path.lstrip("/")

        # Check for conflicts
        if self._has_conflict(txn, usb_path):
            self._resolve_conflict(txn, usb_path)
            return

        # Apply operation
        from .journal import OpType

        if txn.op_type == OpType.CREATE:
            self._apply_create(txn, usb_path)
        elif txn.op_type == OpType.WRITE:
            self._apply_write(txn, usb_path)
        elif txn.op_type == OpType.DELETE:
            self._apply_delete(txn, usb_path)
        elif txn.op_type == OpType.RENAME:
            self._apply_rename(txn, usb_path)
        elif txn.op_type == OpType.CHMOD:
            self._apply_chmod(txn, usb_path)
        elif txn.op_type == OpType.TRUNCATE:
            self._apply_truncate(txn, usb_path)
        elif txn.op_type == OpType.MKDIR:
            self._apply_mkdir(txn, usb_path)
        elif txn.op_type == OpType.RMDIR:
            self._apply_rmdir(txn, usb_path)
        else:
            logger.warning(f"Unsupported operation: {txn.op_type}")

    def _has_conflict(self, txn, usb_path: Path) -> bool:
        """Check if transaction conflicts with USB state."""
        if not usb_path.exists():
            return False

        # Compare modification times
        usb_mtime = usb_path.stat().st_mtime
        if usb_mtime > txn.timestamp:
            logger.warning(f"Conflict detected for {txn.path}")
            return True

        return False

    def _resolve_conflict(self, txn, usb_path: Path) -> None:
        """Resolve conflict based on strategy."""
        self.conflict_count += 1

        if self.conflict_resolution == ConflictStrategy.LAST_WRITE_WINS:
            # Backup USB version
            if self.backup_conflicts:
                self._backup_conflicted_file(usb_path)

            # Apply RAM version (overwrite)
            logger.info(f"Conflict resolved (last-write-wins): {txn.path}")
            self._apply_transaction_force(txn, usb_path)

        elif self.conflict_resolution == ConflictStrategy.KEEP_BOTH:
            # Rename RAM version
            ram_path = usb_path.with_suffix(f".ram-{int(txn.timestamp)}")
            logger.info(f"Conflict resolved (keep-both): RAM -> {ram_path.name}")
            # Apply to renamed path
            self._apply_transaction_force(txn, ram_path)

        else:
            logger.error(f"Unsupported conflict resolution: {self.conflict_resolution}")

    def _backup_conflicted_file(self, usb_path: Path) -> None:
        """Backup conflicted file to .homefs-conflicts/"""
        backup_dir = self.usb_mount_point / ".homefs-conflicts"
        backup_dir.mkdir(exist_ok=True)

        timestamp = int(time.time())
        backup_path = backup_dir / f"{usb_path.name}.usb-{timestamp}"

        shutil.copy2(usb_path, backup_path)
        logger.info(f"Backed up conflicted file: {backup_path}")

    def _apply_transaction_force(self, txn, usb_path: Path) -> None:
        """Apply transaction without conflict checking."""
        # TODO: Implement operation handlers
        pass

    def _apply_create(self, txn, usb_path: Path) -> None:
        """Apply CREATE operation."""
        usb_path.parent.mkdir(parents=True, exist_ok=True)
        usb_path.write_bytes(txn.data or b"")
        if txn.mode:
            usb_path.chmod(txn.mode)
        logger.debug(f"Created {usb_path}")

    def _apply_write(self, txn, usb_path: Path) -> None:
        """Apply WRITE operation."""
        # Read existing file
        if usb_path.exists():
            content = bytearray(usb_path.read_bytes())
        else:
            content = bytearray()

        # Expand if needed
        if txn.offset + len(txn.data) > len(content):
            content.extend(b"\x00" * (txn.offset + len(txn.data) - len(content)))

        # Write data at offset
        content[txn.offset:txn.offset + len(txn.data)] = txn.data

        # Write back
        usb_path.write_bytes(content)
        self.bytes_synced += len(txn.data)
        logger.debug(f"Wrote {len(txn.data)} bytes to {usb_path}")

    def _apply_delete(self, txn, usb_path: Path) -> None:
        """Apply DELETE operation."""
        if usb_path.exists():
            usb_path.unlink()
            logger.debug(f"Deleted {usb_path}")

    def _apply_rename(self, txn, usb_path: Path) -> None:
        """Apply RENAME operation."""
        old_path = self.usb_mount_point / txn.old_path.lstrip("/")
        if old_path.exists():
            usb_path.parent.mkdir(parents=True, exist_ok=True)
            old_path.rename(usb_path)
            logger.debug(f"Renamed {old_path} -> {usb_path}")

    def _apply_chmod(self, txn, usb_path: Path) -> None:
        """Apply CHMOD operation."""
        if usb_path.exists() and txn.mode:
            usb_path.chmod(txn.mode)
            logger.debug(f"Changed mode of {usb_path} to {oct(txn.mode)}")

    def _apply_truncate(self, txn, usb_path: Path) -> None:
        """Apply TRUNCATE operation."""
        if usb_path.exists():
            with open(usb_path, "r+b") as f:
                f.truncate(txn.size)
            logger.debug(f"Truncated {usb_path} to {txn.size} bytes")

    def _apply_mkdir(self, txn, usb_path: Path) -> None:
        """Apply MKDIR operation."""
        usb_path.mkdir(parents=True, exist_ok=True)
        if txn.mode:
            usb_path.chmod(txn.mode)
        logger.debug(f"Created directory {usb_path}")

    def _apply_rmdir(self, txn, usb_path: Path) -> None:
        """Apply RMDIR operation."""
        if usb_path.exists():
            usb_path.rmdir()
            logger.debug(f"Removed directory {usb_path}")

    def is_safe_to_unplug(self) -> bool:
        """Check if USB can be safely unplugged."""
        return (
            self.state == USBState.CONNECTED and
            not self.sync_in_progress and
            len(self.journal.get_pending_transactions()) == 0
        )

    def get_status(self) -> dict:
        """Get sync manager status."""
        pending = self.journal.get_pending_transactions()

        return {
            "state": self.state.value,
            "usb_mounted": self._is_usb_mounted(),
            "sync_in_progress": self.sync_in_progress,
            "pending_transactions": len(pending),
            "last_sync": self.last_sync,
            "safe_to_unplug": self.is_safe_to_unplug(),
            "sync_count": self.sync_count,
            "conflict_count": self.conflict_count,
            "bytes_synced": self.bytes_synced,
        }

    def on_connect(self, callback: Callable) -> None:
        """Register callback for USB connect event."""
        self.on_connect_callbacks.append(callback)

    def on_disconnect(self, callback: Callable) -> None:
        """Register callback for USB disconnect event."""
        self.on_disconnect_callbacks.append(callback)

    def on_sync_complete(self, callback: Callable) -> None:
        """Register callback for sync complete event."""
        self.on_sync_complete_callbacks.append(callback)
