#!/usr/bin/env python3
"""agent-notices.py: carries short notices onto the agent's NEXT tool result instead of it polling for them
(docs/AGENT-HANDBOOK.md, Overhead lessons). A PostToolUse hook (.claude/settings.json, project-level: every
worktree's agents get it).

Modeled on nofate/br's runner.ts toolResultNotice (~/Projects/nofate/br/agent/src/runner.ts:1030-1056) and
SpaceTimeAI's agents/worker/session/inbox.ts: one short "[tag] ..." line per source, shown once (deduped
against a state file), returned as hookSpecificOutput.additionalContext so the model sees it with the tool
result that happened to come next - no idle.sh --wait, no re-reading a log, no polling.

Sources, LOCAL FILE READS ONLY (no adb/network - keeps this fast and safe to run on every tool call):
  comms   ~/.local/state/powos/comms/agents/<role>/inbox/*.json       role: COMMS_AGENT_ID or POWOS_AGENTS_ROLE
                                                                       env, else this worktree's basename
                                                                       (same fallback lib/ai/agents/powos-agent-hook uses)
  verify  ~/.cache/powos-verify-queue/done/*.job  whose from= is this worktree's root (tools/phone/verify/queue.sh)
  ship    ~/.cache/powos-ship-queue/done/*.req    whose who= is this worktree's basename (tools/phone/ship.sh)

Fail-silent: any error, or no stdin JSON, or nothing new -> print nothing, exit 0. Never blocks or breaks a
tool call (docs/AGENT-HANDBOOK.md, Rules: a broken reporter must never break a session).
"""
import glob
import json
import os
import sys

MAX_NOTICES = 8
MAX_SEEN = 500


def _fields(path):
    """A verify .job or ship .req file: key=value lines (bash's own %q escaping, plain for the simple values
    this script reads - from/who/task/note/result never contain a literal newline or an unescaped quote in
    practice; a line that doesn't parse is just skipped)."""
    out = {}
    try:
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("cmd="):
                    k, _, v = line.partition("=")
                    out[k] = v.strip("'\"")
    except OSError:
        pass
    return out


def _last_line(path, limit=140):
    try:
        with open(path, errors="replace") as f:
            lines = [l.strip() for l in f if l.strip()]
        return lines[-1][:limit] if lines else "(no output)"
    except OSError:
        return "(no log)"


def main():
    try:
        inp = json.load(sys.stdin)
    except Exception:
        return
    cwd = (inp.get("cwd") or os.getcwd()).rstrip("/")
    basename = os.path.basename(cwd) or "repo"
    role = os.environ.get("COMMS_AGENT_ID") or os.environ.get("POWOS_AGENTS_ROLE") or basename

    home = os.path.expanduser("~")
    state_dir = os.path.join(home, ".cache", "powos-agent-notices")
    try:
        os.makedirs(state_dir, exist_ok=True)
    except OSError:
        return
    state_path = os.path.join(state_dir, basename + ".json")
    try:
        with open(state_path) as f:
            seen = set(json.load(f))
    except Exception:
        seen = set()
    new_seen = set(seen)
    notices = []

    # 1. comms mail for this agent's role.
    try:
        xdg = os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state")
        inbox = os.path.join(xdg, "powos", "comms", "agents", role, "inbox")
        for p in sorted(glob.glob(os.path.join(inbox, "*.json")))[:20]:
            key = "mail:" + os.path.basename(p)
            if key in seen:
                continue
            new_seen.add(key)
            try:
                with open(p) as f:
                    m = json.load(f)
                body = (m.get("body") or "").strip().replace("\n", " ")[:160]
                notices.append(f"[comms] mail from {m.get('from', '?')}: {body}")
            except Exception:
                notices.append(f"[comms] new mail waiting ({os.path.basename(p)})")
    except OSError:
        pass

    # 2. finished verify-queue results for jobs this worktree queued.
    try:
        qdone = os.path.join(home, ".cache", "powos-verify-queue", "done")
        jobs = sorted(glob.glob(os.path.join(qdone, "*.job")), key=os.path.getmtime)[-80:]
        for jp in jobs:
            key = "verify:" + os.path.basename(jp)
            if key in seen:
                continue
            fields = _fields(jp)
            if fields.get("from") != cwd:
                continue
            new_seen.add(key)
            result = _last_line(jp[:-4] + ".log")
            notices.append(f"[verify] {fields.get('task', '?')}: {result}")
    except OSError:
        pass

    # 3. ship results for this worktree's requests.
    try:
        sdone = os.path.join(home, ".cache", "powos-ship-queue", "done")
        reqs = sorted(glob.glob(os.path.join(sdone, "*.req")), key=os.path.getmtime)[-80:]
        for rp in reqs:
            key = "ship:" + os.path.basename(rp)
            if key in seen:
                continue
            fields = _fields(rp)
            if fields.get("who") != basename:
                continue
            new_seen.add(key)
            note = fields.get("note") or "(silent)"
            notices.append(f"[ship] {note}: {fields.get('result', '?')}")
    except OSError:
        pass

    if new_seen != seen:
        try:
            tmp = state_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(sorted(new_seen)[-MAX_SEEN:], f)
            os.replace(tmp, state_path)
        except OSError:
            pass

    if not notices:
        return
    text = "\n".join(notices[:MAX_NOTICES])
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
