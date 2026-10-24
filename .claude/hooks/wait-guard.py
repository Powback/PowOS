#!/usr/bin/env python3
"""wait-guard.py: denies hand-rolled blocking-wait loops in Bash calls, for SUBAGENTS only (same
`_is_subagent` test as .claude/hooks/agent-notices.py - the transcript_path contains /subagents/).
A PreToolUse hook (.claude/settings.json, matcher "Bash", project-level: every worktree's agents get it).

Why: 374 agent transcripts measured hundreds of `until ...; do sleep N; done` / `while pgrep ...; do :;
done` loops (181 of them a busy spin with `do :;`, no sleep at all) - many of them ran long enough to hit
the Bash tool's 10-min cap while the agent just sat there waiting on a background job. docs/AGENT-HANDBOOK.md
(Efficiency) already says never to hand-roll a wait loop: put the long-running thing in the background with
`run_in_background` and let the PostToolUse hook (agent-notices.py) deliver the result - comms mail, a
finished verify-queue job, or a ship result - on the NEXT tool call instead of blocking this one. This hook
makes that mechanical instead of something an agent has to remember.

Denies two shapes, Bash tool calls only:
  1. A busy spin loop: `while`/`until` ... `do :;` or `do true;` ... with no `sleep` anywhere in the
     command at all. Always denied (even backgrounded - it just pegs CPU for nothing).
  2. A `while`/`until` loop whose body sleeps (`do ... sleep N ... done`), when the Bash call is NOT run
     with `run_in_background: true` - i.e. it will block this tool call, possibly past the 10-min cap.
     The same loop with `run_in_background: true` is exactly the recommended pattern, so it's allowed.

Anything else (not a subagent, not Bash, no loop, or a backgrounded sleep loop): prints nothing and exits
0, which is "defer" - the normal permission flow decides. This hook only ever adds a deny; it never forces
an allow (that could bypass an unrelated permission prompt for a dangerous command).

Fail-silent like agent-notices.py: any error -> print nothing, exit 0. A hook bug must never block a
legitimate tool call (and must never crash to block one by accident either).

See the Claude Code hooks docs for the PreToolUse deny format: hookSpecificOutput.permissionDecision
"deny" + permissionDecisionReason (shown to the model). No output at all = defer.
"""
import json
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


def main():
    try:
        inp = json.load(sys.stdin)
    except Exception:
        return
    if inp.get("tool_name") != "Bash":
        return
    if not _is_subagent(inp):
        return

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


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
