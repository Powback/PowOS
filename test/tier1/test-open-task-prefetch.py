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


if __name__ == "__main__":
    unittest.main()
