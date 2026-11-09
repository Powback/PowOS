#!/usr/bin/env bash
# test-manager-optional-context.sh — an optional context step never kills a chat turn under errexit.
#
# 11-09 22:20, OnePlus: the image's lib/ai/manager/manager.sh called `sh "$_MANAGER_DIR/powos-device-context"` but
# that file wasn't in the image; sh exited 127, the `ctx="$(...)"` assignment carried the 127 out, bin/powos runs
# with `set -e`, and the whole turn died before python3 started ("PowAI didn't answer (exit 127)"). Pinned here:
# with powos-device-context missing (and a failing AGENT_CONTEXT_CMD), under `set -e`,
#   _manager_sysprompt   still prints the persona + state
#   _ai_compose_prompt   still builds full_prompt
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# A copy of lib/ai + config/ai, the way an image could hold it: everything but the new helper.
mkdir -p "$WORK/lib" "$WORK/config"
cp -R "$REPO/lib/ai" "$WORK/lib/ai"
[[ -d "$REPO/config/ai" ]] && cp -R "$REPO/config/ai" "$WORK/config/ai"
rm -f "$WORK/lib/ai/manager/powos-device-context"

run() {  # run <bash snippet> -> stdout then "rc=N"
    env -i PATH="/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK" AI_STATE_DIR="$WORK/state" \
        AGENT_SYSTEM_PROMPT="PERSONA" AGENT_CONTEXT_CMD='echo STATE-LINE; false' \
        bash -c 'set -e
                 source "$1/lib/ai/agent.sh" >/dev/null 2>&1 || true
                 source "$1/lib/ai/manager/manager.sh"
                 '"$1"'
                 echo "rc=$?"' _ "$WORK" 2>/dev/null
}

echo "== manager: optional context steps (powos-device-context missing, errexit) =="
OUT=$(run '_manager_sysprompt; echo')
[[ "$OUT" == *PERSONA* && "$OUT" == *STATE-LINE* && "$OUT" == *rc=0 ]] \
  && ok "_manager_sysprompt still produces a prompt" || bad "_manager_sysprompt: got '$OUT'"

OUT=$(run 'agent=manager; prompt=HELLO; comms_enabled() { return 1; }; _ai_compose_prompt; printf "%s\n" "$full_prompt"')
[[ "$OUT" == *"User request: HELLO"* && "$OUT" == *STATE-LINE* && "$OUT" == *rc=0 ]] \
  && ok "_ai_compose_prompt still builds the prompt" || bad "_ai_compose_prompt: got '$OUT'"

# The helper present: its text leads the state (the normal path is unchanged).
printf '#!/bin/sh\necho DEVICE-LINE\n' > "$WORK/lib/ai/manager/powos-device-context"
OUT=$(run '_manager_sysprompt; echo')
[[ "$OUT" == *DEVICE-LINE*STATE-LINE* && "$OUT" == *rc=0 ]] \
  && ok "helper present: device context leads the state" || bad "helper present: got '$OUT'"

# How the file went missing: the rooted deploy installed the manager by a *.py/*.sh glob. It must take every file.
D="$REPO/targets/android/rooted/powos-deploy.sh"
if grep -q 'powos-manager/\*\.py\|powos-manager/\*\.sh' "$D"; then bad "powos-deploy.sh installs the manager by extension glob"
else grep -q 'for f in $T/powos-manager/\*' "$D" && ok "powos-deploy.sh installs every manager file" \
  || bad "powos-deploy.sh: no whole-dir manager install"; fi

echo "== $pass passed, $fail failed =="
(( fail == 0 ))
