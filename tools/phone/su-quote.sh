# shellcheck shell=bash
# tools/phone/su-quote.sh - su_q <cmd>: the `adb shell` argument that runs <cmd> as root, for ANY <cmd>.
#   "$A" shell "$(su_q "$cmd")"     instead of     "$A" shell "su -c '$cmd'"
# WHY: the pasted `su -c '<cmd>'` form ends its quote at the first ' inside <cmd>, so the phone ran a different command
# than the check wrote - two false check FAILs on 11-28 (automations.sh `grep -c '$TAG'`, `date +'%s %S'`).
# A <cmd> without a ' keeps that exact plain form (readable in logs, same bytes on the wire as before). One with a ' goes
# base64-encoded - only [A-Za-z0-9+/=] inside the quotes - and the root shell evals the decoded text: still ONE shell
# level, so remote $vars, globs, pipes, `exit N` and the exit status behave as in the plain form, and stdin is untouched
# (a caller's pipe into adb still reaches <cmd>). Needs `base64` on the phone (toybox has it).
# No side effects on source; bash 3.2 and `set -euo pipefail` safe. Tier-1 test: test/tier1/test-verify-base.sh.
# shq <s>: <s> as ONE single-quoted shell word, any ' in it escaped - for a command nested one level deeper, e.g. the
# Linux user's shell: "$A" shell "$(su_q "sh /data/powos/powos-run.sh $(shq "$cmd")")".
shq() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
su_q() {
  case $1 in
    *\'*) printf "su -c 'eval \"\$(echo %s | base64 -d)\"'" "$(printf '%s' "$1" | base64 | tr -d '\n')" ;;
    *) printf "su -c '%s'" "$1" ;;
  esac
}
