#!/usr/bin/env python3
"""
layer-sync.py - Sync RAM overlay changes to persistent custom layer

This daemon monitors the RAM upper layer and periodically syncs changes
to the custom layer on USB. This makes your customizations persistent
across reboots while still allowing unplug resilience.

Sync Strategy:
- Changes go to RAM first (instant, unplug-safe)
- Periodically rsync RAM upper -> custom layer on USB. The sync is ADDITIVE:
  the RAM upper is a fresh empty tmpfs each boot while the custom layer
  accumulates changes from all previous boots, so rsync must NEVER be given
  a --delete flag (it would erase the custom layer on the first sync of
  every boot).
- Deletions propagate exclusively via kernel-overlayfs whiteouts:
  a whiteout is a char(0,0) device named like the deleted entry; an opaque
  directory carries the trusted.overlay.opaque=y xattr. (This is NOT the
  AUFS/Docker `.wh.` marker convention.)
- On next boot, custom layer is part of the lower stack
"""

import os
import sys
import stat
import time
import json
import signal
import shutil
import argparse
import subprocess
from pathlib import Path
from datetime import datetime
from typing import Optional

try:
    import fcntl  # Linux only; tests may run elsewhere
except ImportError:  # pragma: no cover
    fcntl = None

# State files
STATE_DIR = Path("/run/powos")
LAYER_PATHS_FILE = STATE_DIR / "layer-paths"
SYNC_STATUS_FILE = STATE_DIR / "layer-sync-status.json"
USB_STATE_FILE = STATE_DIR / "usb-state"
PID_FILE = STATE_DIR / "layer-sync.pid"
# Global sync lock — honored by ALL sync entry points (daemon cycle,
# --sync-now, shutdown sync) so two rsyncs never hit the same destination.
# NOTE: distinct from /run/powos/sync.lock (used by cloud backup).
LOCK_FILE = STATE_DIR / "layer-sync.lock"


def is_whiteout(path: str) -> bool:
    """True if path is a kernel-overlayfs whiteout: a char device (0,0).

    The RAM upper is a kernel overlayfs upperdir, so whiteouts are char(0,0)
    devices named like the deleted entry — NOT AUFS/Docker `.wh.` files.
    A regular file that happens to be named `.wh.something` is just a
    regular file and must never trigger a deletion.
    """
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return (
        stat.S_ISCHR(st.st_mode)
        and os.major(st.st_rdev) == 0
        and os.minor(st.st_rdev) == 0
    )


def is_opaque_dir(path: str) -> bool:
    """True if directory carries the kernel-overlayfs opaque marker xattr."""
    if not hasattr(os, "getxattr"):  # non-Linux (tests)
        return False
    try:
        return os.getxattr(path, "trusted.overlay.opaque",
                           follow_symlinks=False) == b"y"
    except OSError:
        return False


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
        exclude_patterns: Optional[list] = None,
        usb_mount: Optional[Path] = None,
        whiteout_check=None,
        opaque_check=None,
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

        # Whiteout/opaque detection are injectable pure predicates so the
        # logic is testable without root (char devices need CAP_MKNOD).
        self.is_whiteout = whiteout_check or is_whiteout
        self.is_opaque_dir = opaque_check or is_opaque_dir

        # Mount point backing the custom layer. Standard layout is
        # <usb-mount>/layers/custom; used to verify the USB is actually
        # mounted (the mountpoint path stays a plain writable directory on
        # the parent tmpfs after the mount vanishes).
        if usb_mount is not None:
            self.usb_mount = Path(usb_mount)
        elif self.custom_layer.parent.name == "layers":
            self.usb_mount = self.custom_layer.parent.parent
        else:
            self.usb_mount = None

        self.running = True
        self.last_sync = 0
        self.last_sync_success = False
        self.consecutive_failures = 0
        self.sync_errors = []
        # Entries in the RAM upper modified after this timestamp are still
        # pending. Set to the start time of the last successful sync.
        self.synced_cutoff = 0.0

    # ── USB / destination guards ──────────────────────────────────────────

    def is_usb_connected(self) -> bool:
        """Check USB state file (kept up to date by udev hotplug rules)."""
        if not USB_STATE_FILE.exists():
            return False
        try:
            content = USB_STATE_FILE.read_text()
            return "USB_STATUS=connected" in content
        except Exception:
            return False

    def destination_available(self) -> bool:
        """Destination must exist and be backed by a real mounted filesystem.

        Guards against the USB vanishing: after an unmount the mountpoint
        path can remain as a plain (writable) directory on the parent tmpfs,
        so a bare os.access() check is not enough.
        """
        try:
            if not self.custom_layer.parent.exists():
                return False
            if self.usb_mount is not None:
                return os.path.ismount(str(self.usb_mount))
            return True
        except OSError:
            return False

    # ── Locking ───────────────────────────────────────────────────────────

    def _acquire_lock(self, timeout: int = 30):
        """Acquire the global sync lock (flock on LOCK_FILE).

        Returns an open fd on success, None if another sync holds the lock.
        Degrades to no locking (with a warning) if flock is unavailable or
        the lockfile cannot be created.
        """
        if fcntl is None:
            return -1  # sentinel: locking unavailable on this platform
        try:
            LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(str(LOCK_FILE), os.O_RDWR | os.O_CREAT, 0o644)
        except OSError as e:
            self.log(f"Warning: cannot create lock file {LOCK_FILE}: {e} (continuing unlocked)")
            return -1
        deadline = time.time() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return fd
            except OSError:
                if time.time() >= deadline:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    return None
                time.sleep(1)

    def _release_lock(self, fd):
        if fd is None or fd == -1 or fcntl is None:
            return
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass

    # ── Change tracking ───────────────────────────────────────────────────

    def count_changes(self) -> int:
        """Count entries in the RAM upper modified since the last successful
        sync (regular files AND whiteouts — both still need syncing).

        Resets to 0 after a successful sync so `powos safe` reflects what is
        actually unsynced, not everything since boot.
        """
        if not self.ram_upper.exists():
            return 0
        cutoff = self.synced_cutoff
        count = 0
        for root, dirs, files in os.walk(self.ram_upper):
            for f in files:
                path = os.path.join(root, f)
                try:
                    st = os.lstat(path)
                except OSError:
                    continue
                if st.st_mtime > cutoff:
                    count += 1
        return count

    def get_changed_files(self) -> list:
        """List changed regular entries in RAM upper (whiteouts excluded —
        classification is by char(0,0) device, never by filename)."""
        if not self.ram_upper.exists():
            return []

        changed = []
        for root, dirs, files in os.walk(self.ram_upper):
            rel_root = Path(root).relative_to(self.ram_upper)
            for f in files:
                if not self.is_whiteout(os.path.join(root, f)):
                    changed.append(str(rel_root / f))
        return changed

    def should_exclude(self, path: str) -> bool:
        """Check if path matches any exclude pattern."""
        from fnmatch import fnmatch
        for pattern in self.exclude_patterns:
            if fnmatch(path, pattern) or fnmatch("/" + path, pattern):
                return True
        return False

    # ── Whiteout handling ─────────────────────────────────────────────────

    def apply_whiteouts(self) -> bool:
        """Apply kernel-overlayfs whiteouts from the RAM upper to the custom layer.

        Semantics (custom is itself a lowerdir on the next boot):
          - Whiteout char(0,0) device in upper: remove any REAL file/dir at
            the same path in custom. The whiteout device itself is then
            replicated into custom by rsync (-a includes --devices), so it
            keeps hiding the entry in the layers below custom (updates/base).
            A whiteout with no lower counterpart is harmless — the name
            simply stays absent from the merged view.
          - Opaque directory (trusted.overlay.opaque=y): clear pre-existing
            contents of the matching custom dir; rsync -X then copies the
            opaque xattr onto it so lower layers stay hidden.

        Must run before rsync. Returns True if all whiteouts were handled.
        """
        if not self.ram_upper.exists():
            return True

        success = True
        for root, dirs, files in os.walk(self.ram_upper):
            root_path = Path(root)
            rel_dir = root_path.relative_to(self.ram_upper)
            custom_dir = self.custom_layer / rel_dir

            # Opaque directories: everything from lower layers is hidden.
            for d in dirs:
                if not self.is_opaque_dir(str(root_path / d)):
                    continue
                target = custom_dir / d
                if not target.is_dir() or target.is_symlink():
                    continue
                self.log(f"Opaque dir: clearing contents of {rel_dir / d} in custom layer")
                try:
                    for item in list(target.iterdir()):
                        try:
                            if item.is_dir() and not item.is_symlink():
                                shutil.rmtree(item)
                            else:
                                item.unlink(missing_ok=True)
                        except Exception as e:
                            self.log(f"Warning: failed to remove {item}: {e}")
                            success = False
                except Exception as e:
                    self.log(f"Warning: failed to clear {target}: {e}")
                    success = False

            # Per-entry whiteouts: char(0,0) device named like the deleted entry.
            for f in files:
                if not self.is_whiteout(str(root_path / f)):
                    continue
                target = custom_dir / f
                # Already a whiteout in custom? Leave it — rsync will refresh it.
                if self.is_whiteout(str(target)):
                    continue
                if not (target.exists() or target.is_symlink()):
                    continue  # nothing to remove in custom
                self.log(f"Whiteout: removing {rel_dir / f} from custom layer")
                try:
                    if target.is_dir() and not target.is_symlink():
                        shutil.rmtree(target)
                    else:
                        target.unlink(missing_ok=True)
                except Exception as e:
                    self.log(f"Warning: failed to delete {target}: {e}")
                    success = False

        return success

    # ── Sync ──────────────────────────────────────────────────────────────

    def _record_failure(self, error: str) -> bool:
        """Common bookkeeping for a failed sync. Always returns False."""
        self.log(f"Sync failed: {error}")
        self.sync_errors.append(error)
        self.last_sync_success = False
        self.consecutive_failures += 1
        if self.consecutive_failures >= 3:
            self.log(f"Warning: {self.consecutive_failures} consecutive sync failures")
            send_notification(
                "PowOS Sync Error",
                f"Layer sync has failed {self.consecutive_failures} times. Changes may not be persisted.",
                urgency="critical"
            )
        return False

    def sync_to_custom_layer(self) -> bool:
        """Rsync RAM upper to custom layer (serialized via the global lock)."""
        lock_fd = self._acquire_lock()
        if lock_fd is None:
            self.log("Another sync is already running, skipping")
            return False
        try:
            return self._sync_locked()
        finally:
            self._release_lock(lock_fd)

    def _sync_locked(self) -> bool:
        if not self.is_usb_connected():
            self.log("USB not connected, skipping sync")
            return False

        if not self.destination_available():
            self.log("Custom layer is not on a mounted filesystem (USB gone?), skipping sync")
            return False

        if not self.ram_upper.exists():
            self.log("RAM upper doesn't exist, nothing to sync")
            return True

        # Ensure custom layer exists
        self.custom_layer.mkdir(parents=True, exist_ok=True)

        # Apply overlayfs whiteouts (deletions) before the additive rsync.
        self.log("Applying overlayfs whiteouts...")
        self.apply_whiteouts()

        sync_start = time.time()

        # Build rsync command.
        # NO --delete flag of any kind: the RAM upper is a fresh tmpfs each
        # boot while the custom layer accumulates all previous boots — any
        # delete flag would erase the custom layer on the first sync of
        # every boot. Deletions propagate via whiteouts only (see
        # apply_whiteouts). NO --partial either: without --partial-dir it
        # leaves truncated files in the custom layer on interruption.
        cmd = [
            "rsync",
            "-a",   # archive (includes --devices: replicates whiteout char devs)
            "-v",
            "-X",   # xattrs (SELinux contexts, trusted.overlay.opaque)
            "-A",   # ACLs
            "-H",   # hardlinks
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

                # Verify USB is still actually mounted and writable after the
                # sync (mid-sync unplug guard). os.access alone is not enough:
                # the mountpoint stays a writable plain directory after the
                # mount vanishes.
                if not self.destination_available() or not os.access(str(self.custom_layer), os.W_OK):
                    return self._record_failure("USB disconnected during or after sync")

                # Flush page cache to disk. A failed/timed-out flush means the
                # changes are NOT durably on the USB — that is a sync FAILURE.
                try:
                    flush = subprocess.run(["sync"], timeout=30)
                    if flush.returncode != 0:
                        return self._record_failure(f"flush (sync) exited {flush.returncode}")
                except Exception as e:
                    return self._record_failure(f"flush (sync) failed: {e}")

                self.last_sync = time.time()
                self.synced_cutoff = sync_start
                self.last_sync_success = True
                self.consecutive_failures = 0
                self.sync_errors = []
                return True
            else:
                error_label = "partial transfer" if result.returncode == 23 else f"exit {result.returncode}"
                error = result.stderr.strip()
                return self._record_failure(f"{error_label}: {error}")

        except subprocess.TimeoutExpired:
            return self._record_failure("Sync timed out")
        except Exception as e:
            return self._record_failure(str(e))

    # ── Status / logging ──────────────────────────────────────────────────

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

    # ── Daemon loop ───────────────────────────────────────────────────────

    def handle_signal(self, signum, frame):
        """Handle shutdown signals: just request loop exit. The final sync
        runs in the main flow (run()) — never inside the signal handler,
        which could re-enter a sync already in progress."""
        self.log(f"Received signal {signum}, shutting down...")
        self.running = False

    def _sleep_interval(self):
        """Sleep sync_interval seconds in 1s slices so a shutdown signal is
        honored promptly (PEP 475 makes time.sleep resume after signals)."""
        for _ in range(self.sync_interval):
            if not self.running:
                return
            time.sleep(1)

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
                self._sleep_interval()

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

        # Final sync before exit (single shutdown mechanism — the systemd
        # unit has no ExecStop, so this cannot race another sync process).
        self.log("Performing final sync before shutdown...")
        success = self.sync_to_custom_layer()
        self.write_status()
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

        self.log("Layer sync daemon stopped")


def send_notification(title: str, message: str, urgency: str = "normal"):
    """Send desktop notification."""
    try:
        subprocess.run(
            ["notify-send", "-u", urgency, title, message],
            capture_output=True,
            timeout=5
        )
    except Exception:
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
        except Exception:
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
        # Serialized against any running daemon via the flock in
        # sync_to_custom_layer — safe to invoke while the daemon runs.
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
