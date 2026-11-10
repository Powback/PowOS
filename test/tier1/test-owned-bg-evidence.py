#!/usr/bin/env python3
import pathlib
import subprocess
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]

class Evidence(unittest.TestCase):
    def test_ids_ignore_order_but_keep_task_replacement(self):
        src = (ROOT / 'tools/phone/verify/switcher-owned-bg.sh').read_text()
        body = src.split('task_ids() {',1)[1].split('\n}',1)[0]
        def ids(text):
            return subprocess.run(['bash','-c','pkg=com.powos.verifybackground; '+body], input=text, text=True, capture_output=True, check=True).stdout
        first = ' * Recent #0: Task{abc #3363 type=undefined A=10359:com.powos.app.shell}\n * Recent #1: Task{def #3414 type=standard A=10362:com.termux}\n'
        reordered = ' * Recent #0: Task{newhash #3414 type=standard A=10362:com.termux}\n * Recent #2: Task{abcd #3363 type=undefined A=10359:com.powos.app.shell}\n'
        self.assertEqual(ids(first), ids(reordered))
        self.assertNotEqual(ids(first), ids(first.replace('#3363 ', '#3422 ')))
        self.assertIn('tasks_snapshot before',src)
        self.assertIn('tasks_snapshot after',src)
        self.assertIn('diff -u "$OUT/task-ids-before.txt" "$OUT/task-ids-after.txt"',src)
        self.assertIn('FAIL: pre-existing task identities changed',src)

if __name__ == '__main__': unittest.main()
