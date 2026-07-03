#!/usr/bin/env python3
"""
layer-sync.py - Sync RAM overlay changes to persistent custom layer

This daemon monitors the RAM upper layer and periodically syncs changes
to the custom layer on USB. This makes your customizations persistent
across reboots while still allowing unplug resilience.

Sync Strategy:
- Changes go to RAM first (instant, unplug-safe)
- Periodically rsync RAM upper -> custom layer on USB
- On next boot, custom layer is part of the lower stack
"""

import os
import sys
import time
import json
import signal
import shutil
import hashlib
import argparse
import subprocess
from pathlib import Path
from datetime import datetime
from typing import Optional, Dict, Set

# State files
STATE_DIR = Path("/run/powos")
LAYER_PATHS_FILE = STATE_DIR / "layer-paths"
SYNC_STATUS_FILE = STATE_DIR / "layer-sync-status.json"
USB_STATE_FILE = STATE_DIR / "usb-state"
PID_FILE = STATE_DIR / "layer-sync.pid"


def check_pid_file() -> bool:
    """Return True if safe to start (no existing instance). Cleans stale PID files."""
    if not PID_FILE.exists():
        return True
    try:
        existing_pid = int(PID_FILE.read_text().strip())
        os.kill(existing_pid, 0)  # Signal 0 = check existence only
        print(f"[layer-sync] Another instance already running (PID: {existing_pid}), exiting.")
        return False
    except ProcessLookupError:
        PID_FILE.unlink(missing_ok=True)  # Stale PID file
        return True
    except PermissionError:
        print(f"[layer-sync] Another instance already running (PID: {existing_pid}), exiting.")
        return False
    except ValueError:
        PID_FILE.unlink(missing_ok=True)  # Corrupt PID file
        return True


def write_pid_file():
    """Write current PID to pid file."""
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        PID_FILE.write_text(str(os.getpid()))
    except Exception as e:
        print(f"[layer-sync] Warning: could not write PID file: {e}")


def remove_pid_file():
    """Remove PID file on exit."""
    try:
        PID_FILE.unlink(missing_ok=True)
    except Exception:
        pass


class LayerSync:
    """Syncs RAM overlay changes to persistent custom layer."""

    def __init__(
        self,
        ram_upper: Path,
        custom_layer: Path,
        sync_interval: int = 60,
        exclude_patterns: Optional[list] = None
    ):
        self.ram_upper = Path(ram_upper)
        self.custom_layer = Path(custom_layer)
        self.sync_interval = sync_interval
        self.exclude_patterns = exclude_patterns or [
            # Temporary files
            "*.tmp", "*.temp", "*.swp", "*.lock",
            # Cache directories (will be regenerated)
            ".cache/*", "cache/*",
            # Runtime state (shouldn't persist)
            "/run/*", "/tmp/*", "/var/tmp/*",
            # Package manager locks
            "/var/lib/rpm/.rpm.lock",
            "/var/lib/dnf/*lock*",
        ]

        self.running = True
        self.last_sync = 0
        self.last_sync_success = False
        self.consecutive_failures = 0
        self.pending_changes = 0
        self.sync_errors = []

        # Track what we've synced
        self.synced_files: Set[str] = set()

    def is_usb_connected(self) -> bool:
        """Check if USB is connected and writable."""
        if not USB_STATE_FILE.exists():
            return False
        try:
            content = USB_STATE_FILE.read_text()
            return "USB_STATUS=connected" in content
        except:
            return False

    def count_changes(self) -> int:
        """Count files in RAM upper layer (changes since boot)."""
        if not self.ram_upper.exists():
            return 0
        count = 0
        for root, dirs, files in os.walk(self.ram_upper):
            whiteouts = [f for f in files if f.startswith(".wh.")]
            regular = [f for f in files if not f.startswith(".wh.")]
            count += len(regular)
            # If whiteout files exist, they represent deletions that must be synced
            if whiteouts:
                count += len(whiteouts)
        return count

    def get_changed_files(self) -> list:
        """Get list of changed files in RAM upper."""
        if not self.ram_upper.exists():
            return []

        changed = []
        for root, dirs, files in os.walk(self.ram_upper):
            rel_root = Path(root).relative_to(self.ram_upper)
            for f in files:
                if not f.startswith(".wh."):  # Skip whiteout markers
                    changed.append(str(rel_root / f))
        return changed

    def should_exclude(self, path: str) -> bool:
        """Check if path matches any exclude pattern."""
        from fnmatch import fnmatch
        for pattern in self.exclude_patterns:
            if fnmatch(path, pattern) or fnmatch("/" + path, pattern):
                return True
        return False

    def translate_whiteouts(self) -> bool:
        """Translate overlayfs whiteout files in RAM upper to actual deletions on custom layer.

        Overlayfs represents deletions as whiteout files:
          - .wh.FILENAME  : FILENAME was deleted in this layer
          - .wh..wh..opq  : Directory is opaque (all lower-layer contents hidden)

        Must be called before rsync so deleted files don't reappear after reboot.
        Returns True if all whiteouts were handled successfully.
        """
        if not self.ram_upper.exists():
            return True

        success = True
        for root, dirs, files in os.walk(self.ram_upper):
            root_path = Path(root)
            rel_dir = root_path.relative_to(self.ram_upper)
            custom_dir = self.custom_layer / rel_dir

            # Handle opaque directory whiteout: clear all pre-existing contents from the
            # corresponding custom layer directory so lower-layer files don't bleed through.
            if ".wh..wh..opq" in files and custom_dir.exists():
                self.log(f"Opaque whiteout: clearing contents of {rel_dir} from custom layer")
                try:
                    for item in list(custom_dir.iterdir()):
                        try:
                            if item.is_dir() and not item.is_symlink():
                                shutil.rmtree(item)
                            else:
                                item.unlink(missing_ok=True)
                        except Exception as e:
                            self.log(f"Warning: failed to remove {item}: {e}")
                            success = False
                except Exception as e:
                    self.log(f"Warning: failed to clear {custom_dir}: {e}")
                    success = False

            # Handle per-file whiteouts
            for f in files:
                if not f.startswith(".wh.") or f == ".wh..wh..opq":
                    continue
                target_name = f[4:]  # Strip ".wh." prefix
                target_path = custom_dir / target_name
                if target_path.exists() or target_path.is_symlink():
                    self.log(f"Whiteout: deleting {rel_dir / target_name} from custom layer")
                    try:
                        if target_path.is_dir() and not target_path.is_symlink():
                            shutil.rmtree(target_path)
                        else:
                            target_path.unlink(missing_ok=True)
                    except Exception as e:
                        self.log(f"Warning: failed to delete {target_path}: {e}")
                        success = False

        return success

    def sync_to_custom_layer(self) -> bool:
        """Rsync RAM upper to custom layer."""
        if not self.is_usb_connected():
            self.log("USB not connected, skipping sync")
            return False

        if not self.ram_upper.exists():
            self.log("RAM upper doesn't exist, nothing to sync")
            return True

        # Ensure custom layer exists
        self.custom_layer.mkdir(parents=True, exist_ok=True)

        # Translate overlayfs whiteouts to actual deletions before rsync.
        # This ensures files deleted in RAM don't reappear in the custom layer.
        self.log("Translating whiteout files...")
        self.translate_whiteouts()

        # Build rsync command
        cmd = [
            "rsync", "-av",
            "--delete-after",  # Delete after transfer (safer than --delete)
            "--partial",       # Keep partial files on interruption
        ]

        # Add exclude patterns
        for pattern in self.exclude_patterns:
            cmd.extend(["--exclude", pattern])

        # Source and destination
        cmd.append(f"{self.ram_upper}/")
        cmd.append(f"{self.custom_layer}/")

        try:
            self.log(f"Syncing {self.ram_upper} -> {self.custom_layer}")
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300  # 5 minute timeout
            )

            # Rsync exit code handling:
            #   0  = success
            #   23 = partial transfer (some files not transferred) -> FAILURE
            #   24 = vanished files (files changed/disappeared during scan) -> WARNING only
            #        This is normal for overlayfs where files can appear/disappear.
            #   other non-zero -> FAILURE
            if result.returncode == 0 or result.returncode == 24:
                if result.returncode == 24:
                    self.log("Warning: some files vanished during sync (normal for overlayfs)")
                else:
                    self.log("Sync completed successfully")

                # Verify USB is still accessible after sync (race condition guard).
                # The USB could have been disconnected mid-sync.
                if not os.access(str(self.custom_layer), os.W_OK):
                    self.log("ERROR: USB became inaccessible after sync (disconnected?)")
                    self.sync_errors.append("USB disconnected during or after sync")
                    self.last_sync_success = False
                    self.consecutive_failures += 1
                    return False

                # Flush page cache to disk before updating state
                try:
                    subprocess.run(["sync"], timeout=30)
                except Exception as e:
                    self.log(f"Warning: sync flush failed: {e}")
                self.last_sync = time.time()
                self.last_sync_success = True
                self.consecutive_failures = 0
                self.sync_errors = []
                return True
            else:
                error_label = "partial transfer" if result.returncode == 23 else f"exit {result.returncode}"
                error = result.stderr.strip()
                self.log(f"Sync failed ({error_label}): {error}")
                self.sync_errors.append(f"{error_label}: {error}")
                self.last_sync_success = False
                self.consecutive_failures += 1
                if self.consecutive_failures >= 3:
                    self.log(f"Warning: {self.consecutive_failures} consecutive sync failures")
                    send_notification(
                        "PowOS Sync Error",
                        f"Layer sync has failed {self.consecutive_failures} times. Changes may not be persisted.",
                        urgency="critical"
                    )
                # Do NOT update self.last_sync on failure
                return False

        except subprocess.TimeoutExpired:
            self.log("Sync timed out")
            self.sync_errors.append("Sync timed out")
            self.last_sync_success = False
            self.consecutive_failures += 1
            if self.consecutive_failures >= 3:
                send_notification(
                    "PowOS Sync Error",
                    f"Layer sync has failed {self.consecutive_failures} times. Changes may not be persisted.",
                    urgency="critical"
                )
            return False
        except Exception as e:
            self.log(f"Sync error: {e}")
            self.sync_errors.append(str(e))
            self.last_sync_success = False
            self.consecutive_failures += 1
            if self.consecutive_failures >= 3:
                send_notification(
                    "PowOS Sync Error",
                    f"Layer sync has failed {self.consecutive_failures} times. Changes may not be persisted.",
                    urgency="critical"
                )
            return False

    def write_status(self):
        """Write current status to JSON file."""
        status = {
            "last_sync": self.last_sync,
            "last_sync_human": datetime.fromtimestamp(self.last_sync).isoformat() if self.last_sync else "never",
            "last_sync_success": self.last_sync_success,
            "consecutive_failures": self.consecutive_failures,
            "pending_changes": self.count_changes(),
            "usb_connected": self.is_usb_connected(),
            "ram_upper": str(self.ram_upper),
            "custom_layer": str(self.custom_layer),
            "errors": self.sync_errors[-5:],  # Last 5 errors
            "sync_interval": self.sync_interval,
        }

        try:
            SYNC_STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
            SYNC_STATUS_FILE.write_text(json.dumps(status, indent=2))
        except Exception as e:
            self.log(f"Failed to write status: {e}")

    def log(self, msg: str):
        """Log message with timestamp."""
        timestamp = datetime.now().strftime("%H:%M:%S")
        print(f"[{timestamp}] [layer-sync] {msg}", flush=True)

    def handle_signal(self, signum, frame):
        """Handle shutdown signals."""
        self.log(f"Received signal {signum}, shutting down...")
        self.running = False
        # Final sync before exit - write marker if it fails
        success = self.sync_to_custom_layer()
        if not success:
            self.log("ERROR: Final sync on shutdown failed - writing marker file")
            try:
                STATE_DIR.mkdir(parents=True, exist_ok=True)
                (STATE_DIR / "sync-failed-on-shutdown").write_text(
                    f"Sync failed on shutdown at {datetime.now().isoformat()}\n"
                    f"Consecutive failures: {self.consecutive_failures}\n"
                    f"Last errors: {self.sync_errors[-3:]}\n"
                )
            except Exception as e:
                self.log(f"Failed to write shutdown marker: {e}")

    def run(self):
        """Main daemon loop."""
        self.log("Layer sync daemon starting")
        self.log(f"RAM upper: {self.ram_upper}")
        self.log(f"Custom layer: {self.custom_layer}")
        self.log(f"Sync interval: {self.sync_interval}s")

        # Setup signal handlers
        signal.signal(signal.SIGTERM, self.handle_signal)
        signal.signal(signal.SIGINT, self.handle_signal)

        # Initial sync
        self.sync_to_custom_layer()
        self.write_status()

        while self.running:
            try:
                time.sleep(self.sync_interval)

                if not self.running:
                    break

                # Check if there are changes worth syncing
                changes = self.count_changes()
                if changes > 0:
                    self.log(f"Found {changes} changed files, syncing...")
                    self.sync_to_custom_layer()

                self.write_status()

            except Exception as e:
                self.log(f"Error in sync loop: {e}")
                time.sleep(10)  # Back off on error

        self.log("Layer sync daemon stopped")


def send_notification(title: str, message: str, urgency: str = "normal"):
    """Send desktop notification."""
    try:
        subprocess.run(
            ["notify-send", "-u", urgency, title, message],
            capture_output=True,
            timeout=5
        )
    except:
        pass


def main():
    parser = argparse.ArgumentParser(description="Sync RAM overlay to persistent custom layer")
    parser.add_argument("--ram-upper", type=str, help="Path to RAM upper layer")
    parser.add_argument("--custom-layer", type=str, help="Path to custom layer on USB")
    parser.add_argument("--interval", type=int, default=60, help="Sync interval in seconds")
    parser.add_argument("--sync-now", action="store_true", help="Sync once and exit")
    parser.add_argument("--status", action="store_true", help="Show sync status")

    args = parser.parse_args()

    # Try to load paths from state file
    ram_upper = args.ram_upper
    custom_layer = args.custom_layer

    if LAYER_PATHS_FILE.exists() and (not ram_upper or not custom_layer):
        try:
            content = LAYER_PATHS_FILE.read_text()
            for line in content.strip().split("\n"):
                if line.startswith("RAM_UPPER="):
                    ram_upper = ram_upper or line.split("=", 1)[1]
                elif line.startswith("CUSTOM_LAYER="):
                    custom_layer = custom_layer or line.split("=", 1)[1]
        except:
            pass

    if args.status:
        if SYNC_STATUS_FILE.exists():
            print(SYNC_STATUS_FILE.read_text())
        else:
            print("No sync status available")
        return 0

    if not ram_upper or not custom_layer:
        print("Error: Could not determine layer paths")
        print("Specify --ram-upper and --custom-layer, or ensure /run/powos/layer-paths exists")
        return 1

    syncer = LayerSync(
        ram_upper=Path(ram_upper),
        custom_layer=Path(custom_layer),
        sync_interval=args.interval
    )

    if args.sync_now:
        success = syncer.sync_to_custom_layer()
        syncer.write_status()
        return 0 if success else 1

    # Run as daemon — guard against duplicate instances
    if not check_pid_file():
        return 1

    write_pid_file()
    try:
        syncer.run()
    finally:
        remove_pid_file()
    return 0


if __name__ == "__main__":
    sys.exit(main())
