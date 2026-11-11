#!/usr/bin/env python3
"""powos-open-task: a Steam game's files are read ahead from the tap (board broforce-launch-time) - the install dir is
found through appmanifest/libraryfolders, code goes first, data smallest-first, and the cap holds."""
import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[2] / "targets/android/session/powos-open-task"


def load(run):
    os.environ["XDG_RUNTIME_DIR"] = run
    loader = importlib.machinery.SourceFileLoader("powos_open_task_prefetch", str(SOURCE))
    spec = importlib.util.spec_from_loader("powos_open_task_prefetch", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def put(path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)


class Prefetch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.mod = load(str(self.root / "run"))
        self.steam = self.root / "Steam"
        lib2 = self.root / "sd"
        (self.steam / "steamapps").mkdir(parents=True)
        (self.steam / "steamapps/libraryfolders.vdf").write_text(
            '"libraryfolders"\n{\n "0"\n {\n  "path"  "%s"\n }\n "1"\n {\n  "path"  "%s"\n }\n}\n' % (self.steam, lib2))
        (lib2 / "steamapps").mkdir(parents=True)
        (lib2 / "steamapps/appmanifest_274190.acf").write_text('"AppState"\n{\n "appid" "274190"\n "installdir" "Broforce"\n}\n')
        self.game = lib2 / "steamapps/common/Broforce"
        put(self.game / "Broforce_beta.exe", 600)
        put(self.game / "UnityPlayer.dll", 2000)
        put(self.game / "Broforce_beta_Data/Mono/EmbedRuntime/mono.dll", 900)
        put(self.game / "Broforce_beta_Data/globalgamemanagers", 100)
        put(self.game / "Broforce_beta_Data/sharedassets0.assets", 300)
        put(self.game / "Broforce_beta_Data/resources.assets", 5000)
        put(self.game / "empty.txt", 0)

    def tearDown(self):
        self.tmp.cleanup()

    def test_game_dir_from_second_library(self):
        self.assertEqual(self.mod.steam_game_dir("274190", str(self.steam)), str(self.game))
        self.assertIsNone(self.mod.steam_game_dir("999", str(self.steam)))

    def test_plan_order_and_cap(self):
        names = lambda plan: [os.path.basename(p) for p, _ in plan]
        everything = self.mod.prefetch_plan(str(self.game), 1 << 30)
        self.assertEqual(names(everything), ["Broforce_beta.exe", "UnityPlayer.dll", "mono.dll", "globalgamemanagers",
                                             "sharedassets0.assets", "resources.assets"])
        # 1700 bytes: UnityPlayer.dll (2000) is skipped but the smaller code after it and the small data still fit.
        capped = self.mod.prefetch_plan(str(self.game), 1700)
        self.assertEqual(names(capped), ["Broforce_beta.exe", "mono.dll", "globalgamemanagers"])
        self.assertLessEqual(sum(s for _, s in capped), 1700)

    def test_prefetch_runs_and_never_raises(self):
        if not hasattr(os, "posix_fadvise"):
            self.assertIsNone(self.mod.launch_prefetch("274190", str(self.steam)))
            return
        self.mod.PREFETCH_MB = 1
        self.mod.mem_available = lambda: 1 << 30
        t = self.mod.launch_prefetch("274190", str(self.steam))
        self.assertIsNotNone(t)
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertIsNone(self.mod.launch_prefetch("999", str(self.steam)))
        self.mod.PREFETCH_MB = 0
        self.assertIsNone(self.mod.launch_prefetch("274190", str(self.steam)))

    def test_caches_dir_goes_after_code_before_data(self):
        cache = self.game.parent.parent / "shadercache/274190/fex-emu/DiskCache/h"
        put(cache / "RWCacheDB_x.foz", 4000)
        put(cache / "RWCacheDB_x_idx.foz", 50)
        caches = self.mod.steam_shader_dir("274190", str(self.game))
        self.assertEqual(caches, str(self.game.parent.parent / "shadercache/274190"))
        self.assertIsNone(self.mod.steam_shader_dir("999", str(self.game)))
        names = [os.path.basename(p) for p, _ in self.mod.prefetch_plan(str(self.game), 1 << 30, caches)]
        self.assertEqual(names, ["Broforce_beta.exe", "UnityPlayer.dll", "mono.dll", "RWCacheDB_x.foz",
                                 "RWCacheDB_x_idx.foz", "globalgamemanagers", "sharedassets0.assets",
                                 "resources.assets"])

    def test_whole_file_is_read_ahead_not_just_one_window(self):
        """The kernel clamps one fadvise(WILLNEED) to the bdi's readahead window (5.15 force_page_cache_ra): one call
        with len 0 reads only the first window. Model that clamp and require every byte of every planned file."""
        if not hasattr(os, "posix_fadvise"):
            self.skipTest("no posix_fadvise")
        window = 1024
        covered = {}
        real = os.posix_fadvise

        def fake(fd, off, length, advice):
            self.assertEqual(advice, os.POSIX_FADV_WILLNEED)
            name = os.path.basename(os.readlink(f"/proc/self/fd/{fd}")) if os.path.exists("/proc/self/fd") else str(fd)
            size = os.fstat(fd).st_size
            end = min(size, off + min(length or size, window))  # what the kernel actually reads
            covered.setdefault(name, set()).update(range(off, end))

        self.mod.readahead_window = lambda fd: window
        self.mod.mem_available = lambda: 1 << 30
        self.mod.PREFETCH_MB = 1
        os.posix_fadvise = fake
        try:
            t = self.mod.launch_prefetch("274190", str(self.steam))
            t.join(5)
        finally:
            os.posix_fadvise = real
        if not os.path.exists("/proc/self/fd"):
            self.skipTest("no /proc/self/fd to name the files")
        self.assertEqual(len(covered["resources.assets"]), 5000, "resources.assets read ahead only partly")
        self.assertEqual(len(covered["UnityPlayer.dll"]), 2000)

    def test_window_from_the_bdi_with_a_floor(self):
        with open(self.game / "Broforce_beta.exe", "rb") as f:
            w = self.mod.readahead_window(f.fileno())
        self.assertGreaterEqual(w, 16 << 10)
        self.assertEqual(w % 1024, 0)


if __name__ == "__main__":
    unittest.main()
