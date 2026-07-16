#!/usr/bin/env python3
"""
CacheFS Sync Helper — thin wrapper for triggering CacheFS flushes.

The write-back engine lives inside the FUSE process (powos-cachefs.py).
This script provides CLI entry points for:
  --sync-now   Touch the flush trigger file; the FUSE process picks it up
  --status     Print the status JSON written by the FUSE process

Used by: powos flush, powos status, powos safe
"""

import json
import sys
import time
from pathlib import Path

STATUS_FILE = Path("/run/powos/cachefs-status.json")
FLUSH_TRIGGER = Path("/run/powos/cachefs-flush-now")


def sync_now() -> int:
    """Signal the running CacheFS FUSE process to flush immediately."""
    FLUSH_TRIGGER.parent.mkdir(parents=True, exist_ok=True)
    FLUSH_TRIGGER.touch()
    print("[cachefs-sync] Flush triggered")

    # Wait briefly for flush to complete (poll status file)
    deadline = time.time() + 10
    initial_ts = 0
    if STATUS_FILE.exists():
        try:
            initial_ts = json.loads(STATUS_FILE.read_text()).get("timestamp", 0)
        except Exception:
            pass

    while time.time() < deadline:
        time.sleep(0.5)
        if STATUS_FILE.exists():
            try:
                status = json.loads(STATUS_FILE.read_text())
                if status.get("timestamp", 0) > initial_ts:
                    dirty = status.get("dirty_files", 0)
                    if dirty == 0:
                        print("[cachefs-sync] Flush complete — 0 dirty files")
                        return 0
                    else:
                        print(f"[cachefs-sync] Flush completed — {dirty} files still dirty")
                        return 1
            except Exception:
                pass

    print("[cachefs-sync] Flush timed out (10s) — CacheFS may not be running")
    return 1


def show_status() -> int:
    """Print the CacheFS status JSON."""
    if STATUS_FILE.exists():
        print(STATUS_FILE.read_text())
        return 0
    else:
        print("No CacheFS status available (CacheFS not running)")
        return 1


def main():
    import argparse

    parser = argparse.ArgumentParser(description='CacheFS Sync Helper')
    parser.add_argument('--sync-now', action='store_true',
                        help='Trigger an immediate flush in the running CacheFS')
    parser.add_argument('--status', action='store_true',
                        help='Show CacheFS status')
    parser.add_argument('--cache-dir', default='/run/powos/cachefs',
                        help='(ignored, kept for CLI compat)')
    parser.add_argument('--backing-path', default='/mnt/powos-usb/home',
                        help='(ignored, kept for CLI compat)')

    args = parser.parse_args()

    if args.sync_now:
        return sync_now()
    elif args.status:
        return show_status()
    else:
        # Default: sync-now
        return sync_now()


if __name__ == '__main__':
    sys.exit(main())
