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

Also: context budget (docs/AGENT-HANDBOOK.md, Efficiency) - the hand-off numbers (hand back by 120k, never
   resume past 150k) used to be something an agent had to remember and self-police. This makes it
   mechanical: every hook call reads the LATEST assistant message's usage off the TAIL of this call's own
   transcript_path (hook input field; points at the current session's own JSONL - a subagent's hook call
   gets its own file, the coordinator's gets its own, so this fires correctly for both without extra
   plumbing) and, past budget, adds the same reminder every tool call sees. Only the tail is read (a seek
   to the last TAIL_BYTES, never the whole file) so this stays fast on a long session. The usage field
   path (message.usage.{input,cache_read_input,cache_creation_input}_tokens) isn't in Anthropic's public
   hook docs, but it's the same path tools/agents/efficiency.py already parses from the same transcripts -
   matching that, not inventing a second way to read the same file.
"""
import glob
import json
import os
import sys

MAX_NOTICES = 8
MAX_SEEN = 500
TAIL_BYTES = 200_000     # enough to hold the latest assistant message's usage even with a big tool call
HANDBACK_HINT = "done, commits, next steps, Friction & missing info (powos friction add, then list it)"


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


def _latest_usage(transcript_path):
    """The latest assistant message's context tokens (input + cache-read + cache-creation) from only the
    TAIL of transcript_path - never the whole file. None on any error or if no usage is found in the tail."""
    try:
        size = os.path.getsize(transcript_path)
        with open(transcript_path, "rb") as f:
            f.seek(max(0, size - TAIL_BYTES))
            chunk = f.read()
    except OSError:
        return None
    for line in reversed(chunk.split(b"\n")):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("type") != "assistant":
            continue
        u = ((e.get("message") or {}).get("usage")) or {}
        if not u:
            continue
        return (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                + u.get("cache_creation_input_tokens", 0))
    return None


def _ctx_notice(inp, seen, new_seen):
    """Mechanical context-budget reminder (AGENT-HANDBOOK.md, Efficiency: hand back by 120k, never resume
    past 150k). Past 150k: every call. 120k-150k: once per 20k bucket (deduped via the shared seen set,
    keyed by this session so a fresh session starts its own count)."""
    tpath = inp.get("transcript_path")
    if not tpath:
        return None
    ctx = _latest_usage(tpath)
    if ctx is None or ctx < 120_000:
        return None
    k = ctx // 1000
    if ctx >= 150_000:
        return f"[context] {k}k is past the 150k budget: hand back NOW with notes ({HANDBACK_HINT})"
    bucket = (ctx // 20_000) * 20
    sess = inp.get("session_id") or "nosession"
    key = f"ctxbucket:{sess}:{bucket}"
    if key in seen:
        return None
    new_seen.add(key)
    return (f"[context] {k}k: finish the current step, write hand-back notes "
            f"(<=400 words: {HANDBACK_HINT}) and hand back")


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

    # 0. context budget - checked first so it's never crowded out by other notices (MAX_NOTICES below).
    try:
        ctx_notice = _ctx_notice(inp, seen, new_seen)
        if ctx_notice:
            notices.append(ctx_notice)
    except Exception:
        pass

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
