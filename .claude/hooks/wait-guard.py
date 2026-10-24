#!/usr/bin/env python3
"""wait-guard.py: denies hand-rolled blocking-wait loops in Bash calls, for SUBAGENTS only (same
`_is_subagent` test as .claude/hooks/agent-notices.py - the transcript_path contains /subagents/).
Also denies edits to the SHARED checkout (powos-multiplatform) or runner checkouts (marked by
.powos-runner-checkout), for SUBAGENTS only.
A PreToolUse hook (.claude/settings.json, matchers "Bash", "Edit", "Write", "MultiEdit", project-level: every
worktree's agents get it).

Why: 374 agent transcripts measured hundreds of `until ...; do sleep N; done` / `while pgrep ...; do :;
done` loops (181 of them a busy spin with `do :;`, no sleep at all) - many of them ran long enough to hit
the Bash tool's 10-min cap while the agent just sat there waiting on a background job. docs/AGENT-HANDBOOK.md
(Efficiency) already says never to hand-roll a wait loop: put the long-running thing in the background with
`run_in_background` and let the PostToolUse hook (agent-notices.py) deliver the result - comms mail, a
finished verify-queue job, or a ship result - on the NEXT tool call instead of blocking this one. This hook
makes that mechanical instead of something an agent has to remember.

For files: agents edit files in the SHARED checkout (powos-multiplatform) or runner checkouts (verify-runner,
emu-runner, ship-runner, ship-runner-apk; marked by .powos-runner-checkout), and only find out when land.sh
refuses to land. This hook prevents that early, requiring agents to make their own worktree instead.

Also (context hygiene, docs/agent-tool-waste-2026-10-24.md): repeated status polls, whole-file Reads of
files > 400 lines / 40 KB, `cat` of > 400-line files, uncapped `grep -r`, `sed -n` ranges > 200 lines.

Denies four shapes, for SUBAGENTS only:
  1. A busy spin loop (Bash): `while`/`until` ... `do :;` or `do true;` ... with no `sleep` anywhere in the
     command at all. Always denied (even backgrounded - it just pegs CPU for nothing).
  2. A blocking sleep loop (Bash): `while`/`until` loop whose body sleeps (`do ... sleep N ... done`), when
     the Bash call is NOT run with `run_in_background: true` - i.e. it will block this tool call, possibly past
     the 10-min cap. The same loop with `run_in_background: true` is exactly the recommended pattern, so it's
     allowed.
  3. A file edit (Edit/Write/MultiEdit): `file_path` is inside powos-multiplatform or inside a checkout with
     a .powos-runner-checkout marker in one of its parent dirs.
  4. A direct phone input (Bash): adb.sh/user.sh running `input tap`/`input swipe`/`input keyevent` straight
     at the device, outside the verify queue (f24: a desktop agent's direct input during a live E2E round
     invalidated that round's page-swipe step - nothing stopped it from racing a check mid-run in a locked
     window). `LOCK_HELD=<nonzero>` anywhere in the command is the documented escape hatch - the same text
     convention tools/phone/verify/*.sh scripts and .claude/skills/powos-phone/SKILL.md already use for "I
     hold the lock (or don't need it, e.g. the emulator) - run anyway"; trusted here at the same level.

Anything else (not a subagent, not Bash/Edit/Write/MultiEdit, no loop, or a backgrounded sleep loop, or a
non-shared file path): prints nothing and exits 0, which is "defer" - the normal permission flow decides. This
hook only ever adds a deny; it never forces an allow (that could bypass an unrelated permission prompt for a
dangerous command).

Fail-silent like agent-notices.py: any error -> print nothing, exit 0. A hook bug must never block a
legitimate tool call (and must never crash to block one by accident either).

See the Claude Code hooks docs for the PreToolUse deny format: hookSpecificOutput.permissionDecision
"deny" + permissionDecisionReason (shown to the model). No output at all = defer.
"""
import json
import os
import re
import sys

REFUSAL_TAIL = ("run it with run_in_background and keep working; the PostToolUse hook delivers "
                 "queue/ship/mail results; or hand back with the job id.")

# while/until ... do :; / do true; ... - a no-op busy spin, never useful even backgrounded.
SPIN_RE = re.compile(r'\b(?:while|until)\b[\s\S]{0,300}?\bdo\b\s*(?::|true)\s*(?:;|\n)')
SLEEP_WORD_RE = re.compile(r'\bsleep\b')

# while/until ... do ... sleep N ... done - fine backgrounded, blocks the call otherwise.
SLEEP_LOOP_RE = re.compile(r'\b(?:while|until)\b[\s\S]{0,400}?\bdo\b[\s\S]{0,400}?\bsleep\s+\d')

# adb.sh/user.sh driving the phone's touchscreen/keys directly (f24) - the thing the verify queue
# exists to serialize. Bounded lookahead so a long unrelated command can't make this pathological.
PHONE_INPUT_RE = re.compile(r'\b(?:adb|user)\.sh\b[\s\S]{0,200}?\binput\s+(?:tap|swipe|keyevent)\b')
# The documented bypass: LOCK_HELD=1 (or any non-"0" value) anywhere in the command.
LOCK_HELD_SET_RE = re.compile(r'\bLOCK_HELD=(?!0\b)\S')

# git commit/push/rebase/merge commands - check if running in powos-multiplatform checkout
# Allows for git -C <path> flags
GIT_CMD_RE = re.compile(r'\bgit\s+(?:-C\s+\S+\s+)?(?:commit|push|rebase|merge)\b')


# --- context hygiene (docs/agent-tool-waste-2026-10-24.md fixes 1, 3, 5) ----------------------------
POLL_WINDOW = 8          # the same status poll again within this many guarded calls is denied
READ_MAX_LINES = 400     # whole-file Read denied above this ...
READ_MAX_BYTES = 40_000  # ... or this
CAT_MAX_LINES = 400
SED_MAX_RANGE = 200
NO_LIMIT_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".pdf", ".ipynb", ".svg")

WAIT_HINT = ("block ONCE instead of polling: `tools/phone/verify/queue.sh wait <job-id> [max_s]` (prints "
             "PASS/FAIL lines only), `tools/phone/idle.sh --wait`, or a background `until ...` loop run with "
             "run_in_background (the harness notifies you; the PostToolUse hook also delivers queue/ship "
             "results on your next call). Or hand back with the job id.")
POLL_RES = [re.compile(p) for p in (
    r'\bqueue\.sh\s+(?:status|list)\b', r'\bship\.sh\s+status\b',
    r'\bls\b[^|;&]*powos-(?:verify|ship)-queue', r'\b(?:tail|cat|head)\b[^|;&]*runner\.log',
    r'\bget-state\b', r'\btasks/[^\s]*\.output\b')]
GREP_REC_RE = re.compile(r'(?<!git )\bgrep\s+(?:[^|;&\n]*?\s)?(?:-[A-Za-z]*[rR][A-Za-z]*|--recursive)(?=\s)')
GREP_OK_FLAG_RE = re.compile(r'(?:^|\s)(?:-[A-Za-z]*[lLcq][A-Za-z]*|-m\s*\d*|--max-count\S*|--files-with\S*|--count)(?=\s|$)')
HEADLIKE_RE = re.compile(r'\|\s*(?:head|tail|wc|sed\s+-n|awk|cut\b[^|]*\|\s*head)\b')
SED_RANGE_RE = re.compile(r"\bsed\s+(?:-[A-Za-z]*n[A-Za-z]*\s+)['\"]?(\d+),(\d+)p")
CAT_RE = re.compile(r'^\s*cat\s+((?:-\S+\s+)*)([^|;&<>\n]+?)\s*(?:2>&1\s*)?$')


def _state_file(inp):
    d = os.path.join(os.path.expanduser("~"), ".cache", "powos-agent-notices")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, "poll-" + re.sub(r'[^A-Za-z0-9_.-]', '_', inp.get("session_id") or "nosession") + ".json")


def _poll_repeat(inp, cmd):
    """Count every guarded call; True when this is a status poll identical to one made < POLL_WINDOW calls ago."""
    path = _state_file(inp)
    try:
        with open(path) as f:
            st = json.load(f)
    except Exception:
        st = {"n": 0, "polls": {}}
    st["n"] += 1
    key = re.sub(r'\s+', ' ', cmd.strip())
    is_poll = any(r.search(cmd) for r in POLL_RES)
    repeat = is_poll and key in st["polls"] and st["n"] - st["polls"][key] < POLL_WINDOW
    if is_poll and not repeat:
        st["polls"][key] = st["n"]
    st["polls"] = {k: v for k, v in st["polls"].items() if st["n"] - v < 50}
    try:
        with open(path, "w") as f:
            json.dump(st, f)
    except OSError:
        pass
    return repeat


def _count_lines(path, cap=3_000_000):
    """(lines, bytes) of a file, reading at most cap bytes; None if unreadable."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            return f.read(cap).count(b"\n"), size
    except OSError:
        return None


def _resolve(inp, path):
    path = os.path.expanduser(path.strip("'\""))
    return path if os.path.isabs(path) else os.path.join(inp.get("cwd") or os.getcwd(), path)


def _check_read(inp):
    ti = inp.get("tool_input") or {}
    path = ti.get("file_path") or ""
    if not path or ti.get("offset") or ti.get("limit") or ti.get("pages") or path.lower().endswith(NO_LIMIT_EXT):
        return None
    c = _count_lines(path)
    if c and (c[0] > READ_MAX_LINES or c[1] > READ_MAX_BYTES):
        return (f"this file has {c[0]} lines ({c[1] // 1000} KB) - `grep -n '<what you need>' {path} | head -20` first, "
                f"then Read with offset/limit around the hit (or `grep -n '^## ' <file>` for a doc's outline).")
    return None


def _check_bash_output(inp, cmd):
    """Fix 5: deny the output shapes that dump thousands of tokens into the context."""
    body = re.sub(r'^\s*cd\s+\S+\s*&&\s*', '', cmd)
    m = CAT_RE.match(body)
    if m and "<<" not in body:
        for a in m.group(2).split():
            c = _count_lines(_resolve(inp, a))
            if c and c[0] > CAT_MAX_LINES:
                return (f"`cat` of a {c[0]}-line file ({a}) denied - `grep -n '<what you need>' {a} | head -20`, then "
                        f"`sed -n 'A,Bp' {a}` (<= {SED_MAX_RANGE} lines) or Read with offset/limit.")
    if GREP_REC_RE.search(cmd) and not HEADLIKE_RE.search(cmd) and not GREP_OK_FLAG_RE.search(cmd):
        return ("recursive grep with no cap denied - add `| head -20`, or `-m 5`, `-l` (file names only) or `-c` "
                "(counts) so a broad pattern can't dump the tree into your context; narrow the path/--include too.")
    for a, b in SED_RANGE_RE.findall(cmd):
        if int(b) - int(a) > SED_MAX_RANGE:
            return (f"sed -n '{a},{b}p' is {int(b) - int(a)} lines (cap {SED_MAX_RANGE}) - `grep -n '<what you need>' <file> | head -20` "
                    f"first, then print a narrower range around the hit.")
    return None


def _is_subagent(inp):
    """Same rule as agent-notices.py: budgets/guards are for subagents only - the user's own sessions
    and the manager are long-lived by design and drive their own waits deliberately."""
    return "/subagents/" in (inp.get("transcript_path") or "")


def _deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def _is_in_powos_multiplatform(file_path):
    """Check if file_path is inside a directory named powos-multiplatform."""
    if not file_path:
        return False
    # Normalize the path and check for powos-multiplatform in the components
    parts = os.path.normpath(file_path).split(os.sep)
    return "powos-multiplatform" in parts


def _is_in_runner_checkout(file_path):
    """Check if file_path is inside a checkout with .powos-runner-checkout marker in a parent dir."""
    if not file_path:
        return False
    # Walk up from the file's directory to find a .powos-runner-checkout marker
    current = os.path.dirname(os.path.abspath(file_path))
    # Limit to 20 levels deep to avoid infinite loops
    for _ in range(20):
        marker_file = os.path.join(current, ".powos-runner-checkout")
        if os.path.exists(marker_file):
            return True
        parent = os.path.dirname(current)
        if parent == current:  # reached root
            break
        current = parent
    return False


def _extract_git_cwd(cmd):
    """Extract the working directory for a git command.

    Handles:
      - cd X && git ...
      - git -C X ...
      - implicit cwd

    Returns the cwd as a string, or None if not extractable.
    """
    # Check for 'cd X &&' pattern
    cd_match = re.search(r'\bcd\s+(\S+)\s*&&', cmd)
    if cd_match:
        path = cd_match.group(1)
        # Strip quotes if present
        if path.startswith(("'", '"')) and path.endswith(path[0]):
            path = path[1:-1]
        return path

    # Check for 'git -C X' pattern
    git_c_match = re.search(r'\bgit\s+-C\s+(\S+)', cmd)
    if git_c_match:
        path = git_c_match.group(1)
        # Strip quotes if present
        if path.startswith(("'", '"')) and path.endswith(path[0]):
            path = path[1:-1]
        return path

    # No explicit cwd in the command
    return None


def _is_dangerous_git_in_powos_multiplatform(cmd):
    """Check if command runs git commit/push/rebase/merge in a powos-multiplatform checkout.

    Returns True (deny) if:
      - Contains 'git commit', 'git push', 'git rebase', or 'git merge'
      - AND (explicit cwd is in powos-multiplatform OR implicit cwd via .git detection)
    """
    if not GIT_CMD_RE.search(cmd):
        return False

    # Extract explicit cwd if present
    explicit_cwd = _extract_git_cwd(cmd)
    if explicit_cwd:
        return _is_in_powos_multiplatform(explicit_cwd) or _is_in_runner_checkout(explicit_cwd)

    # No explicit cwd; check if the command itself indicates a cwd
    # In most cases, implicit commands run in the current shell cwd which we can't know.
    # However, if there's no explicit cwd, we have to be conservative and not deny
    # (the agent might be running from a safe worktree).
    # But if the command starts with 'cd powos-multiplatform && git' we catch it above.
    # For now, be safe and don't deny commands without explicit cwd markers.
    return False


def main():
    try:
        inp = json.load(sys.stdin)
    except Exception:
        return

    if not _is_subagent(inp):
        return

    tool_name = inp.get("tool_name")

    if tool_name == "Read":
        why = _check_read(inp)
        if why:
            _deny(why)
        return

    # Handle Bash tool: wait loop checks
    if tool_name == "Bash":
        cmd = (inp.get("tool_input") or {}).get("command") or ""
        if not cmd.strip():
            return

        if not (inp.get("tool_input") or {}).get("run_in_background") and _poll_repeat(inp, cmd):
            _deny("Repeated status poll denied (same command again within %d calls) - " % POLL_WINDOW + WAIT_HINT)
            return
        why = _check_bash_output(inp, cmd)
        if why:
            _deny(why)
            return

        if SPIN_RE.search(cmd) and not SLEEP_WORD_RE.search(cmd):
            _deny("Busy spin loop (do :; / do true;, no sleep) denied - it just burns CPU and the Bash "
                  "call's time budget for no signal. " + REFUSAL_TAIL)
            return

        backgrounded = bool((inp.get("tool_input") or {}).get("run_in_background"))
        if SLEEP_LOOP_RE.search(cmd) and not backgrounded:
            _deny("Blocking wait loop (while/until ... sleep ... done) denied - not run with "
                  "run_in_background, so it blocks this call until the loop exits (and can hit the 10-min "
                  "cap while waiting on a background job). " + REFUSAL_TAIL)
            return

        if PHONE_INPUT_RE.search(cmd) and not LOCK_HELD_SET_RE.search(cmd):
            _deny("Direct phone input (adb.sh/user.sh input tap/swipe/keyevent) denied outside the verify "
                  "queue - it can race a check running in a locked window (f24). Queue it instead: "
                  "tools/phone/verify/queue.sh add <task> <check>; or, only once you've checked the lock "
                  "yourself (or you're on the emulator), prefix the command with LOCK_HELD=1.")
            return

        # Check for dangerous git commands in powos-multiplatform checkouts
        if _is_dangerous_git_in_powos_multiplatform(cmd):
            _deny("make your own worktree: tools/agents/worktree.sh new <name>")
            return

    # Handle Edit/Write/MultiEdit tools: shared checkout checks
    elif tool_name in ("Edit", "Write", "MultiEdit"):
        # For MultiEdit, check all file_paths in the edits array
        if tool_name == "MultiEdit":
            edits = (inp.get("tool_input") or {}).get("edits") or []
            for edit in edits:
                file_path = edit.get("file_path") if isinstance(edit, dict) else None
                if file_path and (_is_in_powos_multiplatform(file_path) or _is_in_runner_checkout(file_path)):
                    _deny(f"make your own worktree: tools/agents/worktree.sh new <name> (lands in ~/pw), then edit there")
                    return
        else:
            # For Edit and Write, check the single file_path
            file_path = (inp.get("tool_input") or {}).get("file_path")
            if file_path and (_is_in_powos_multiplatform(file_path) or _is_in_runner_checkout(file_path)):
                _deny(f"make your own worktree: tools/agents/worktree.sh new <name> (lands in ~/pw), then edit there")
                return


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
