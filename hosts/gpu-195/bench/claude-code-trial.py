#!/usr/bin/env python3
"""Small local harness smoke test, not a model-quality benchmark. Runs on the Mac.

Usage: python3 claude-code-trial.py MODEL /path/to/claude-local [CASE] [--shell]
Each case gets an isolated temporary workspace and Claude config. Tests remain
outside that workspace so an agent cannot accidentally rewrite its assertions.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

CASES = [
    ("intervals", "def merge_ranges(ranges):\n    return sorted(ranges)\n",
     "Implement merge_ranges in solution.py. Input is an iterable of (start, end) integer pairs. "
     "Return a list of (start, end) tuples, sorted by start, merging overlapping or touching closed ranges. Handle unsorted input, "
     "Touching means sharing an endpoint: [(1,2),(2,4)] merges to [(1,4)], "
     "but [(1,2),(3,4)] must remain separate. Handle "
     "duplicates, containment, empty input and generators. Reject start > end with ValueError. "
     "Do not mutate input. Read the file and edit it, then briefly report what changed.",
     """from solution import merge_ranges as f
assert f([]) == []
x = [(8,10),(1,4),(3,6),(6,8),(2,3)]
assert f(x) == [(1,10)] and x == [(8,10),(1,4),(3,6),(6,8),(2,3)]
assert f(iter([(5,5),(-4,-1),(-1,0),(5,5)])) == [(-4,0),(5,5)]
assert f([(1,2),(3,4)]) == [(1,2),(3,4)]
try: f([(4,2)])
except ValueError: pass
else: raise AssertionError('invalid range accepted')
"""),
    ("cache", "from collections import OrderedDict\n\nclass LRUCache:\n    def __init__(self, capacity):\n        self.capacity = capacity\n        self.items = OrderedDict()\n\n    def get(self, key, default=None):\n        return self.items.get(key, default)\n\n    def put(self, key, value):\n        self.items[key] = value\n",
     "Fix LRUCache in solution.py. get(key, default=None) returns the value and promotes hits to "
     "most recently used; misses return default without inserting. put updates/promotes an existing "
     "key or inserts a new one, evicting the least recently used entry beyond capacity. "
     "Capacity zero stores nothing; negative capacity raises ValueError. None is a valid value. "
     "Keep both operations O(1). Read and edit the file, then briefly report what changed.",
     """from solution import LRUCache
c = LRUCache(2)
c.put('a', None); c.put('b', 2)
assert c.get('a', 99) is None
c.put('c', 3)
assert c.get('b', 'miss') == 'miss'
c.put('a', 4); c.put('d', 5)
assert c.get('c') is None and c.get('a') == 4 and c.get('d') == 5
assert c.get('missing', 7) == 7
c.put('e', 6)
assert c.get('a') is None
z = LRUCache(0); z.put('x', 1); assert z.get('x') is None
try: LRUCache(-1)
except ValueError: pass
else: raise AssertionError('negative capacity accepted')
"""),
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model")
    parser.add_argument("launcher")
    parser.add_argument("case", nargs="?", choices=[c[0] for c in CASES])
    parser.add_argument("--shell", action="store_true", help="also allow Bash for model-written tests")
    parser.add_argument("--timeout", type=int, default=240, help="seconds per case, including model load")
    args = parser.parse_args()
    model, launcher, selected = args.model, args.launcher, args.case
    tool_names = "Read,Edit,Write,Bash" if args.shell else "Read,Edit,Write"
    root = Path(tempfile.mkdtemp(prefix=f"powos-trial-{model}-"))
    print(f"Artifacts: {root}", flush=True)
    results = []
    for name, initial, prompt, assertions in CASES:
        if selected and selected != name:
            continue
        work = root / name
        work.mkdir()
        (work / "solution.py").write_text(initial)
        env = dict(os.environ, CLAUDE_CONFIG_DIR=str(root / f"config-{name}"))
        env.pop("CLAUDECODE", None)
        if args.shell:
            prompt += " Work only in this directory. Use Python to test your changes before your final response."
        started = time.monotonic()
        try:
            trace_path = root / f"{name}-trace.jsonl"
            with trace_path.open("w") as trace:
                run = subprocess.run([launcher, model, "--setting-sources", "", "--strict-mcp-config",
                    "--mcp-config", '{"mcpServers":{}}', "--tools", tool_names,
                    "--allowedTools", tool_names, "--no-session-persistence", "--output-format", "stream-json",
                    "--verbose", "-p", prompt], cwd=work, env=env, text=True,
                    stdout=trace, stderr=subprocess.PIPE, timeout=args.timeout)
            response = {}
            for line in trace_path.read_text().splitlines():
                try:
                    event = json.loads(line)
                    if event.get("type") == "result":
                        response = event
                except ValueError:
                    pass
            (root / f"{name}-response.json").write_text(json.dumps(response, indent=2) + "\n")
            (root / f"{name}-stderr.txt").write_text(run.stderr)
            elapsed = round(time.monotonic() - started, 2)
            check = subprocess.run([sys.executable, "-c", assertions], cwd=work,
                                   text=True, capture_output=True, timeout=10)
            (root / f"{name}-assertions.py").write_text(assertions)
            (root / f"{name}-test.txt").write_text(check.stdout + check.stderr)
            result = dict(case=name, tools=tool_names, seconds=elapsed, cli_exit=run.returncode,
                          passed=check.returncode == 0 and run.returncode == 0 and response.get("is_error") is False,
                          assertions_passed=check.returncode == 0, turns=response.get("num_turns"),
                          usage=response.get("usage"), is_error=response.get("is_error"))
        except subprocess.TimeoutExpired:
            result = dict(case=name, tools=tool_names, seconds=args.timeout, passed=False, error="timeout")
        results.append(result)
        print(json.dumps(result), flush=True)
    (root / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(r["passed"] for r in results) else 1

if __name__ == "__main__":
    sys.exit(main())
