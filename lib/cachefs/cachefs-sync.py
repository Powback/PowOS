#!/usr/bin/env python3
"""
CacheFS Sync Daemon - Monitors USB and syncs dirty cache files

This daemon:
1. Monitors USB connection state
2. Periodically syncs dirty files to USB
3. Notifies desktop of USB events
4. Provides sync status to powos CLI
"""

import os
import sys
import time
import json
import signal
import subprocess
from pathlib import Path
from typing import Optional
import logging

logging.basicConfig(level=logging.INFO, format='[cachefs-sync] %(message)s')
log = logging.getLogger(__name__)

# Config
SYNC_INTERVAL = 30  # seconds
STATUS_FILE = "/run/powos/cachefs-status.json"
USB_STATE_FILE = "/run/powos/usb-state"
CACHEFS_SOCKET = "/run/powos/cachefs.sock"  # Future: for IPC


class CacheFSSyncDaemon:
    def __init__(self, cache_dir: str, backing_path: str):
        self.cache_dir = Path(cache_dir)
        self.backing_path = Path(backing_path)
        self.running = True
        self.last_sync = 0
        self.pending_changes = 0
        self.usb_connected = False

        # Track dirty files by mtime
        self.tracked_files: dict = {}

        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)

    def _handle_signal(self, signum, frame):
        log.info(f"Received signal {signum}, shutting down...")
        self.running = False

    def check_usb_connected(self) -> bool:
        """Check if USB with PowOS label is connected."""
        try:
            result = subprocess.run(
                ['blkid', '-L', 'POWOS-DATA'],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                return True

            # Try alternate label
            result = subprocess.run(
                ['blkid', '-L', 'POWOS-HOME'],
                capture_output=True, text=True, timeout=5
            )
            return result.returncode == 0 and result.stdout.strip() != ''
        except Exception as e:
            log.warning(f"Error checking USB: {e}")
            return False

    def notify_desktop(self, message: str, urgency: str = "normal"):
        """Send desktop notification."""
        try:
            subprocess.run([
                'notify-send',
                '-u', urgency,
                '-i', 'drive-removable-media',
                'PowOS CacheFS',
                message
            ], timeout=5)
        except Exception:
            pass  # Notifications are optional

    def find_dirty_files(self) -> list:
        """Find files in cache that have been modified."""
        dirty = []

        if not self.cache_dir.exists():
            return dirty

        # Look for cache metadata file
        meta_file = self.cache_dir / "cache_meta.json"
        if meta_file.exists():
            try:
                with open(meta_file) as f:
                    meta = json.load(f)
                    dirty = meta.get('dirty_files', [])
            except Exception as e:
                log.warning(f"Error reading cache metadata: {e}")

        return dirty

    def sync_to_usb(self) -> bool:
        """Sync dirty cache files to USB."""
        if not self.usb_connected:
            log.warning("Cannot sync - USB not connected")
            return False

        if not self.backing_path.exists():
            log.warning(f"Backing path not available: {self.backing_path}")
            return False

        dirty_files = self.find_dirty_files()
        if not dirty_files:
            log.debug("No dirty files to sync")
            return True

        log.info(f"Syncing {len(dirty_files)} files to USB...")
        synced = 0

        for rel_path in dirty_files:
            cache_file = self.cache_dir / "data" / rel_path.lstrip('/')
            usb_file = self.backing_path / rel_path.lstrip('/')

            if cache_file.exists():
                try:
                    usb_file.parent.mkdir(parents=True, exist_ok=True)
                    # Use rsync for efficient copy
                    subprocess.run([
                        'rsync', '-a', '--inplace',
                        str(cache_file), str(usb_file)
                    ], check=True, timeout=60)
                    synced += 1
                except Exception as e:
                    log.error(f"Failed to sync {rel_path}: {e}")

        log.info(f"Synced {synced}/{len(dirty_files)} files")
        self.last_sync = time.time()
        return synced == len(dirty_files)

    def update_status(self):
        """Update status file for powos CLI."""
        status = {
            'usb_connected': self.usb_connected,
            'last_sync': self.last_sync,
            'pending_changes': self.pending_changes,
            'cache_dir': str(self.cache_dir),
            'backing_path': str(self.backing_path),
            'timestamp': time.time()
        }

        try:
            Path(STATUS_FILE).parent.mkdir(parents=True, exist_ok=True)
            with open(STATUS_FILE, 'w') as f:
                json.dump(status, f, indent=2)
        except Exception as e:
            log.warning(f"Could not update status file: {e}")

    def run(self):
        """Main daemon loop."""
        log.info("CacheFS sync daemon starting...")
        log.info(f"  Cache dir: {self.cache_dir}")
        log.info(f"  Backing path: {self.backing_path}")
        log.info(f"  Sync interval: {SYNC_INTERVAL}s")

        last_usb_state = None
        last_sync_time = 0

        while self.running:
            try:
                # Check USB state
                self.usb_connected = self.check_usb_connected()

                # Detect USB state change
                if last_usb_state is not None and last_usb_state != self.usb_connected:
                    if self.usb_connected:
                        log.info("USB connected!")
                        self.notify_desktop("USB connected - syncing changes...", "normal")
                        self.sync_to_usb()
                        self.notify_desktop("Sync complete", "low")
                    else:
                        log.warning("USB disconnected!")
                        self.notify_desktop(
                            "USB disconnected - running from cache\nCached files still accessible",
                            "critical"
                        )

                last_usb_state = self.usb_connected

                # Periodic sync
                now = time.time()
                if self.usb_connected and (now - last_sync_time) >= SYNC_INTERVAL:
                    dirty = self.find_dirty_files()
                    self.pending_changes = len(dirty)
                    if dirty:
                        self.sync_to_usb()
                    last_sync_time = now

                # Update status
                self.update_status()

                # Sleep
                time.sleep(5)

            except Exception as e:
                log.error(f"Error in sync loop: {e}")
                time.sleep(10)

        log.info("Sync daemon stopped")


def main():
    import argparse

    parser = argparse.ArgumentParser(description='CacheFS Sync Daemon')
    parser.add_argument('--cache-dir', default='/run/powos/cachefs',
                        help='Cache directory')
    parser.add_argument('--backing-path', default='/mnt/powos-usb/home',
                        help='USB backing store path')

    args = parser.parse_args()

    daemon = CacheFSSyncDaemon(args.cache_dir, args.backing_path)
    daemon.run()


if __name__ == '__main__':
    main()
