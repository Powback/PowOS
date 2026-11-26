#!/bin/bash
# tools/lint/changed-lints.sh: the lints the pre-push hook refuses a push on, over a list of changed files - one
# script for both places that run them:
#   - tools/git-hooks/pre-push (the files of the pushed range);
#   - the agent's scoped gate (shell/dev/gate.sh: the branch's changes since the merge base, committed + uncommitted),
#     so a complexity / shellcheck / hack-registry failure shows in the FIRST gate run, not at push - 11-25 agents
#     went gate pass -> push refused -> refactor commit -> gate again (whole extra rounds).
#
#   tools/lint/changed-lints.sh [--no-shell] FILE...   repo-relative paths (missing/deleted files are skipped)
#     shell/*.ts|tsx|mjs|js  shell/dev/lint-complexity.sh on them, then tsc --noEmit over shell/   (--no-shell: neither;
#                            the gate runs both over its composed tree already)
#     apps/*/ui/*            shell/dev/lint-complexity.sh --apps
#     targets/android/app/**/*.kt (not tests)   targets/android/lint-complexity.sh --only (detekt, ~4 s)
#     every file             tools/lint/shellcheck-ratchet.py --check (keeps the shell scripts among them)
#     always                 test/tier1/test-hack-registry.sh (~1 s: each hack marker needs its REMOTE-POWOS.md row)
# GATE_LINT=0 skips tsc and the shellcheck ratchet (as the hook always did). Exit 0 clean, 1 a lint failed (above).
set -uo pipefail
root=$(git rev-parse --show-toplevel)
noshell=""; [ "${1:-}" = --no-shell ] && { noshell=1; shift; }
files=() apps="" kt="" sh=()
for f in "$@"; do
  [ -e "$root/$f" ] || continue
  sh+=("$f")
  case "$f" in
    shell/*.ts|shell/*.tsx|shell/*.mjs|shell/*.js) [ -n "$noshell" ] || files+=("${f#shell/}") ;;
    apps/*/ui/*) apps=--apps ;;
    targets/android/app/*/test/*) ;;
    targets/android/app/*.kt) kt+="${kt:+,}${f#targets/android/app/}" ;;
  esac
done
s=0
if [ ${#files[@]} -gt 0 ] || [ -n "$apps" ]; then
  "$root/shell/dev/lint-complexity.sh" $apps ${files[@]+"${files[@]}"} || s=$?
  [ $s = 2 ] && s=0   # skipped on purpose (GATE_LINT=0)
fi
if [ ${#files[@]} -gt 0 ] && [ "${GATE_LINT:-1}" != 0 ]; then
  tsc=$root/shell/node_modules/.bin/tsc
  if [ ! -x "$tsc" ]; then echo "lints: tsc skipped (no shell/node_modules)" >&2
  elif ! out=$(cd "$root/shell" && "$tsc" --noEmit -p . 2>&1); then echo "$out" | grep -v '^ ' | head -30 | sed 's/^/FAIL tsc: /'; s=1
  fi
fi
if [ -n "$kt" ]; then
  # need_docker (f35: brew upgrade unlinks docker) fixes PATH for this shell, which lint-complexity.sh inherits.
  . "$root/tools/lib/need-docker.sh"
  need_docker
  k=0; "$root/targets/android/lint-complexity.sh" --only "$kt" || k=$?
  [ $k = 1 ] && s=1
fi
# The shellcheck ratchet (tools/lint/shellcheck-ratchet.py; CI runs it over every script): no new finding, no file worse
# than tools/lint/shellcheck-baseline.txt, no stale or raised entry. Pinned shellcheck 0.9.0 (on the Mac through docker).
if [ ${#sh[@]} -gt 0 ] && [ "${GATE_LINT:-1}" != 0 ]; then
  . "$root/tools/lib/need-docker.sh"; need_docker 2>/dev/null || true   # a native shellcheck 0.9.0 needs no docker
  c=0; out=$(cd "$root" && python3 tools/lint/shellcheck-ratchet.py --check "${sh[@]}" 2>&1) || c=$?
  [ $c = 0 ] || { echo "$out" | grep -v '^ok '; s=1; }
fi
# 11-09: five ships in one night failed only on test-hack-registry (a new hack marker with no row in
# REMOTE-POWOS.md §4) - a ~1 s file scan.
if ! out=$(bash "$root/test/tier1/test-hack-registry.sh" 2>&1); then
  echo "$out" | grep -E "FAIL" | sed 's/^ */FAIL hack registry: /'; s=1
fi
[ $s = 0 ] && echo "ok   changed-file lints (complexity, shellcheck ratchet, hack registry)"
exit $s
