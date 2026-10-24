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

Denies three shapes, for SUBAGENTS only:
  1. A busy spin loop (Bash): `while`/`until` ... `do :;` or `do true;` ... with no `sleep` anywhere in the
     command at all. Always denied (even backgrounded - it just pegs CPU for nothing).
  2. A blocking sleep loop (Bash): `while`/`until` loop whose body sleeps (`do ... sleep N ... done`), when
     the Bash call is NOT run with `run_in_background: true` - i.e. it will block this tool call, possibly past
     the 10-min cap. The same loop with `run_in_background: true` is exactly the recommended pattern, so it's
     allowed.
  3. A file edit (Edit/Write/MultiEdit): `file_path` is inside powos-multiplatform or inside a checkout with
     a .powos-runner-checkout marker in one of its parent dirs.

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
