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

    # Handle Bash tool: wait loop checks
    if tool_name == "Bash":
        cmd = (inp.get("tool_input") or {}).get("command") or ""
        if not cmd.strip():
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
