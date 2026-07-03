#!/usr/bin/env python3
"""
Tests for lib/cachefs/powos-cachefs.py  –  LRUCache class

Covers:
- Eviction when all files dirty → must raise ENOSPC, NOT infinite loop
- _evict_one() returns False when all items are dirty
- remove() decrements current_size and removes item from items dict
- Cache size tracking accuracy across add/remove cycles
"""

import errno
import importlib.util
import os
import signal
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock

# ── Mock fusepy BEFORE loading powos-cachefs.py ───────────────────────────────
# fusepy (fuse module) is not installed in the test/CI environment.  We stub it
# so the module-level "from fuse import FUSE, FuseOSError, Operations" succeeds.

class _FuseOSError(OSError):
    """Minimal stand-in for fusepy's FuseOSError."""
    def __init__(self, errno_val: int):
        super().__init__(errno_val, os.strerror(errno_val))
        self.errno = errno_val


_fake_fuse = MagicMock()
_fake_fuse.FuseOSError = _FuseOSError
_fake_fuse.FUSE = MagicMock()
_fake_fuse.Operations = object  # base class used by PowOSCacheFS

sys.modules.setdefault("fuse", _fake_fuse)

# ── Load lib/cachefs/powos-cachefs.py ─────────────────────────────────────────
_REPO_ROOT = Path(__file__).parent.parent.parent
_CACHEFS_PATH = _REPO_ROOT / "lib" / "cachefs" / "powos-cachefs.py"

spec = importlib.util.spec_from_file_location("powos_cachefs", str(_CACHEFS_PATH))
cachefs_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cachefs_mod)

LRUCache = cachefs_mod.LRUCache
FuseOSError = _FuseOSError  # the same class injected into the module


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: LRUCache
# ══════════════════════════════════════════════════════════════════════════════

class TestLRUCache(unittest.TestCase):

    # ── helpers ───────────────────────────────────────────────────────────────

    def _make_cache(self, cache_dir: str, max_size: int = 10_000) -> LRUCache:
        return LRUCache(cache_dir, max_size=max_size)

    def _write_source(self, directory: str, name: str, size: int) -> Path:
        """Write a source file of exactly *size* bytes and return its path."""
        p = Path(directory) / name
        p.write_bytes(b"x" * size)
        return p

    # ── eviction / ENOSPC ─────────────────────────────────────────────────────

    def test_all_dirty_raises_enospc_not_infinite_loop(self):
        """
        When the cache is full and every item is dirty (cannot be evicted),
        add() must raise FuseOSError(ENOSPC) and must NOT loop forever.

        A 5-second SIGALRM watchdog guards against an infinite-loop regression.
        """
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=100)

            # Fill the cache with a single dirty file (60 bytes)
            src1 = self._write_source(cache_dir, "src1.bin", 60)
            cache.add("file1", src1, 60)
            cache.mark_dirty("file1")  # mark as unsaved – prevents eviction

            # Prepare a second file that would exceed capacity
            src2 = self._write_source(cache_dir, "src2.bin", 60)

            # Install a watchdog timeout so a bug producing an infinite loop is
            # caught as a TimeoutError rather than hanging the test suite.
            def _watchdog(signum, frame):
                raise TimeoutError(
                    "add() did not terminate within 5 s – possible infinite loop"
                )

            old_handler = signal.signal(signal.SIGALRM, _watchdog)
            signal.alarm(5)
            try:
                with self.assertRaises(FuseOSError) as ctx:
                    cache.add("file2", src2, 60)
            finally:
                signal.alarm(0)
                signal.signal(signal.SIGALRM, old_handler)

            self.assertEqual(
                ctx.exception.errno, errno.ENOSPC,
                "FuseOSError must carry ENOSPC errno"
            )

    def test_evict_one_returns_false_when_all_dirty(self):
        """_evict_one() must return False when every cached item is dirty."""
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=1_000)

            src = self._write_source(cache_dir, "src.bin", 100)
            cache.add("f", src, 100)
            cache.mark_dirty("f")

            result = cache._evict_one()
            self.assertFalse(
                result,
                "_evict_one() must return False when all cached files are dirty"
            )

    def test_evict_one_succeeds_for_clean_file(self):
        """_evict_one() must return True when a clean (non-dirty) item exists."""
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=1_000)

            src = self._write_source(cache_dir, "src.bin", 100)
            cache.add("clean_file", src, 100)
            # leave it clean (not marked dirty)

            result = cache._evict_one()
            self.assertTrue(result, "_evict_one() should evict clean files")
            self.assertNotIn("clean_file", cache.items)

    # ── remove() ──────────────────────────────────────────────────────────────

    def test_remove_decrements_current_size(self):
        """remove() must subtract the file's size from current_size."""
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir)

            src = self._write_source(cache_dir, "src.bin", 250)
            cache.add("myfile", src, 250)
            self.assertEqual(cache.current_size, 250)

            cache.remove("myfile")
            self.assertEqual(
                cache.current_size, 0,
                "current_size must be 0 after removing the only cached file"
            )

    def test_remove_deletes_item_from_items_dict(self):
        """remove() must delete the entry from the internal items dict."""
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir)

            src = self._write_source(cache_dir, "src.bin", 100)
            cache.add("target", src, 100)
            self.assertIn("target", cache.items)

            cache.remove("target")
            self.assertNotIn("target", cache.items)

    def test_remove_nonexistent_is_noop(self):
        """remove() on an unknown key must not raise and must not change size."""
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir)
            before = cache.current_size

            cache.remove("does_not_exist")  # must not raise

            self.assertEqual(cache.current_size, before)

    # ── size tracking accuracy ─────────────────────────────────────────────────

    def test_size_tracking_across_add_remove_cycles(self):
        """current_size must stay accurate through multiple add/remove cycles."""
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=100_000)

            src1 = self._write_source(cache_dir, "s1.bin", 200)
            src2 = self._write_source(cache_dir, "s2.bin", 300)
            src3 = self._write_source(cache_dir, "s3.bin", 150)

            # Add three files
            cache.add("f1", src1, 200)
            self.assertEqual(cache.current_size, 200, "after adding 200-byte file")

            cache.add("f2", src2, 300)
            self.assertEqual(cache.current_size, 500, "after adding 300-byte file")

            # Remove one
            cache.remove("f1")
            self.assertEqual(cache.current_size, 300, "after removing 200-byte file")

            # Add a third
            cache.add("f3", src3, 150)
            self.assertEqual(cache.current_size, 450, "after adding 150-byte file")

            # Remove the remaining two
            cache.remove("f2")
            cache.remove("f3")
            self.assertEqual(
                cache.current_size, 0,
                "current_size must be 0 after all files are removed"
            )

    def test_size_tracking_with_multiple_files(self):
        """current_size must equal the sum of all added files' reported sizes."""
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=100_000)

            sizes = [100, 200, 50, 400, 75]
            for i, sz in enumerate(sizes):
                src = self._write_source(cache_dir, f"src{i}.bin", sz)
                cache.add(f"file{i}", src, sz)

            self.assertEqual(cache.current_size, sum(sizes))
            self.assertEqual(len(cache.items), len(sizes))

    # ── eviction respects LRU order ───────────────────────────────────────────

    def test_eviction_when_clean_file_exists(self):
        """
        add() must automatically evict a clean (non-dirty) file when the cache
        is full, rather than raising ENOSPC.
        """
        with tempfile.TemporaryDirectory() as cache_dir:
            # Max 100 bytes; add a 60-byte clean file, then add another 60-byte file
            cache = self._make_cache(cache_dir, max_size=100)

            src1 = self._write_source(cache_dir, "s1.bin", 60)
            src2 = self._write_source(cache_dir, "s2.bin", 60)

            cache.add("evictable", src1, 60)
            # evictable is clean (default) – must be evicted to make room

            cache.add("new_file", src2, 60)  # must not raise

            # evictable was evicted; new_file is present
            self.assertIn("new_file", cache.items)
            self.assertNotIn("evictable", cache.items)
            self.assertEqual(cache.current_size, 60)


# ══════════════════════════════════════════════════════════════════════════════
#  Entry point
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    unittest.main(verbosity=2)
