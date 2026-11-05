#!/usr/bin/env python3
"""queue.sh's shipped(): when a job's "need" commit counts as on the phone (11-05).

A docs/tools commit branched before the installed APK never waits for an APK ship (inst..c listed the APK's own newer
Kotlin -> "waits for its ship" forever); a commit in an origin tip the ship service processed with nothing to push
counts as shipped; a commit with APK inputs whose APK ship is held (phone offline, 11-04) keeps waiting.
"""
import os
import pathlib
import subprocess
import tempfile
import time
import unittest

CODE = (pathlib.Path(__file__).resolve().parents[2] / "tools/phone/verify/queue.sh").read_text()
START = CODE.index("  ship_paths() {")
FUNC = CODE[START:CODE.index("  # pause <summary>", START)]


def git(repo, *a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, check=True).stdout.strip()


def commit(repo, path, text, msg):
    p = pathlib.Path(repo, path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", msg)
    return git(repo, "rev-parse", "HEAD")


class Shipped(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = os.path.join(self.tmp.name, "vr")
        self.ship = os.path.join(self.tmp.name, "ship")
        os.makedirs(self.ship)
        git(self.tmp.name, "init", "-q", "-b", "main", self.repo)
        self.base = commit(self.repo, "targets/android/app/A.kt", "a", "base")
        commit(self.repo, "shell/x.js", "x", "shell base")
        self.base = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self):
        self.tmp.cleanup()

    def shipped(self, c, live=None, inst=None, processed=None):
        for name, v in (("live", live), ("processed", processed)):
            f = pathlib.Path(self.ship, name)
            f.write_text(v + "\n") if v else f.unlink(missing_ok=True)
        inst_f = pathlib.Path(self.tmp.name, "installed")
        inst_f.write_text((inst or "") + "\n")
        script = f'VR=$1\n{FUNC}\nshipped "$2" "$3"'
        env = dict(os.environ, SHIP_DIR=self.ship, INSTALLED_FILE=str(inst_f))
        r = subprocess.run(["bash", "-c", script, "t", self.repo, c, str(int(time.time()))], env=env,
                           capture_output=True, text=True)
        return r.returncode == 0

    def branch(self, name, start):
        git(self.repo, "checkout", "-q", "-b", name, start)

    def test_docs_commit_behind_installed_apk_is_shipped(self):
        # The installed APK (and live shell) carry a Kotlin change the docs commit's branch lacks.
        self.branch("apk", self.base)
        inst = commit(self.repo, "targets/android/app/VerifyRun.kt", "v", "apk change")
        self.branch("docs", self.base)
        docs = commit(self.repo, "docs/research/x.md", "d", "docs")
        git(self.repo, "checkout", "-q", "apk")
        git(self.repo, "-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "--no-edit", "docs")
        tip = git(self.repo, "rev-parse", "HEAD")
        self.assertTrue(self.shipped(docs, live=inst, inst=inst, processed=tip))
        self.assertTrue(self.shipped(docs, live=inst, inst=inst))  # no APK input in it at all: nothing to wait for

    def test_held_apk_keeps_waiting(self):
        # A commit with APK inputs; the APK ship was held (phone offline): installed build is still the old one,
        # though the ship service processed the tip containing it and found the shell part live.
        self.branch("kt", self.base)
        kt = commit(self.repo, "targets/android/app/Game.kt", "g", "kotlin")
        self.assertFalse(self.shipped(kt, live=kt, inst=self.base, processed=kt))
        self.assertTrue(self.shipped(kt, live=kt, inst=kt, processed=kt))

    def test_processed_tip_counts_for_the_shell(self):
        # live record is older and the commit changes shell: shipped only once a processed tip contains it.
        self.branch("sh", self.base)
        sh = commit(self.repo, "shell/y.js", "y", "shell")
        self.assertFalse(self.shipped(sh, live=self.base, inst=self.base))
        self.assertTrue(self.shipped(sh, live=self.base, inst=self.base, processed=sh))
        self.assertFalse(self.shipped(sh, live=self.base, inst=self.base, processed=self.base))

    def test_ship_service_records_processed(self):
        ship = (pathlib.Path(__file__).resolve().parents[2] / "tools/phone/ship.sh").read_text()
        i = ship.index("nothing differs from what's live")
        self.assertIn('echo "$T" > "$Q/processed"', ship[i - 900:i])


if __name__ == "__main__":
    unittest.main()
