#!/usr/bin/env python3
"""tools/agents/where eval: 8 real tasks from 11-23..11-26, fixed commit range.

Each task is ranked as of the commit BEFORE it (`where --before <parent>`: history up to the parent, the tree at the
parent), so the task's own commit message never leaks in. Expected = the files the task's commit touched that already
existed at the parent, minus the hubs every change touches (types.ts, gate.mjs, shots.mjs, shell.css, manifest,
strings, detekt baseline, registries) and docs/research. "app shortcuts" was in flight (agent/app-shortcuts, not yet
committed) when this was written: its expected files are that working tree's edits on top of ae0825d9.

Metrics: task hit = at least one expected file in the top 8; recall@8 = hits / min(8, expected). The test fails below
7/8 task hits or 45% mean recall (8/8 and 50% when written, 11-26). Needs the repo's git history: skips
in a checkout without it (the tier-1 job image copies the working tree only).
"""

import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
WHERE = os.path.join(ROOT, "tools", "agents", "where")
K = "targets/android/app/app/src/main/kotlin/dev/omalauncher/"
CASES = [
    ("lock media", "b860d6a1672b5fe452432dc01f212c8aa9451568",
     [".claude/skills/powos-shell/SKILL.md", "shell/bridge.ts", "shell/ui/control.tsx", "shell/ui/lock.tsx",
      K + "shell/LockFace.kt", K + "shell/ShellBridge.kt", K + "shell/ShellMedia.kt", K + "widgets/runtime/Media.kt",
      K + "widgets/runtime/Notifications.kt"]),
    ("app shortcuts", "ae0825d9777de25de5b977594638d832a98f7b7f",
     ["shell/bridge.ts", "shell/ui/apps.tsx", K + "shell/ShellBridge.kt"]),
    ("notification dots", "ae0825d9777de25de5b977594638d832a98f7b7f",
     ["shell/ui/apps.tsx", K + "shell/ShellBridge.kt", K + "widgets/runtime/Notifications.kt"]),
    ("control-center tiles", "d40cdeb2b14c16a6728966624a76a181909e2f3d",
     ["docs/REMOTE-POWOS.md", K + "shell/QuickSettings.kt", K + "system/KeyboardShotService.kt"]),
    ("camera ring", "0c32d305f140db90e980f8bc0892a5bac33d5e97",
     ["shell/ui/chrome.css", "shell/ui/chrome.tsx", K + "system/StatusChrome.kt"]),
    ("status bar", "cffe536e9a9ccee9e3fe59cfbdcbef34e6f5e77f",
     ["shell/bridge.ts", "shell/ui/chrome.css", "shell/ui/chrome.tsx", K + "shell/ChromeSlot.kt",
      K + "shell/ShellActivity.kt", K + "shell/ShellBridge.kt", K + "system/StatusChrome.kt"]),
    ("keyboard AI provider", "1c4812c0eb5c426efdd4ad2793b198ed5730e9cc",
     ["docs/POWAI-ASSISTANT.md", "lib/ai/manager/manager.sh", "lib/ai/manager/reply_drafts.py",
      K + "system/KeyboardAi.kt", K + "system/KeyboardAiProvider.kt",
      "targets/android/app/app/src/test/kotlin/dev/omalauncher/system/KeyboardAiTest.kt",
      "test/tier1/test-reply-drafts.py"]),
    ("Devices tab", "b3b62f186b4a3c90f0e8500b2704d51d8bff1720",
     ["docs/DEVICES.md", "lib/apps/powos-account-sync", "shell/apps/thisdevice.ts", "shell/ui/aimenu.tsx",
      "shell/ui/aipanes.tsx", "shell/ui/icons.tsx", K + "devices/PowStation.kt",
      "targets/android/app/app/src/test/kotlin/dev/omalauncher/devices/PowStationTest.kt"]),
]
MIN_TASK_HITS = 7
MIN_RECALL = 0.45


def main():
    os.chdir(ROOT)
    ok = subprocess.run(["git", "cat-file", "-e", CASES[0][1] + "^{commit}"], capture_output=True).returncode == 0
    if not ok:
        print("  SKIP test-where: no git history with the eval commits here (tier-1 image copies the tree only)")
        print("== Results: 0 passed, 0 failed ==")
        return 0
    passed = failed = 0
    hits, recalls = 0, []
    for q, rev, expect in CASES:
        out = subprocess.run([sys.executable, WHERE, "--json", "--before", rev, q], capture_output=True, text=True)
        if out.returncode != 0:
            print("  FAIL %s: where exited %d: %s" % (q, out.returncode, out.stderr[-300:]))
            failed += 1
            continue
        top = [r["file"] for r in json.loads(out.stdout)][:8]
        got = [f for f in expect if f in top]
        r = len(got) / min(8, len(expect))
        recalls.append(r)
        hits += bool(got)
        print("  %-4s %-22s recall@8 %d/%d  top: %s" % ("hit" if got else "MISS", q, len(got), min(8, len(expect)),
                                                        ", ".join(os.path.basename(f) for f in top)))
    mean = sum(recalls) / max(1, len(recalls))
    print("  where eval: %d/%d tasks hit, mean recall@8 %.0f%%" % (hits, len(CASES), 100 * mean))
    for name, cond in (("task hits >= %d" % MIN_TASK_HITS, hits >= MIN_TASK_HITS),
                       ("mean recall@8 >= %.0f%%" % (100 * MIN_RECALL), mean >= MIN_RECALL)):
        if cond:
            passed += 1
            print("  PASS %s" % name)
        else:
            failed += 1
            print("  FAIL %s" % name)
    print("== Results: %d passed, %d failed ==" % (passed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
