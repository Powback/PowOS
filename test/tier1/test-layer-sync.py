#!/usr/bin/env python3
"""
Tests for lib/ramfs/layer-sync.py

Covers:
- rsync exit code 23 → sync returns False, last_sync NOT updated
- rsync exit code 0  → subprocess.run(["sync"]) called after
- rsync exit code 24 → treated as warning/success (True returned)
- rsync flags: -X/-A/-H present, NO --delete* and NO --partial* flags
- flush (sync) failure/timeout → whole sync treated as FAILURE
- consecutive_failures increments on failure, resets on success
- kernel-overlayfs whiteout semantics (char(0,0) devices, injected as a
  stubbed is_whiteout predicate since char devices need root to create):
  removal from custom layer, no deletion for literal ".wh.foo" filenames,
  opaque-dir clearing via stubbed opaque predicate
- count_changes() counts regular + whiteout entries, resets after a
  successful sync (pending = changes since last successful sync)
- destination mount guard (pre- and post-sync)
- global sync lock is honored (busy lock → skip, no rsync)
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ── Load lib/ramfs/layer-sync.py (hyphen in name prevents normal import) ──────
_REPO_ROOT = Path(__file__).parent.parent.parent
_LAYER_SYNC_PATH = _REPO_ROOT / "lib" / "ramfs" / "layer-sync.py"

spec = importlib.util.spec_from_file_location("layer_sync", str(_LAYER_SYNC_PATH))
layer_sync_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layer_sync_mod)

LayerSync = layer_sync_mod.LayerSync
_real_subprocess = subprocess  # keep reference for TimeoutExpired


# ── Helpers ────────────────────────────────────────────────────────────────────

def _make_syncer(tmpdir: str, **kwargs) -> "LayerSync":
    ram_upper = Path(tmpdir) / "upper"
    custom_layer = Path(tmpdir) / "custom"
    ram_upper.mkdir(parents=True, exist_ok=True)
    custom_layer.mkdir(parents=True, exist_ok=True)
    # NOTE: custom_layer.parent is not named "layers", so usb_mount stays
    # None and destination_available() falls back to existence checks —
    # exactly what we want in a tmpdir test environment.
    return LayerSync(ram_upper=ram_upper, custom_layer=custom_layer, **kwargs)


def _usb_state_file(tmpdir: str) -> Path:
    """Create a fake USB state file that reports USB connected."""
    state = Path(tmpdir) / "usb-state"
    state.write_text("USB_STATUS=connected\n")
    return state


def _ok(returncode: int = 0) -> MagicMock:
    r = MagicMock()
    r.returncode = returncode
    r.stderr = ""
    r.stdout = ""
    return r


def _flush_ok() -> MagicMock:
    """A mocked subprocess.run(['sync']) result that succeeded."""
    return _ok(0)


class _SyncTestBase(unittest.TestCase):
    """Common setup: connected USB state + lock file redirected to tmpdir."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        usb_state = _usb_state_file(self.tmpdir)
        self._patchers = [
            patch.object(layer_sync_mod, "USB_STATE_FILE", usb_state),
            patch.object(layer_sync_mod, "LOCK_FILE", Path(self.tmpdir) / "layer-sync.lock"),
        ]
        for p in self._patchers:
            p.start()
        self.syncer = _make_syncer(self.tmpdir)

    def tearDown(self):
        for p in self._patchers:
            p.stop()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: sync_to_custom_layer() – rsync exit codes
# ══════════════════════════════════════════════════════════════════════════════

class TestLayerSyncRsyncExitCodes(_SyncTestBase):

    # ── Exit code 23 ──────────────────────────────────────────────────────────

    def test_exit_23_returns_false(self):
        """rsync exit 23 (partial transfer) must return False."""
        with patch("subprocess.run", return_value=_ok(23)):
            with patch.object(layer_sync_mod, "send_notification"):
                result = self.syncer.sync_to_custom_layer()
        self.assertFalse(result)

    def test_exit_23_does_not_update_last_sync(self):
        """rsync exit 23 must NOT update last_sync (changes are not persisted)."""
        initial = self.syncer.last_sync  # 0

        with patch("subprocess.run", return_value=_ok(23)):
            with patch.object(layer_sync_mod, "send_notification"):
                self.syncer.sync_to_custom_layer()

        self.assertEqual(
            self.syncer.last_sync, initial,
            "last_sync must not be updated when rsync exits with code 23"
        )

    def test_exit_23_last_sync_success_false(self):
        """rsync exit 23 must mark last_sync_success=False."""
        with patch("subprocess.run", return_value=_ok(23)):
            with patch.object(layer_sync_mod, "send_notification"):
                self.syncer.sync_to_custom_layer()
        self.assertFalse(self.syncer.last_sync_success)

    # ── Exit code 0 ───────────────────────────────────────────────────────────

    def test_exit_0_returns_true(self):
        """rsync exit 0 must return True."""
        with patch("subprocess.run", side_effect=[_ok(0), _flush_ok()]):
            result = self.syncer.sync_to_custom_layer()
        self.assertTrue(result)

    def test_exit_0_calls_sync_flush(self):
        """rsync exit 0 must call subprocess.run(['sync']) to flush page cache."""
        with patch("subprocess.run", side_effect=[_ok(0), _flush_ok()]) as mock_run:
            self.syncer.sync_to_custom_layer()

        sync_calls = [c for c in mock_run.call_args_list if c.args[0] == ["sync"]]
        self.assertTrue(
            len(sync_calls) >= 1,
            "subprocess.run(['sync']) must be called after successful rsync to flush to disk"
        )

    def test_exit_0_updates_last_sync(self):
        """rsync exit 0 must update last_sync to a non-zero value."""
        with patch("subprocess.run", side_effect=[_ok(0), _flush_ok()]):
            self.syncer.sync_to_custom_layer()

        self.assertGreater(self.syncer.last_sync, 0)
        self.assertTrue(self.syncer.last_sync_success)

    # ── Exit code 24 ──────────────────────────────────────────────────────────

    def test_exit_24_returns_true(self):
        """rsync exit 24 (vanished files) is normal for overlayfs; must return True."""
        with patch("subprocess.run", side_effect=[_ok(24), _flush_ok()]):
            result = self.syncer.sync_to_custom_layer()
        self.assertTrue(result, "exit 24 should be treated as success/warning, not failure")

    def test_exit_24_updates_last_sync(self):
        """rsync exit 24 must update last_sync (considered successful)."""
        with patch("subprocess.run", side_effect=[_ok(24), _flush_ok()]):
            self.syncer.sync_to_custom_layer()

        self.assertGreater(self.syncer.last_sync, 0)
        self.assertTrue(self.syncer.last_sync_success)


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: rsync flags — additive sync, xattrs/ACLs/hardlinks
# ══════════════════════════════════════════════════════════════════════════════

class TestRsyncFlags(_SyncTestBase):

    def _run_and_get_cmd(self) -> list:
        with patch("subprocess.run", side_effect=[_ok(0), _flush_ok()]) as mock_run:
            self.syncer.sync_to_custom_layer()
        rsync_calls = [c for c in mock_run.call_args_list if c.args[0][0] == "rsync"]
        self.assertEqual(len(rsync_calls), 1, "exactly one rsync invocation expected")
        return rsync_calls[0].args[0]

    def test_no_delete_flag(self):
        """The sync must be ADDITIVE: the RAM upper is a fresh tmpfs each boot
        while the custom layer accumulates prior boots. ANY --delete* flag
        would erase the custom layer on the first sync of every boot."""
        cmd = self._run_and_get_cmd()
        offenders = [a for a in cmd if a.startswith("--delete")]
        self.assertEqual(offenders, [], f"rsync must not use delete flags, found: {offenders}")

    def test_no_partial_flag(self):
        """--partial without --partial-dir leaves truncated files in the
        custom layer on interruption; neither flag should be present."""
        cmd = self._run_and_get_cmd()
        offenders = [a for a in cmd if a.startswith("--partial")]
        self.assertEqual(offenders, [], f"rsync must not use --partial*, found: {offenders}")

    def test_xattr_acl_hardlink_flags_present(self):
        """-X (xattrs incl. SELinux + trusted.overlay.opaque), -A (ACLs),
        -H (hardlinks) must be present."""
        cmd = self._run_and_get_cmd()
        for flag in ("-X", "-A", "-H"):
            self.assertIn(flag, cmd, f"rsync flag {flag} missing from {cmd}")

    def test_archive_flag_present(self):
        """-a is required (includes --devices, which replicates whiteout
        char devices into the custom layer)."""
        cmd = self._run_and_get_cmd()
        self.assertIn("-a", cmd)


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: flush (sync) failure = sync failure
# ══════════════════════════════════════════════════════════════════════════════

class TestFlushFailure(_SyncTestBase):

    def test_flush_nonzero_exit_is_failure(self):
        """rsync ok but flush exits non-zero → whole sync must FAIL."""
        with patch("subprocess.run", side_effect=[_ok(0), _ok(1)]):
            with patch.object(layer_sync_mod, "send_notification"):
                result = self.syncer.sync_to_custom_layer()

        self.assertFalse(result, "a failed flush means data is not durable; sync must fail")
        self.assertFalse(self.syncer.last_sync_success)
        self.assertEqual(self.syncer.last_sync, 0, "last_sync must not update on flush failure")
        self.assertEqual(self.syncer.consecutive_failures, 1)

    def test_flush_timeout_is_failure(self):
        """rsync ok but flush times out → whole sync must FAIL."""
        def _side_effect(cmd, **kwargs):
            if cmd == ["sync"]:
                raise _real_subprocess.TimeoutExpired(cmd="sync", timeout=30)
            return _ok(0)

        with patch("subprocess.run", side_effect=_side_effect):
            with patch.object(layer_sync_mod, "send_notification"):
                result = self.syncer.sync_to_custom_layer()

        self.assertFalse(result)
        self.assertFalse(self.syncer.last_sync_success)


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: consecutive_failures counter
# ══════════════════════════════════════════════════════════════════════════════

class TestConsecutiveFailures(_SyncTestBase):

    def test_increments_on_each_failure(self):
        """consecutive_failures must increment by 1 for each failed sync."""
        self.assertEqual(self.syncer.consecutive_failures, 0)

        fail = _ok(23)
        fail.stderr = "partial transfer error"
        with patch("subprocess.run", return_value=fail):
            with patch.object(layer_sync_mod, "send_notification"):
                self.syncer.sync_to_custom_layer()
                self.assertEqual(self.syncer.consecutive_failures, 1)

                self.syncer.sync_to_custom_layer()
                self.assertEqual(self.syncer.consecutive_failures, 2)

    def test_resets_to_zero_on_success(self):
        """consecutive_failures must reset to 0 after a successful sync."""
        self.syncer.consecutive_failures = 2  # simulate prior failures

        with patch("subprocess.run", side_effect=[_ok(0), _flush_ok()]):
            result = self.syncer.sync_to_custom_layer()

        self.assertTrue(result)
        self.assertEqual(
            self.syncer.consecutive_failures, 0,
            "consecutive_failures must reset to 0 after a successful sync"
        )


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: kernel-overlayfs whiteout semantics (stubbed predicate)
#
#  Real whiteouts are char(0,0) devices, which cannot be created without root
#  on CI. The detection is a pure, injectable predicate — we stub it by
#  basename and test the surrounding logic.
# ══════════════════════════════════════════════════════════════════════════════

class TestWhiteouts(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.wh_names = set()      # basenames treated as whiteouts (upper side only)
        self.opaque_names = set()  # dir basenames treated as opaque

        def stub_whiteout(path: str) -> bool:
            # Only entries inside the RAM upper are stubbed as whiteouts;
            # the same basename in the custom layer is a real file
            # (apply_whiteouts also probes the custom side to skip
            # already-replicated whiteouts).
            return (os.path.basename(path) in self.wh_names
                    and str(self.syncer.ram_upper) in str(path))

        def stub_opaque(path: str) -> bool:
            return os.path.basename(path) in self.opaque_names

        self.syncer = _make_syncer(
            self.tmpdir,
            whiteout_check=lambda p: stub_whiteout(str(p)),
            opaque_check=lambda p: stub_opaque(str(p)),
        )

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _mark_whiteout(self, rel: str):
        """Create a stand-in whiteout entry in upper and register it."""
        p = self.syncer.ram_upper / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.touch()
        self.wh_names.add(os.path.basename(rel))

    def test_whiteout_removes_file_from_custom(self):
        """A whiteout in upper must delete the matching file in custom."""
        (self.syncer.custom_layer / "deleted.conf").write_text("old content")
        self._mark_whiteout("deleted.conf")

        ok = self.syncer.apply_whiteouts()

        self.assertTrue(ok)
        self.assertFalse((self.syncer.custom_layer / "deleted.conf").exists())

    def test_whiteout_removes_directory_tree_from_custom(self):
        """A whiteout over a directory must remove the whole tree in custom."""
        d = self.syncer.custom_layer / "olddir"
        (d / "nested").mkdir(parents=True)
        (d / "nested" / "f.txt").write_text("x")
        self._mark_whiteout("olddir")

        ok = self.syncer.apply_whiteouts()

        self.assertTrue(ok)
        self.assertFalse(d.exists())

    def test_whiteout_in_subdir(self):
        """Whiteouts in subdirectories map to the same relative path in custom."""
        target = self.syncer.custom_layer / "etc" / "conf.d" / "gone.conf"
        target.parent.mkdir(parents=True)
        target.write_text("bye")
        self._mark_whiteout("etc/conf.d/gone.conf")

        self.syncer.apply_whiteouts()

        self.assertFalse(target.exists())
        # Sibling dirs must survive
        self.assertTrue(target.parent.exists())

    def test_whiteout_with_no_counterpart_is_harmless(self):
        """A whiteout whose path doesn't exist in custom must not error."""
        self._mark_whiteout("never-existed.txt")
        self.assertTrue(self.syncer.apply_whiteouts())

    def test_literal_wh_prefixed_filename_is_a_regular_file(self):
        """A legit file literally named '.wh.foo' must NOT delete 'foo' —
        classification is by char(0,0) device, never by filename."""
        (self.syncer.custom_layer / "foo").write_text("keep me")
        (self.syncer.ram_upper / ".wh.foo").write_text("just a weirdly named file")
        # NOT registered as a whiteout

        self.syncer.apply_whiteouts()

        self.assertTrue((self.syncer.custom_layer / "foo").exists(),
                        "'.wh.foo' is a regular file under kernel overlayfs; 'foo' must survive")
        # And it counts as a regular changed file, not a whiteout
        self.assertIn(".wh.foo", self.syncer.get_changed_files())

    def test_opaque_dir_clears_custom_contents(self):
        """An opaque dir in upper must clear the matching custom dir's
        pre-existing contents (the dir itself stays; rsync -X copies the
        opaque xattr onto it afterwards)."""
        up_dir = self.syncer.ram_upper / "appcfg"
        up_dir.mkdir()
        (up_dir / "new.conf").write_text("new")

        cust_dir = self.syncer.custom_layer / "appcfg"
        cust_dir.mkdir()
        (cust_dir / "stale.conf").write_text("stale")
        (cust_dir / "staledir").mkdir()
        self.opaque_names.add("appcfg")

        ok = self.syncer.apply_whiteouts()

        self.assertTrue(ok)
        self.assertTrue(cust_dir.exists(), "opaque handling must keep the directory itself")
        self.assertEqual(list(cust_dir.iterdir()), [], "stale contents must be cleared")

    def test_get_changed_files_excludes_whiteouts(self):
        (self.syncer.ram_upper / "regular.txt").write_text("r")
        self._mark_whiteout("removed.txt")

        changed = self.syncer.get_changed_files()

        self.assertIn("regular.txt", changed)
        self.assertNotIn("removed.txt", changed)

    def test_default_predicate_rejects_regular_files(self):
        """The real is_whiteout() must be False for regular files and
        nonexistent paths (char(0,0) devices can't be made without root)."""
        f = Path(self.tmpdir) / "plain.txt"
        f.write_text("plain")
        self.assertFalse(layer_sync_mod.is_whiteout(str(f)))
        self.assertFalse(layer_sync_mod.is_whiteout(str(Path(self.tmpdir) / "missing")))


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: count_changes() – pending reflects changes since last successful sync
# ══════════════════════════════════════════════════════════════════════════════

class TestCountChanges(_SyncTestBase):

    def test_counts_regular_files(self):
        (self.syncer.ram_upper / "file_a.txt").write_text("content a")
        (self.syncer.ram_upper / "file_b.conf").write_text("content b")
        self.assertEqual(self.syncer.count_changes(), 2)

    def test_counts_whiteout_entries(self):
        """Whiteout entries (char devices in real life) are changes too —
        os.walk lists them in files, and they must be counted."""
        (self.syncer.ram_upper / "deleted_marker").touch()
        (self.syncer.ram_upper / "another_marker").touch()
        self.assertEqual(self.syncer.count_changes(), 2)

    def test_zero_for_empty_dir(self):
        self.assertEqual(self.syncer.count_changes(), 0)

    def test_counts_files_in_subdirs(self):
        subdir = self.syncer.ram_upper / "etc" / "conf.d"
        subdir.mkdir(parents=True)
        (subdir / "my.conf").write_text("conf")
        (subdir / "other.conf").write_text("conf2")
        self.assertEqual(self.syncer.count_changes(), 2)

    def test_pending_resets_after_successful_sync(self):
        """After a successful sync, previously-synced entries must no longer
        count as pending — `powos safe` must not report unsafe forever."""
        (self.syncer.ram_upper / "synced.txt").write_text("data")
        self.assertEqual(self.syncer.count_changes(), 1)

        time.sleep(0.05)  # ensure file mtime < sync start time
        with patch("subprocess.run", side_effect=[_ok(0), _flush_ok()]):
            self.assertTrue(self.syncer.sync_to_custom_layer())

        self.assertEqual(self.syncer.count_changes(), 0,
                         "entries synced successfully must not stay pending")

        # New changes after the sync become pending again
        time.sleep(0.05)
        (self.syncer.ram_upper / "new-after-sync.txt").write_text("later")
        self.assertEqual(self.syncer.count_changes(), 1)

    def test_pending_not_reset_by_failed_sync(self):
        (self.syncer.ram_upper / "unsynced.txt").write_text("data")

        with patch("subprocess.run", return_value=_ok(23)):
            with patch.object(layer_sync_mod, "send_notification"):
                self.syncer.sync_to_custom_layer()

        self.assertEqual(self.syncer.count_changes(), 1,
                         "a failed sync must leave changes pending")


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: destination mount guard
# ══════════════════════════════════════════════════════════════════════════════

class TestDestinationGuard(_SyncTestBase):

    def test_skips_sync_when_destination_not_mounted(self):
        """If the USB mount is gone before sync, no rsync must run."""
        # Point usb_mount at a path that is definitely not a mount point
        self.syncer.usb_mount = Path(self.tmpdir) / "not-a-mount"
        (Path(self.tmpdir) / "not-a-mount").mkdir()

        with patch("subprocess.run") as mock_run:
            result = self.syncer.sync_to_custom_layer()

        self.assertFalse(result)
        mock_run.assert_not_called()

    def test_fails_when_destination_vanishes_after_sync(self):
        """If the mount vanishes mid-sync, the sync must be marked failed even
        though the (now unbacked) directory path is still writable."""
        with patch.object(self.syncer, "destination_available", side_effect=[True, False]):
            with patch("subprocess.run", return_value=_ok(0)):
                with patch.object(layer_sync_mod, "send_notification"):
                    result = self.syncer.sync_to_custom_layer()

        self.assertFalse(result)
        self.assertFalse(self.syncer.last_sync_success)
        self.assertEqual(self.syncer.consecutive_failures, 1)

    def test_usb_mount_derived_from_standard_layout(self):
        """<mount>/layers/custom must derive usb_mount = <mount>."""
        s = LayerSync(
            ram_upper=Path(self.tmpdir) / "upper",
            custom_layer=Path(self.tmpdir) / "usbmnt" / "layers" / "custom",
        )
        self.assertEqual(s.usb_mount, Path(self.tmpdir) / "usbmnt")


# ══════════════════════════════════════════════════════════════════════════════
#  Tests: global sync lock
# ══════════════════════════════════════════════════════════════════════════════

class TestSyncLock(_SyncTestBase):

    def test_busy_lock_skips_sync(self):
        """If another sync holds the lock, no rsync must be spawned."""
        with patch.object(self.syncer, "_acquire_lock", return_value=None):
            with patch("subprocess.run") as mock_run:
                result = self.syncer.sync_to_custom_layer()

        self.assertFalse(result)
        mock_run.assert_not_called()

    def test_lock_released_after_sync(self):
        """The lock must be released even when the sync fails."""
        with patch.object(self.syncer, "_acquire_lock", return_value=-1) as m_acq:
            with patch.object(self.syncer, "_release_lock") as m_rel:
                with patch("subprocess.run", return_value=_ok(23)):
                    with patch.object(layer_sync_mod, "send_notification"):
                        self.syncer.sync_to_custom_layer()

        m_acq.assert_called_once()
        m_rel.assert_called_once_with(-1)


# ══════════════════════════════════════════════════════════════════════════════
#  Entry point
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    unittest.main(verbosity=2)
