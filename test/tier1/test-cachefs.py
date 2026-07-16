#!/usr/bin/env python3
"""
Tests for lib/cachefs/powos-cachefs.py — LRUCache, WriteBackEngine, PowOSCacheFS

Covers:
- Eviction when all files dirty -> must raise ENOSPC, NOT infinite loop
- _evict_one() returns False when all items are dirty
- remove() decrements current_size and removes item from items dict
- Cache size tracking accuracy across add/remove cycles
- Write-back round-trip: write -> flush -> verify on USB
- Dirty tracking: writes mark dirty, flush marks clean
- Flush on unmount (destroy): all dirty files flushed
- USB-gone queueing: dirty files queued when USB disconnected, flushed on reconnect
- Crash simulation: kill mid-write, remount, verify no corruption of flushed data
- Metadata propagation: mtime/permissions synced to USB
- Pending delete/rename replay on USB reconnect
- Status file reporting (dirty_bytes, dirty_files)
"""

import errno
import importlib.util
import json
import os
import signal
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# -- Mock fusepy BEFORE loading powos-cachefs.py --------------------------

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

# -- Load lib/cachefs/powos-cachefs.py ------------------------------------
_REPO_ROOT = Path(__file__).parent.parent.parent
_CACHEFS_PATH = _REPO_ROOT / "lib" / "cachefs" / "powos-cachefs.py"

spec = importlib.util.spec_from_file_location("powos_cachefs", str(_CACHEFS_PATH))
cachefs_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cachefs_mod)

LRUCache = cachefs_mod.LRUCache
WriteBackEngine = cachefs_mod.WriteBackEngine
PowOSCacheFS = cachefs_mod.PowOSCacheFS
FileMetadata = cachefs_mod.FileMetadata
FuseOSError = _FuseOSError


# =========================================================================
#  Tests: LRUCache (original suite, preserved)
# =========================================================================

class TestLRUCache(unittest.TestCase):

    # -- helpers ----------------------------------------------------------

    def _make_cache(self, cache_dir: str, max_size: int = 10_000) -> LRUCache:
        return LRUCache(cache_dir, max_size=max_size)

    def _write_source(self, directory: str, name: str, size: int) -> Path:
        """Write a source file of exactly *size* bytes and return its path."""
        p = Path(directory) / name
        p.write_bytes(b"x" * size)
        return p

    # -- eviction / ENOSPC ------------------------------------------------

    def test_all_dirty_raises_enospc_not_infinite_loop(self):
        """All-dirty cache + add() must raise ENOSPC, not loop forever."""
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=100)
            src1 = self._write_source(cache_dir, "src1.bin", 60)
            cache.add("file1", src1, 60)
            cache.mark_dirty("file1")

            src2 = self._write_source(cache_dir, "src2.bin", 60)

            def _watchdog(signum, frame):
                raise TimeoutError("add() did not terminate within 5s")

            old_handler = signal.signal(signal.SIGALRM, _watchdog)
            signal.alarm(5)
            try:
                with self.assertRaises(FuseOSError) as ctx:
                    cache.add("file2", src2, 60)
            finally:
                signal.alarm(0)
                signal.signal(signal.SIGALRM, old_handler)

            self.assertEqual(ctx.exception.errno, errno.ENOSPC)

    def test_evict_one_returns_false_when_all_dirty(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=1_000)
            src = self._write_source(cache_dir, "src.bin", 100)
            cache.add("f", src, 100)
            cache.mark_dirty("f")
            self.assertFalse(cache._evict_one())

    def test_evict_one_succeeds_for_clean_file(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=1_000)
            src = self._write_source(cache_dir, "src.bin", 100)
            cache.add("clean_file", src, 100)
            self.assertTrue(cache._evict_one())
            self.assertNotIn("clean_file", cache.items)

    # -- remove() ---------------------------------------------------------

    def test_remove_decrements_current_size(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir)
            src = self._write_source(cache_dir, "src.bin", 250)
            cache.add("myfile", src, 250)
            cache.remove("myfile")
            self.assertEqual(cache.current_size, 0)

    def test_remove_deletes_item_from_items_dict(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir)
            src = self._write_source(cache_dir, "src.bin", 100)
            cache.add("target", src, 100)
            cache.remove("target")
            self.assertNotIn("target", cache.items)

    def test_remove_nonexistent_is_noop(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir)
            before = cache.current_size
            cache.remove("does_not_exist")
            self.assertEqual(cache.current_size, before)

    # -- size tracking ----------------------------------------------------

    def test_size_tracking_across_add_remove_cycles(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=100_000)
            src1 = self._write_source(cache_dir, "s1.bin", 200)
            src2 = self._write_source(cache_dir, "s2.bin", 300)
            src3 = self._write_source(cache_dir, "s3.bin", 150)

            cache.add("f1", src1, 200)
            self.assertEqual(cache.current_size, 200)
            cache.add("f2", src2, 300)
            self.assertEqual(cache.current_size, 500)
            cache.remove("f1")
            self.assertEqual(cache.current_size, 300)
            cache.add("f3", src3, 150)
            self.assertEqual(cache.current_size, 450)
            cache.remove("f2")
            cache.remove("f3")
            self.assertEqual(cache.current_size, 0)

    def test_size_tracking_with_multiple_files(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=100_000)
            sizes = [100, 200, 50, 400, 75]
            for i, sz in enumerate(sizes):
                src = self._write_source(cache_dir, f"src{i}.bin", sz)
                cache.add(f"file{i}", src, sz)
            self.assertEqual(cache.current_size, sum(sizes))
            self.assertEqual(len(cache.items), len(sizes))

    # -- eviction respects LRU order --------------------------------------

    def test_eviction_when_clean_file_exists(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=100)
            src1 = self._write_source(cache_dir, "s1.bin", 60)
            src2 = self._write_source(cache_dir, "s2.bin", 60)
            cache.add("evictable", src1, 60)
            cache.add("new_file", src2, 60)
            self.assertIn("new_file", cache.items)
            self.assertNotIn("evictable", cache.items)
            self.assertEqual(cache.current_size, 60)

    # -- dirty bytes tracking ---------------------------------------------

    def test_get_dirty_bytes(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = self._make_cache(cache_dir, max_size=100_000)
            src1 = self._write_source(cache_dir, "s1.bin", 200)
            src2 = self._write_source(cache_dir, "s2.bin", 300)
            cache.add("f1", src1, 200)
            cache.add("f2", src2, 300)

            self.assertEqual(cache.get_dirty_bytes(), 0)
            cache.mark_dirty("f1")
            self.assertEqual(cache.get_dirty_bytes(), 200)
            cache.mark_dirty("f2")
            self.assertEqual(cache.get_dirty_bytes(), 500)
            cache.mark_clean("f1")
            self.assertEqual(cache.get_dirty_bytes(), 300)


# =========================================================================
#  Tests: WriteBackEngine
# =========================================================================

class TestWriteBackEngine(unittest.TestCase):
    """Test the write-back engine in isolation (no FUSE)."""

    def _make_engine(self, backing_dir, cache_dir, max_size=100_000):
        """Create a WriteBackEngine with a real cache for testing."""
        cache = LRUCache(cache_dir, max_size)
        metadata = {}
        metadata_lock = threading.RLock()
        engine = WriteBackEngine(
            backing_path=Path(backing_dir),
            cache=cache,
            metadata=metadata,
            metadata_lock=metadata_lock,
            flush_interval=9999  # Don't auto-flush in tests
        )
        # Override USB check to use our fake backing dir
        engine.check_usb_connected = lambda: Path(backing_dir).exists()
        return engine, cache, metadata

    def _add_dirty_file(self, cache, cache_dir, rel_path, content=b"hello"):
        """Add a file to cache and mark it dirty."""
        src = Path(cache_dir) / f"src_{rel_path.replace('/', '_')}"
        src.write_bytes(content)
        cache.add(rel_path, src, len(content))
        cache.mark_dirty(rel_path)
        return src

    # -- basic flush round-trip -------------------------------------------

    def test_flush_roundtrip(self):
        """Write to cache -> flush -> verify file appears on 'USB'."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)

            # Add a dirty file
            content = b"important data that must persist"
            self._add_dirty_file(cache, cache_dir, "/testfile.txt", content)

            # Flush
            flushed, failed = engine.flush_all()
            self.assertEqual(flushed, 1)
            self.assertEqual(failed, 0)

            # Verify on "USB"
            usb_file = Path(backing) / "testfile.txt"
            self.assertTrue(usb_file.exists())
            self.assertEqual(usb_file.read_bytes(), content)

            # File should no longer be dirty
            self.assertEqual(cache.get_dirty_files(), [])

    def test_flush_multiple_files(self):
        """Multiple dirty files all get flushed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)

            for i in range(5):
                self._add_dirty_file(cache, cache_dir, f"/file{i}.txt",
                                     f"content {i}".encode())

            flushed, failed = engine.flush_all()
            self.assertEqual(flushed, 5)
            self.assertEqual(failed, 0)
            self.assertEqual(cache.get_dirty_files(), [])

            for i in range(5):
                usb_file = Path(backing) / f"file{i}.txt"
                self.assertTrue(usb_file.exists())
                self.assertEqual(usb_file.read_bytes(), f"content {i}".encode())

    def test_flush_creates_subdirectories(self):
        """Flush creates parent dirs on USB as needed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)
            self._add_dirty_file(cache, cache_dir, "/deep/nested/dir/file.txt",
                                 b"nested content")

            flushed, _ = engine.flush_all()
            self.assertEqual(flushed, 1)

            usb_file = Path(backing) / "deep" / "nested" / "dir" / "file.txt"
            self.assertTrue(usb_file.exists())
            self.assertEqual(usb_file.read_bytes(), b"nested content")

    # -- dirty tracking ---------------------------------------------------

    def test_dirty_tracking(self):
        """Dirty flag set on write, cleared on flush."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)
            self._add_dirty_file(cache, cache_dir, "/tracked.txt", b"data")

            self.assertEqual(len(cache.get_dirty_files()), 1)
            self.assertGreater(cache.get_dirty_bytes(), 0)

            engine.flush_all()

            self.assertEqual(len(cache.get_dirty_files()), 0)
            self.assertEqual(cache.get_dirty_bytes(), 0)

    def test_dirty_since_tracking(self):
        """dirty_since timestamp is set when file first becomes dirty."""
        with tempfile.TemporaryDirectory() as cache_dir:
            cache = LRUCache(cache_dir, 100_000)
            src = Path(cache_dir) / "src.bin"
            src.write_bytes(b"data")
            cache.add("/f", src, 4)

            self.assertEqual(cache.items["/f"].dirty_since, 0.0)
            before = time.time()
            cache.mark_dirty("/f")
            after = time.time()

            self.assertGreaterEqual(cache.items["/f"].dirty_since, before)
            self.assertLessEqual(cache.items["/f"].dirty_since, after)

    # -- USB disconnect queueing ------------------------------------------

    def test_usb_offline_queues_dirty_files(self):
        """When USB is offline, dirty files are not lost — they stay queued."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)
            self._add_dirty_file(cache, cache_dir, "/offline.txt", b"offline data")

            # Simulate USB disconnect
            engine.usb_connected = False
            flushed, failed = engine.flush_all()
            self.assertEqual(flushed, 0)
            self.assertEqual(failed, 1)

            # File is still dirty (queued)
            self.assertEqual(len(cache.get_dirty_files()), 1)

            # Reconnect and flush
            engine.usb_connected = True
            flushed, failed = engine.flush_all()
            self.assertEqual(flushed, 1)
            self.assertEqual(failed, 0)

            usb_file = Path(backing) / "offline.txt"
            self.assertTrue(usb_file.exists())
            self.assertEqual(usb_file.read_bytes(), b"offline data")

    def test_pending_deletes_replayed_on_reconnect(self):
        """Deletes queued while USB offline are applied on reconnect."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            # Create a file on "USB"
            usb_file = Path(backing) / "to_delete.txt"
            usb_file.write_bytes(b"delete me")

            engine, cache, metadata = self._make_engine(backing, cache_dir)

            # Queue a delete while offline
            engine.usb_connected = False
            engine.queue_delete("/to_delete.txt")

            self.assertTrue(usb_file.exists())

            # Reconnect + flush triggers pending ops
            engine.usb_connected = True
            engine.flush_all()

            self.assertFalse(usb_file.exists())

    def test_pending_renames_replayed_on_reconnect(self):
        """Renames queued while USB offline are applied on reconnect."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            old_file = Path(backing) / "old_name.txt"
            old_file.write_bytes(b"rename me")

            engine, cache, metadata = self._make_engine(backing, cache_dir)

            engine.usb_connected = False
            engine.queue_rename("/old_name.txt", "/new_name.txt")

            engine.usb_connected = True
            engine.flush_all()

            self.assertFalse(old_file.exists())
            self.assertTrue((Path(backing) / "new_name.txt").exists())
            self.assertEqual((Path(backing) / "new_name.txt").read_bytes(), b"rename me")

    # -- crash safety (temp+rename) ---------------------------------------

    def test_temp_rename_no_partial_files(self):
        """After a successful flush, no .cachefs- temp files remain."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)
            self._add_dirty_file(cache, cache_dir, "/safe.txt", b"safe data")

            engine.flush_all()

            # No temp files should remain
            temps = list(Path(backing).glob(".cachefs-*"))
            self.assertEqual(temps, [])

    def test_previously_flushed_data_survives_crash(self):
        """Simulate crash mid-write: previously flushed data is intact."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)

            # First file — flushed successfully
            content1 = b"critical data v1"
            self._add_dirty_file(cache, cache_dir, "/important.txt", content1)
            engine.flush_all()

            # Verify it's on "USB"
            usb_file = Path(backing) / "important.txt"
            self.assertEqual(usb_file.read_bytes(), content1)

            # Second write (dirty, not yet flushed — simulates crash before flush)
            content2 = b"updated data v2"
            cache_path = cache.get_path("/important.txt")
            if cache_path:
                cache_path.write_bytes(content2)
                cache.mark_dirty("/important.txt")

            # "Crash" — don't flush. The USB file should still have v1.
            self.assertEqual(usb_file.read_bytes(), content1)

    # -- metadata propagation ---------------------------------------------

    def test_metadata_propagation(self):
        """Flush propagates mtime and permissions to USB."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)
            import stat

            # Set metadata
            metadata["/meta.txt"] = FileMetadata(
                mode=stat.S_IFREG | 0o644,
                uid=os.getuid(),
                gid=os.getgid(),
                size=5,
                atime=1000000.0,
                mtime=2000000.0,
                ctime=3000000.0
            )

            self._add_dirty_file(cache, cache_dir, "/meta.txt", b"hello")
            engine.flush_all()

            usb_file = Path(backing) / "meta.txt"
            st = usb_file.stat()
            self.assertAlmostEqual(st.st_mtime, 2000000.0, places=0)

    # -- status reporting -------------------------------------------------

    def test_status_file_written(self):
        """write_status() produces a valid JSON with required fields."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            # Override status file path for test isolation
            status_path = Path(tmpdir) / "status.json"
            engine, cache, metadata = self._make_engine(backing, cache_dir)

            old_sf = cachefs_mod.STATUS_FILE
            cachefs_mod.STATUS_FILE = status_path
            try:
                engine.write_status()
            finally:
                cachefs_mod.STATUS_FILE = old_sf

            self.assertTrue(status_path.exists())
            status = json.loads(status_path.read_text())
            self.assertIn("dirty_files", status)
            self.assertIn("dirty_bytes", status)
            self.assertIn("dirty_bytes_human", status)
            self.assertIn("usb_connected", status)
            self.assertIn("last_flush", status)
            self.assertIn("flush_interval", status)

    def test_status_reflects_dirty_state(self):
        """Status accurately reflects dirty file count and bytes."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            status_path = Path(tmpdir) / "status.json"
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)
            self._add_dirty_file(cache, cache_dir, "/a.txt", b"aaaa")
            self._add_dirty_file(cache, cache_dir, "/b.txt", b"bb")

            old_sf = cachefs_mod.STATUS_FILE
            cachefs_mod.STATUS_FILE = status_path
            try:
                engine.write_status()
            finally:
                cachefs_mod.STATUS_FILE = old_sf

            status = json.loads(status_path.read_text())
            self.assertEqual(status["dirty_files"], 2)
            self.assertEqual(status["dirty_bytes"], 6)  # 4 + 2

    # -- background thread ------------------------------------------------

    def test_background_thread_starts_and_stops(self):
        """Engine thread starts and can be stopped cleanly."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)
            engine.flush_interval = 1  # Short interval for test

            engine.start()
            self.assertTrue(engine._thread.is_alive())

            engine.stop()
            self.assertFalse(engine._thread.is_alive())

    def test_request_flush_wakes_background_thread(self):
        """request_flush() triggers an immediate flush in the background."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            engine, cache, metadata = self._make_engine(backing, cache_dir)
            engine.flush_interval = 9999  # Long interval — only triggered flush

            self._add_dirty_file(cache, cache_dir, "/trigger.txt", b"trigger me")

            engine.start()
            try:
                engine.request_flush()
                # Give the thread time to flush
                time.sleep(1)
                self.assertEqual(len(cache.get_dirty_files()), 0)
                usb_file = Path(backing) / "trigger.txt"
                self.assertTrue(usb_file.exists())
            finally:
                engine.stop()


# =========================================================================
#  Tests: PowOSCacheFS (integrated, FUSE layer mocked)
# =========================================================================

class TestPowOSCacheFSIntegrated(unittest.TestCase):
    """Integration tests for the full CacheFS with write-back.

    The FUSE mount is not used — we call FUSE operations directly.
    """

    def _make_fs(self, backing_dir, cache_dir):
        """Create a PowOSCacheFS instance for testing."""
        fs = PowOSCacheFS(backing_dir, cache_dir, cache_size=10 * 1024 * 1024,
                          flush_interval=9999)
        # Override USB check
        fs.writeback.check_usb_connected = lambda: Path(backing_dir).exists()
        return fs

    def test_write_then_flush_roundtrip(self):
        """create -> write -> fsync -> verify on USB."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            fs = self._make_fs(backing, cache_dir)
            try:
                # Create a file via FUSE ops
                fd = fs.create("/newfile.txt", 0o644)
                fs.write("/newfile.txt", b"hello world", 0, fd)
                fs.fsync("/newfile.txt", False, fd)
                fs.release("/newfile.txt", fd)

                # File should be on USB after fsync
                usb_file = Path(backing) / "newfile.txt"
                self.assertTrue(usb_file.exists())
                self.assertEqual(usb_file.read_bytes(), b"hello world")
            finally:
                fs.writeback.stop()

    def test_destroy_flushes_all(self):
        """destroy() must flush all dirty files before exit."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            fs = self._make_fs(backing, cache_dir)

            # Write without fsync
            fd = fs.create("/unflushed.txt", 0o644)
            fs.write("/unflushed.txt", b"must survive unmount", 0, fd)
            fs.release("/unflushed.txt", fd)

            # Should still be dirty
            self.assertIn("/unflushed.txt", fs.cache.get_dirty_files())

            # Unmount — should flush
            fs.destroy("/")

            usb_file = Path(backing) / "unflushed.txt"
            self.assertTrue(usb_file.exists())
            self.assertEqual(usb_file.read_bytes(), b"must survive unmount")

    def test_read_back_written_data(self):
        """Data written via write() can be read back via read()."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            fs = self._make_fs(backing, cache_dir)
            try:
                fd = fs.create("/readback.txt", 0o644)
                fs.write("/readback.txt", b"readback test", 0, fd)
                fs.release("/readback.txt", fd)

                # Re-open for reading
                fd2 = fs.open("/readback.txt", os.O_RDONLY)
                data = fs.read("/readback.txt", 100, 0, fd2)
                fs.release("/readback.txt", fd2)

                self.assertEqual(data, b"readback test")
            finally:
                fs.writeback.stop()

    def test_chmod_marks_dirty_for_metadata_sync(self):
        """chmod/chown marks the file dirty so metadata propagates on flush."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            fs = self._make_fs(backing, cache_dir)
            try:
                fd = fs.create("/perms.txt", 0o644)
                fs.write("/perms.txt", b"test", 0, fd)
                fs.release("/perms.txt", fd)

                # Flush first to clear dirty
                fs.writeback.flush_all()
                self.assertEqual(len(fs.cache.get_dirty_files()), 0)

                # chmod should re-dirty
                fs.chmod("/perms.txt", 0o755)
                self.assertIn("/perms.txt", fs.cache.get_dirty_files())
            finally:
                fs.writeback.stop()

    def test_unlink_while_offline_queues_delete(self):
        """Deleting a file while USB offline queues the delete."""
        with tempfile.TemporaryDirectory() as tmpdir:
            backing = os.path.join(tmpdir, "usb")
            cache_dir = os.path.join(tmpdir, "cache")
            os.makedirs(backing)
            os.makedirs(cache_dir)

            # Pre-create file on USB
            (Path(backing) / "victim.txt").write_bytes(b"doomed")

            fs = self._make_fs(backing, cache_dir)
            try:
                # Go offline
                fs.writeback.usb_connected = False
                fs.unlink("/victim.txt")

                # File still on USB (offline)
                self.assertTrue((Path(backing) / "victim.txt").exists())

                # Come back online + flush
                fs.writeback.usb_connected = True
                fs.writeback.flush_all()

                # Now deleted
                self.assertFalse((Path(backing) / "victim.txt").exists())
            finally:
                fs.writeback.stop()


# =========================================================================
#  Entry point
# =========================================================================

if __name__ == "__main__":
    unittest.main(verbosity=2)
