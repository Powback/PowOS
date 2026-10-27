#!/usr/bin/env python3
"""Task-specific test-now requests must not endlessly yield to excluded jobs."""
import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[2] / "tools/phone/verify/queue.sh"
CODE = SOURCE.read_text()
START = CODE.index('        for f in "$Q"/*.job; do', CODE.index('# A runnable job that sorts before'))
BLOCK = CODE[START:CODE.index('\n        done', START) + len('\n        done')]


class TaskSelection(unittest.TestCase):
    def run_selection(self, go, earlier_task, shipped=True):
        with tempfile.TemporaryDirectory() as directory:
            queue = pathlib.Path(directory)
            (queue / "001.job").write_text(f"task={earlier_task}\nneed=old\nqt=0\n")
            current = queue / "002.job"
            current.write_text("task=gestures\n")
            script = f'''Q=$1; go=$2; j="$Q/002.job"; sel=("$j")
shipped() {{ return {0 if shipped else 1}; }}
{BLOCK}
exit 0
'''
            return subprocess.run(["bash", "-c", script, "test", directory, go], capture_output=True).returncode

    def test_unrelated_job_does_not_starve_selected_task(self):
        self.assertEqual(self.run_selection("gestures", "games"), 0)

    def test_same_task_install_still_runs_first(self):
        self.assertEqual(self.run_selection("gestures", "gestures"), 4)

    def test_all_and_idle_keep_queue_order(self):
        for go in ("all", ""):
            with self.subTest(go=go):
                self.assertEqual(self.run_selection(go, "games"), 4)

    def test_unshipped_job_does_not_preempt(self):
        self.assertEqual(self.run_selection("all", "games", shipped=False), 0)


if __name__ == "__main__":
    unittest.main()
