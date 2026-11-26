#!/usr/bin/env python3
"""tools/agents/efficiency.py queue_wait(): gate slot, build lock (build-slot, warm builder, Gradle pool) and verify
queue waits read from a synthetic transcript; the Gradle pool's "slot wait" is a build wait, never a gate one."""
import json, os, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools', 'agents'))
import efficiency as e

L = []
def use(i, ts, cmd): L.append({"type": "assistant", "timestamp": ts, "message": {"id": "m" + i, "content": [{"type": "tool_use", "id": i, "name": "Bash", "input": {"command": cmd}}]}})
def res(i, ts, txt): L.append({"type": "user", "timestamp": ts, "message": {"content": [{"type": "tool_result", "tool_use_id": i, "content": txt}]}})
use("1", "2026-11-25T10:00:00Z", "shell/dev/gate.sh"); res("1", "2026-11-25T10:05:00Z", "gate: got a slot after 40 s\ngate: summary: x; slot wait 40 s; tsc 3 s")
use("2", "2026-11-25T10:06:00Z", "tools/phone/compile-check.sh"); res("2", "2026-11-25T10:07:00Z", "warm-builder: got the build lock after 300 s\ngradle-pool: slot wait 7 s\nbuild-slot: got the heavy slot after 12s")
use("3", "2026-11-25T10:08:00Z", "tools/phone/verify/queue.sh wait 20261125-1 600"); res("3", "2026-11-25T10:10:30Z", "PASS")
with tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False) as f:
    f.write("\n".join(json.dumps(x) for x in L))
try:
    w = e.queue_wait(f.name)
finally:
    os.unlink(f.name)
want = {'gate_s': 40, 'build_s': 319, 'verify_s': 150, 'total_s': 509}
if w != want:
    print(f"FAIL queue_wait: {w} != {want}"); sys.exit(1)
print("ok   queue_wait: gate 40 s, build 319 s, verify 150 s")
