#!/usr/bin/env python3
"""
Tests for lib/ramfs/layer-sync.py

Covers:
- rsync exit code 23 → sync returns False, last_sync NOT updated
- rsync exit code 0  → subprocess.run(["sync"]) called after
- rsync exit code 24 → treated as warning/success (True returned)
- consecutive_failures increments on failure, resets on success
- count_changes() with whiteout files (.wh.*) always > 0
- count_changes() with mixed regular + whiteout files
"""

import errno
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, call, patch

# ── Load lib/ramfs/layer-sync.py (hyphen in name prevents normal import) ──────
_REPO_ROOT = Path(__file__).parent.parent.parent
_LAYER_SYNC_PATH = _REPO_ROOT / "lib" / "ramfs" / "layer-sync.py"

spec = importlib.util.spec_from_file_location("layer_sync", str(_LAYER_SYNC_PATH))
layer_sync_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layer_sync_mod)

LayerSync = layer_sync_mod.LayerSync
_real_subprocess = subprocess  # keep reference for TimeoutExpired


# ── Helper to build a LayerSync instance with a fresh temp dir ────────────────

def _make_syncer(tmpdir: str) -> "LayerSync":
    ram_upper = Path(tmpdir) / "upper"
    custom_layer = Path(tmpdir) / "custom"
    ram_upper.mkdir(parents=True, exist_ok=True)
    custom_layer.mkdir(parents=True, exist_ok=True)
    syncer = LayerSync(ram_upper=ram_upper, custom_layer=custom_layer)
    return syncer


def _usb_state_file(tmpdir: str) -> Path:
    """Create a fake USB state file that reports USB connected."""
    state = Path(tmpdir) / "usb-state"
    state.write_text("USB_STATUS=connected\n")
    return state


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: sync_to_custom_layer() – rsync exit codes
# ══════════════════════════════════════════════════════════════════════════════

class TestLayerSyncRsyncExitCodes(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        usb_state = _usb_state_file(self.tmpdir)
        # Patch module-level USB_STATE_FILE so is_usb_connected() returns True
        self._usb_patcher = patch.object(layer_sync_mod, "USB_STATE_FILE", usb_state)
        self._usb_patcher.start()
        self.syncer = _make_syncer(self.tmpdir)

    def tearDown(self):
        self._usb_patcher.stop()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _mock_rsync_result(self, returncode: int) -> MagicMock:
        r = MagicMock()
        r.returncode = returncode
        r.stderr = ""
        r.stdout = ""
        return r

    # ── Exit code 23 ──────────────────────────────────────────────────────────

    def test_exit_23_returns_false(self):
        """rsync exit 23 (partial transfer) must return False."""
        with patch("subprocess.run", return_value=self._mock_rsync_result(23)):
            with patch.object(layer_sync_mod, "send_notification"):
                result = self.syncer.sync_to_custom_layer()
        self.assertFalse(result)

    def test_exit_23_does_not_update_last_sync(self):
        """rsync exit 23 must NOT update last_sync (changes are not persisted)."""
        initial = self.syncer.last_sync  # 0

        with patch("subprocess.run", return_value=self._mock_rsync_result(23)):
            with patch.object(layer_sync_mod, "send_notification"):
                self.syncer.sync_to_custom_layer()

        self.assertEqual(
            self.syncer.last_sync, initial,
            "last_sync must not be updated when rsync exits with code 23"
        )

    def test_exit_23_last_sync_success_false(self):
        """rsync exit 23 must mark last_sync_success=False."""
        with patch("subprocess.run", return_value=self._mock_rsync_result(23)):
            with patch.object(layer_sync_mod, "send_notification"):
                self.syncer.sync_to_custom_layer()
        self.assertFalse(self.syncer.last_sync_success)

    # ── Exit code 0 ───────────────────────────────────────────────────────────

    def test_exit_0_returns_true(self):
        """rsync exit 0 must return True."""
        rsync_ok = self._mock_rsync_result(0)
        sync_flush = MagicMock()

        with patch("subprocess.run", side_effect=[rsync_ok, sync_flush]):
            result = self.syncer.sync_to_custom_layer()

        self.assertTrue(result)

    def test_exit_0_calls_sync_flush(self):
        """rsync exit 0 must call subprocess.run(['sync']) to flush page cache."""
        rsync_ok = self._mock_rsync_result(0)
        sync_flush = MagicMock()

        with patch("subprocess.run", side_effect=[rsync_ok, sync_flush]) as mock_run:
            self.syncer.sync_to_custom_layer()

        # Verify subprocess.run(["sync"], ...) was called
        sync_calls = [c for c in mock_run.call_args_list if c.args[0] == ["sync"]]
        self.assertTrue(
            len(sync_calls) >= 1,
            "subprocess.run(['sync']) must be called after successful rsync to flush to disk"
        )

    def test_exit_0_updates_last_sync(self):
        """rsync exit 0 must update last_sync to a non-zero value."""
        rsync_ok = self._mock_rsync_result(0)
        sync_flush = MagicMock()

        with patch("subprocess.run", side_effect=[rsync_ok, sync_flush]):
            self.syncer.sync_to_custom_layer()

        self.assertGreater(self.syncer.last_sync, 0)
        self.assertTrue(self.syncer.last_sync_success)

    # ── Exit code 24 ──────────────────────────────────────────────────────────

    def test_exit_24_returns_true(self):
        """rsync exit 24 (vanished files) is normal for overlayfs; must return True."""
        rsync_24 = self._mock_rsync_result(24)
        sync_flush = MagicMock()

        with patch("subprocess.run", side_effect=[rsync_24, sync_flush]):
            result = self.syncer.sync_to_custom_layer()

        self.assertTrue(result, "exit 24 should be treated as success/warning, not failure")

    def test_exit_24_updates_last_sync(self):
        """rsync exit 24 must update last_sync (considered successful)."""
        rsync_24 = self._mock_rsync_result(24)
        sync_flush = MagicMock()

        with patch("subprocess.run", side_effect=[rsync_24, sync_flush]):
            self.syncer.sync_to_custom_layer()

        self.assertGreater(self.syncer.last_sync, 0)
        self.assertTrue(self.syncer.last_sync_success)


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: consecutive_failures counter
# ══════════════════════════════════════════════════════════════════════════════

class TestConsecutiveFailures(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        usb_state = _usb_state_file(self.tmpdir)
        self._usb_patcher = patch.object(layer_sync_mod, "USB_STATE_FILE", usb_state)
        self._usb_patcher.start()
        self.syncer = _make_syncer(self.tmpdir)

    def tearDown(self):
        self._usb_patcher.stop()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _fail_result(self) -> MagicMock:
        r = MagicMock()
        r.returncode = 23
        r.stderr = "partial transfer error"
        r.stdout = ""
        return r

    def _ok_result(self) -> MagicMock:
        r = MagicMock()
        r.returncode = 0
        r.stderr = ""
        r.stdout = ""
        return r

    def test_increments_on_each_failure(self):
        """consecutive_failures must increment by 1 for each failed sync."""
        self.assertEqual(self.syncer.consecutive_failures, 0)

        fail = self._fail_result()
        with patch("subprocess.run", return_value=fail):
            with patch.object(layer_sync_mod, "send_notification"):
                self.syncer.sync_to_custom_layer()
                self.assertEqual(self.syncer.consecutive_failures, 1)

                self.syncer.sync_to_custom_layer()
                self.assertEqual(self.syncer.consecutive_failures, 2)

    def test_resets_to_zero_on_success(self):
        """consecutive_failures must reset to 0 after a successful sync."""
        self.syncer.consecutive_failures = 2  # simulate prior failures

        ok = self._ok_result()
        sync_flush = MagicMock()
        with patch("subprocess.run", side_effect=[ok, sync_flush]):
            result = self.syncer.sync_to_custom_layer()

        self.assertTrue(result)
        self.assertEqual(
            self.syncer.consecutive_failures, 0,
            "consecutive_failures must reset to 0 after a successful sync"
        )


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: count_changes() – whiteouts and regular files
# ══════════════════════════════════════════════════════════════════════════════

class TestCountChanges(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.syncer = _make_syncer(self.tmpdir)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_whiteout_only_produces_nonzero_count(self):
        """.wh.* (whiteout) files must contribute to count_changes() > 0."""
        # Only whiteout files – no regular files
        (self.syncer.ram_upper / ".wh.deleted_file.txt").touch()
        (self.syncer.ram_upper / ".wh.another_deleted").touch()

        count = self.syncer.count_changes()
        self.assertGreater(count, 0, "Whiteout files represent deletions and must be counted")

    def test_count_changes_counts_regular_files(self):
        """Regular files must be counted."""
        (self.syncer.ram_upper / "file_a.txt").write_text("content a")
        (self.syncer.ram_upper / "file_b.conf").write_text("content b")

        count = self.syncer.count_changes()
        self.assertEqual(count, 2)

    def test_count_changes_includes_both_regular_and_whiteouts(self):
        """count_changes() must sum regular files + whiteout files."""
        # 2 regular files
        (self.syncer.ram_upper / "regular1.txt").write_text("r1")
        (self.syncer.ram_upper / "regular2.txt").write_text("r2")
        # 1 whiteout
        (self.syncer.ram_upper / ".wh.removed.cfg").touch()

        count = self.syncer.count_changes()
        self.assertEqual(count, 3, "Should count 2 regular + 1 whiteout = 3")

    def test_count_changes_zero_for_empty_dir(self):
        """Empty RAM upper should produce count of 0."""
        # Ensure upper dir exists but is empty
        for f in self.syncer.ram_upper.iterdir():
            f.unlink()

        count = self.syncer.count_changes()
        self.assertEqual(count, 0)

    def test_count_changes_counts_files_in_subdirs(self):
        """count_changes() must recurse into subdirectories."""
        subdir = self.syncer.ram_upper / "etc" / "conf.d"
        subdir.mkdir(parents=True)
        (subdir / "my.conf").write_text("conf")
        (subdir / ".wh.old.conf").touch()

        count = self.syncer.count_changes()
        self.assertEqual(count, 2)


# ══════════════════════════════════════════════════════════════════════════════
#  Entry point
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    unittest.main(verbosity=2)
