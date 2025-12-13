#!/usr/bin/env python3
"""
HomeFS Command-Line Interface

User-facing commands for managing HomeFS filesystem.
"""

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Optional

from rich.console import Console
from rich.table import Table
from rich.progress import Progress

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

console = Console()


def parse_size(size_str: str) -> int:
    """
    Parse human-readable size to bytes.

    Examples: "4G", "100M", "512K"
    """
    units = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}

    size_str = size_str.strip().upper()

    if size_str[-1] in units:
        return int(float(size_str[:-1]) * units[size_str[-1]])
    else:
        return int(size_str)


def format_size(size_bytes: int) -> str:
    """Format bytes to human-readable size."""
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.2f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.2f} PB"


def format_time_ago(timestamp: Optional[float]) -> str:
    """Format timestamp as time ago."""
    if timestamp is None:
        return "Never"

    import time
    delta = time.time() - timestamp

    if delta < 60:
        return f"{int(delta)} seconds ago"
    elif delta < 3600:
        return f"{int(delta / 60)} minutes ago"
    elif delta < 86400:
        return f"{int(delta / 3600)} hours ago"
    else:
        return f"{int(delta / 86400)} days ago"


class HomeFSCLI:
    """HomeFS command-line interface."""

    def __init__(self):
        self.config_path = Path("/etc/homefs/config.json")
        self.status_path = Path("/var/run/homefs/status.json")

    def load_config(self) -> dict:
        """Load HomeFS configuration."""
        if not self.config_path.exists():
            console.print(f"[red]Error:[/red] Config not found: {self.config_path}")
            sys.exit(1)

        with open(self.config_path) as f:
            return json.load(f)

    def load_status(self) -> Optional[dict]:
        """Load current status."""
        if not self.status_path.exists():
            return None

        try:
            with open(self.status_path) as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Failed to load status: {e}")
            return None

    def cmd_status(self, args):
        """Show filesystem status."""
        status = self.load_status()

        if not status:
            console.print("[yellow]HomeFS is not running[/yellow]")
            return

        # Main status box
        console.print("\n[bold]HomeFS Status[/bold]")
        console.print("━" * 50)

        # USB status
        usb_state = status.get("sync", {}).get("state", "unknown")
        if usb_state == "connected":
            usb_icon = "[green]●[/green]"
        elif usb_state == "offline":
            usb_icon = "[yellow]○[/yellow]"
        else:
            usb_icon = "[red]✗[/red]"

        console.print(f"USB:           {usb_icon} {usb_state.title()}")

        # Safe to unplug?
        safe = status.get("sync", {}).get("safe_to_unplug", False)
        if safe:
            console.print(f"Safe to unplug: [green]Yes[/green]")
        else:
            console.print(f"Safe to unplug: [red]No[/red] (syncing...)")

        # Cache stats
        cache = status.get("cache", {})
        cache_size = cache.get("total_size", 0)
        cache_max = cache.get("max_size", 1)
        cache_pct = cache.get("usage_percent", 0)

        console.print(f"Cache:         {format_size(cache_size)} / {format_size(cache_max)} ({cache_pct:.1f}%)")

        # Pending writes
        pending = status.get("sync", {}).get("pending_transactions", 0)
        if pending > 0:
            console.print(f"Pending:       [yellow]{pending} transactions[/yellow]")
        else:
            console.print(f"Pending:       [green]None[/green]")

        # Last sync
        last_sync = status.get("sync", {}).get("last_sync")
        console.print(f"Last Sync:     {format_time_ago(last_sync)}")

        # Cache stats
        console.print("\n[bold]Cache Statistics[/bold]")
        console.print("━" * 50)

        console.print(f"Total entries:   {cache.get('total_entries', 0)}")
        console.print(f"Cached entries:  {cache.get('cached_entries', 0)}")
        console.print(f"Dirty entries:   {cache.get('dirty_entries', 0)}")
        console.print(f"Pinned entries:  {cache.get('pinned_entries', 0)}")

        hit_rate = cache.get("hit_rate", 0) * 100
        console.print(f"Hit rate:        {hit_rate:.1f}%")
        console.print(f"Evictions:       {cache.get('evictions', 0)}")

        # RAM pressure
        pressure = cache.get("ram_pressure", "OK")
        if pressure == "OK":
            pressure_color = "green"
        elif pressure == "HIGH":
            pressure_color = "yellow"
        else:
            pressure_color = "red"

        console.print(f"RAM pressure:    [{pressure_color}]{pressure}[/{pressure_color}]")

        console.print()

    def cmd_sync(self, args):
        """Force synchronization."""
        import os

        if args.daemon:
            # Run sync daemon in background
            console.print("[bold]Starting sync daemon...[/bold]")
            pid = os.fork()
            if pid > 0:
                console.print(f"Sync daemon started (PID: {pid})")
                return
            # Child - run sync loop
            os.setsid()

            # Simple sync daemon loop
            import time
            config = self.load_config()
            interval = config.get("sync", {}).get("batch_interval", 30)

            while True:
                try:
                    # Check if USB is connected
                    usb_status_file = Path("/var/run/homefs/usb-status")
                    if usb_status_file.exists():
                        status = usb_status_file.read_text().strip()
                        if status == "connected":
                            # Trigger sync (would call sync manager)
                            logger.info("Sync check - USB connected")
                except Exception as e:
                    logger.error(f"Sync daemon error: {e}")

                time.sleep(interval)
        else:
            console.print("[bold]Syncing to USB...[/bold]")
            # TODO: Trigger sync via IPC to running daemon
            console.print("[yellow]Sync triggered (not implemented)[/yellow]")

    def cmd_pin(self, args):
        """Pin files to prevent eviction."""
        if args.list:
            # List pinned files
            console.print("[bold]Pinned Files[/bold]")
            console.print("━" * 50)

            # TODO: Query daemon for pinned files
            console.print("[yellow]Not implemented[/yellow]")

        elif args.file:
            # Pin file
            console.print(f"[bold]Pinning:[/bold] {args.file}")

            # TODO: Send pin command to daemon
            console.print("[yellow]Not implemented[/yellow]")

    def cmd_unpin(self, args):
        """Unpin files."""
        console.print(f"[bold]Unpinning:[/bold] {args.file}")

        # TODO: Send unpin command to daemon
        console.print("[yellow]Not implemented[/yellow]")

    def cmd_cache(self, args):
        """Cache management."""
        if args.action == "list":
            # List cached files
            console.print("[bold]Cached Files[/bold]")
            console.print("━" * 50)

            # TODO: Query daemon for cache contents
            console.print("[yellow]Not implemented[/yellow]")

        elif args.action == "clear":
            # Clear cache
            console.print("[bold]Clearing cache...[/bold]")

            # TODO: Send clear command to daemon
            console.print("[yellow]Not implemented[/yellow]")

        elif args.action == "stats":
            # Show detailed stats
            status = self.load_status()
            if not status:
                console.print("[red]HomeFS not running[/red]")
                return

            cache = status.get("cache", {})

            table = Table(title="Cache Statistics")
            table.add_column("Metric", style="cyan")
            table.add_column("Value", style="green")

            table.add_row("Total Size", format_size(cache.get("total_size", 0)))
            table.add_row("Max Size", format_size(cache.get("max_size", 0)))
            table.add_row("Usage", f"{cache.get('usage_percent', 0):.1f}%")
            table.add_row("Total Entries", str(cache.get("total_entries", 0)))
            table.add_row("Cached Entries", str(cache.get("cached_entries", 0)))
            table.add_row("Dirty Entries", str(cache.get("dirty_entries", 0)))
            table.add_row("Pinned Entries", str(cache.get("pinned_entries", 0)))
            table.add_row("Cache Hits", str(cache.get("hits", 0)))
            table.add_row("Cache Misses", str(cache.get("misses", 0)))
            table.add_row("Hit Rate", f"{cache.get('hit_rate', 0) * 100:.1f}%")
            table.add_row("Evictions", str(cache.get("evictions", 0)))
            table.add_row("RAM Pressure", cache.get("ram_pressure", "UNKNOWN"))

            console.print(table)

    def cmd_conflicts(self, args):
        """Conflict management."""
        if args.action == "list":
            # List conflicts
            console.print("[bold]Conflicted Files[/bold]")
            console.print("━" * 50)

            # TODO: Query conflict directory
            console.print("[yellow]Not implemented[/yellow]")

        elif args.action == "resolve":
            # Resolve conflict
            console.print(f"[bold]Resolving conflict:[/bold] {args.file}")
            console.print(f"Strategy: {args.strategy}")

            # TODO: Implement conflict resolution
            console.print("[yellow]Not implemented[/yellow]")

    def cmd_mount(self, args):
        """Mount HomeFS."""
        import os

        # Load config
        config = self.load_config()

        # Override with command-line args
        if args.cache_size:
            config.setdefault("cache", {})["max_size"] = parse_size(args.cache_size)

        if args.read_only:
            config["read_only"] = True

        # Mount
        console.print(f"[bold]Mounting HomeFS[/bold]")
        console.print(f"USB:         {args.usb_device}")
        console.print(f"Mount point: {args.mount_point}")

        # Daemon mode - fork to background
        if args.daemon:
            pid = os.fork()
            if pid > 0:
                # Parent - exit
                console.print(f"HomeFS started in background (PID: {pid})")
                return
            # Child - continue to mount
            os.setsid()

        try:
            from .homefs import mount_homefs
            mount_homefs(args.usb_device, args.mount_point, config)
        except KeyboardInterrupt:
            console.print("\n[yellow]Unmounting...[/yellow]")
        except Exception as e:
            console.print(f"[red]Error:[/red] {e}")
            sys.exit(1)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="HomeFS - Lazy-Load Home Filesystem",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    subparsers = parser.add_subparsers(dest="command", help="Command")

    # Mount command
    mount_parser = subparsers.add_parser("mount", help="Mount HomeFS")
    mount_parser.add_argument("usb_device", help="USB device path (e.g., /dev/sdb2)")
    mount_parser.add_argument("mount_point", help="Where to mount (e.g., /home)")
    mount_parser.add_argument("--cache-size", help="Cache size (e.g., 4G)")
    mount_parser.add_argument("--read-only", action="store_true", help="Mount read-only")
    mount_parser.add_argument("--offline", action="store_true", help="Start in offline mode")
    mount_parser.add_argument("--daemon", action="store_true", help="Run in background")

    # Status command
    status_parser = subparsers.add_parser("status", help="Show filesystem status")

    # Sync command
    sync_parser = subparsers.add_parser("sync", help="Force sync to USB")
    sync_parser.add_argument("file", nargs="?", help="Sync specific file")
    sync_parser.add_argument("--dry-run", action="store_true", help="Show what would sync")
    sync_parser.add_argument("--daemon", action="store_true", help="Run sync daemon in background")

    # Pin command
    pin_parser = subparsers.add_parser("pin", help="Pin files to prevent eviction")
    pin_parser.add_argument("file", nargs="?", help="File to pin")
    pin_parser.add_argument("--list", action="store_true", help="List pinned files")

    # Unpin command
    unpin_parser = subparsers.add_parser("unpin", help="Unpin files")
    unpin_parser.add_argument("file", help="File to unpin")

    # Cache command
    cache_parser = subparsers.add_parser("cache", help="Cache management")
    cache_parser.add_argument("action", choices=["list", "clear", "stats"], help="Cache action")

    # Conflicts command
    conflicts_parser = subparsers.add_parser("conflicts", help="Conflict management")
    conflicts_parser.add_argument("action", choices=["list", "resolve"], help="Conflict action")
    conflicts_parser.add_argument("file", nargs="?", help="File with conflict")
    conflicts_parser.add_argument("--strategy", choices=["ram", "usb", "merge"], help="Resolution strategy")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Create CLI instance
    cli = HomeFSCLI()

    # Dispatch command
    if args.command == "mount":
        cli.cmd_mount(args)
    elif args.command == "status":
        cli.cmd_status(args)
    elif args.command == "sync":
        cli.cmd_sync(args)
    elif args.command == "pin":
        cli.cmd_pin(args)
    elif args.command == "unpin":
        cli.cmd_unpin(args)
    elif args.command == "cache":
        cli.cmd_cache(args)
    elif args.command == "conflicts":
        cli.cmd_conflicts(args)


if __name__ == "__main__":
    main()
