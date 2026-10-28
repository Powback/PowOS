#!/usr/bin/env python3
"""mistake-guard.py: PreToolUse(Bash) hook, SUBAGENTS only (transcript_path contains /subagents/, same
test as wait-guard.py). Denies known Mac/zsh command mistakes with a ONE-LINE corrected command, so the
agent retries once, correctly, instead of burning a call on the error (measured: 13% of Bash calls erred).

Add a rule = add one RULES entry: (name, regex, fix) where fix is a str or fn(match, cmd) -> str.
Only add patterns that are unambiguous; a valid command must never be blocked. Skipped entirely when the
command runs elsewhere (docker/ssh/adb: Linux userland there, GNU flags are right).
Fail-open: any error -> print nothing, exit 0 (= defer).
"""
import json
import re
import sys

CMDPOS = r'(?:^|[;&|(]\s*|\bthen\s+|\bdo\s+)'  # command position


def _timeout(m, cmd):
    return "no `timeout` on macOS - use: perl -e 'alarm %s; exec @ARGV' %s" % (m.group(1), m.group(2).strip()[:120])


def _glob(m, cmd):
    return "zsh expands unquoted globs - quote it: %s='%s'" % (m.group(1), m.group(2))


def _sed(m, cmd):
    return "BSD sed needs an (empty) suffix: use `sed -i '' ...` (or `perl -pi -e`)"


RULES = [
    ("timeout", re.compile(CMDPOS + r'timeout\s+(\d+[smhd]?)\s+(\S[^\n]*)'), _timeout),
    ("glob-arg", re.compile(r'(?:^|\s)(--(?:include|exclude)(?:-dir)?)=([^\s\'"]*[*?\[][^\s\'"]*)'), _glob),
    ("sed-i", re.compile(CMDPOS + r'sed\s+(?:-[a-zA-Z]+\s+)*-i\s+(?![\'"]{2}|\.|-i)\S'), _sed),
    ("source-procsub", re.compile(r'\bsource\s+<\('),
     "`source <(cmd)` fails here - use: eval \"$(cmd)\""),
    ("pull-root-dest", re.compile(r'pull-root\.sh\s+\S+\s+(?!\S*/(?:\s|$))\S+\.(?:jpe?g|png|webp|txt|log|xml|json|mp4)\s*(?:$|[;&|])'),
     "pull-root.sh dest is a DIRECTORY: `pull-root.sh <src> <dir>/` (file lands as <dir>/<basename>)"),
]
SKIP_RE = re.compile(r'\b(?:docker|podman|ssh|adb(?:\.sh)?|user\.sh)\b')


def check(cmd):
    if SKIP_RE.search(cmd):
        return None
    for _name, rx, fix in RULES:
        m = rx.search(cmd)
        if m:
            return fix(m, cmd) if callable(fix) else fix
    return None


def main():
    inp = json.load(sys.stdin)
    if "/subagents/" not in (inp.get("transcript_path") or "") or inp.get("tool_name") != "Bash":
        return
    why = check((inp.get("tool_input") or {}).get("command") or "")
    if why:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": why}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
