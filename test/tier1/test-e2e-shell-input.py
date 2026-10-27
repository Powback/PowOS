#!/usr/bin/env python3
"""A device command must not consume the remaining tasks in a cleanup loop."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ShellInput(unittest.TestCase):
    def test_command_preserves_loop_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            adb = pathlib.Path(tmp) / "adb"
            adb.write_text("#!/bin/bash\ncat >/dev/null\n")
            adb.chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", '''source "$1/tools/phone/verify/e2e-lib.sh"
A=$2
while read -r task; do
  sh_ "am stack remove $task"
  echo "$task"
done <<EOF
101
102
103
EOF
''', "test", str(ROOT), str(adb)],
                text=True, capture_output=True, check=True,
            )
            self.assertEqual(result.stdout.splitlines(), ["101", "102", "103"])


if __name__ == "__main__":
    unittest.main()
