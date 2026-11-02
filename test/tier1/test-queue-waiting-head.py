#!/usr/bin/env python3
"""A queued job that waits for its ship never blocks the jobs behind it (11-02 deadlock).

Runs queue.sh's own select_jobs (the runner's per-window pick) with a fake shipped(): the head job's commit isn't on
the phone yet, the next ones are -> they run, the head is skipped (held) and picked again once it's shipped.
"""
import pathlib
import subprocess
import tempfile
import unittest

CODE = (pathlib.Path(__file__).resolve().parents[2] / "tools/phone/verify/queue.sh").read_text()
START = CODE.index("  select_jobs() {")
FUNC = CODE[START:CODE.index("    done; }", START) + len("    done; }")]


def pick(jobs, unshipped, go=""):
    """jobs: [(name, task, need)]; unshipped: needs not on the phone. Returns (selected names, held count)."""
    with tempfile.TemporaryDirectory() as d:
        q = pathlib.Path(d)
        for name, task, need in jobs:
            (q / f"{name}.job").write_text(f"task={task}\nneed={need}\nqt=0\n")
        cases = "|".join(unshipped) or "__none__"
        script = f'''Q=$1
shipped() {{ case "$1" in {cases}) return 1 ;; esac; return 0; }}
{FUNC}
select_jobs "$2" >/dev/null
for j in "${{sel[@]}}"; do basename "$j" .job; done
echo "held=$held"
'''
        out = subprocess.run(["bash", "-c", script, "test", d, go], capture_output=True, text=True, check=True).stdout.split()
        return out[:-1], int(out[-1].split("=")[1])


class WaitingHead(unittest.TestCase):
    JOBS = [("001", "smooth", "aaa"), ("002", "shade", "bbb"), ("003", "switcher", "ccc")]

    def test_waiting_head_does_not_block_next(self):
        self.assertEqual(pick(self.JOBS, ["aaa"]), (["002", "003"], 1))

    def test_head_runs_once_shipped(self):
        self.assertEqual(pick(self.JOBS, []), (["001", "002", "003"], 0))

    def test_all_waiting_selects_nothing(self):
        self.assertEqual(pick(self.JOBS, ["aaa", "bbb", "ccc"]), ([], 3))

    def test_test_now_of_waiting_task_runs_it(self):
        self.assertEqual(pick(self.JOBS, ["aaa"], go="smooth"), (["001"], 0))

    def test_runner_uses_select_jobs_and_skips_window_when_nothing_runs(self):
        self.assertIn('select_jobs "$go"', CODE)
        self.assertIn("! ( select_jobs \"\" >/dev/null; [ ${#sel[@]} -gt 0 ] )", CODE)


if __name__ == "__main__":
    unittest.main()
