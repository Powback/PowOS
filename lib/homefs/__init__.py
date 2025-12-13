"""
HomeFS - Lazy-Load Home Filesystem for PowOS

A FUSE-based filesystem that enables RAM-based operation with on-demand
loading from USB storage. Supports offline operation and automatic sync
when USB is reconnected.
"""

__version__ = "0.1.0"
__author__ = "PowOS Team"

from .homefs import HomeFS
from .cache import CacheManager
from .journal import Journal
from .sync import SyncManager

__all__ = ["HomeFS", "CacheManager", "Journal", "SyncManager"]
