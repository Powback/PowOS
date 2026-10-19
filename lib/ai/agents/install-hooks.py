#!/usr/bin/env python3
"""Adds the Agents view's reporter (claude-hooks.json) to a Claude Code settings file, keeping everything in it.

    install-hooks.py SETTINGS [--command CMD] [--ask CMD] [--backup PATH] [--remove]

Every hook event in claude-hooks.json gets one more matcher group running CMD (default: the hook file's own command,
/usr/lib/powos/ai/agents/powos-agent-hook), next to whatever hooks the file already has (the Mac's br-gate, say).
--ask also adds the PermissionRequest hook (powos-agent-ask: approvals from the phone, falling back to the terminal's
prompt when no one answers in time) - the one hook that waits, so only where an answer can come from.
Idempotent: groups running powos-agent-hook from an earlier install are replaced, nothing else is touched. --remove
takes them out again. The file is written tmp + rename; --backup copies the old one first (never over an existing
backup). Used by targets/android/rooted/powos-deploy.sh (the phone's ~powos/.claude) and for the Mac's ~/.claude (the
design doc, §4 Hook config).
"""

import argparse
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MARKS = ("powos-agent-hook", "powos-agent-ask")


def ours(group):
    return any(m in str(h.get("command", "")) for h in group.get("hooks", []) if isinstance(h, dict) for m in MARKS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("settings")
    ap.add_argument("--command")
    ap.add_argument("--ask")
    ap.add_argument("--backup")
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()

    with open(os.path.join(HERE, "claude-hooks.json")) as f:
        wanted = json.load(f)["hooks"]
    if a.ask:
        # Its own wait (powos-agent-ask: POWOS_AGENTS_ASK_TIMEOUT, 60 s) ends first; this is Claude's cap on it.
        wanted["PermissionRequest"] = [{"hooks": [{"type": "command", "command": a.ask, "timeout": 90}]}]
    try:
        with open(a.settings) as f:
            settings = json.load(f)
    except FileNotFoundError:
        settings = {}
    if not isinstance(settings, dict):
        sys.exit(f"{a.settings}: not a JSON object, left alone")

    hooks = settings.setdefault("hooks", {})
    for event in set(hooks) | set(wanted):
        groups = [g for g in hooks.get(event, []) if not (isinstance(g, dict) and ours(g))]
        if not a.remove and event in wanted:
            for g in wanted[event]:
                g = json.loads(json.dumps(g))
                if a.command:
                    for h in g["hooks"]:
                        h["command"] = a.command
                groups.append(g)
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    if not hooks:
        settings.pop("hooks")

    if a.backup and os.path.exists(a.settings) and not os.path.exists(a.backup):
        shutil.copy2(a.settings, a.backup)
    d = os.path.dirname(os.path.abspath(a.settings))
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".settings.json.agents-tmp")
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    if os.path.exists(a.settings):
        shutil.copymode(a.settings, tmp)
    os.replace(tmp, a.settings)
    print(f"{a.settings}: agents hooks {'removed' if a.remove else 'installed'}")


if __name__ == "__main__":
    main()
