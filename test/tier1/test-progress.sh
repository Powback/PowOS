#!/usr/bin/env bash
# The install progress footer.
#
# Two lines pinned to the bottom via a scroll region (DECSTBM) so the
# installer's own output still scrolls above them — a whiptail gauge would
# clear the screen and hide exactly the output you need when an install fails.
set -uo pipefail
PASS=0; FAIL=0
check() { if ( eval "$2" ) >/dev/null 2>&1; then echo "  ok   - $1"; PASS=$((PASS+1));
          else echo "  FAIL - $1"; FAIL=$((FAIL+1)); fi }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
LIB="$ROOT/lib/progress.sh"; [[ -f "$LIB" ]] || LIB=/usr/lib/powos/progress.sh
PTY="$ROOT/bin/powos-pty-run"; [[ -x "$PTY" ]] || PTY=/usr/bin/powos-pty-run

echo "== install progress footer =="
# shellcheck disable=SC1090
source "$LIB" >/dev/null 2>&1
check "the library loads"          'declare -F pg_begin && declare -F pg_step && declare -F pg_finish'
check "run_step drives it"         'grep -q "pg_have && pg_step" "$ROOT/lib/install-system.sh"'
check "install-system sources it"  'grep -q "progress.sh" "$ROOT/lib/install-system.sh"'
check "it ships in the image"      'grep -q "^COPY lib/" "$ROOT/Containerfile"'
check "pg_* calls are guarded so a missing lib cannot break an install" \
      'grep -q "pg_have()" "$ROOT/lib/install-system.sh"'

# Must be inert without a terminal, or it would spray escapes into the log.
check "no TTY -> completely inert" \
      'PG_TTY=/nonexistent/tty; pg_begin 5; [[ "$PG_ACTIVE" == "0" ]]'
check "POWOS_NO_PROGRESS=1 disables it" \
      'POWOS_NO_PROGRESS=1 PG_TTY=/dev/tty; ! pg_available'

# The bar must never claim more than it has done.
check "the bar clamps and never exceeds the total" \
      '[[ "$(pg__bar 99 5 10)" == "[##########]" ]]'
check "a zero total does not divide by zero"       'pg__bar 0 0 10'

if [[ -x "$PTY" ]]; then
    L=$(mktemp)
    "$PTY" "$L" '
      source '"$LIB"'
      PG_TTY=/dev/tty; pg_begin 4
      for s in one two three; do pg_step "$s"; sleep 1.2; done
      pg_finish' >/dev/null 2>&1
    frames=$(tr -d '\r' < "$L" | grep -oE 'step [0-9]+/' | grep -oE '[0-9]+')

    # The ticker runs in a forked subshell. If it does not read shared state it
    # repaints the values it forked with — the footer flipped back to "step 0"
    # mid-install before this was fixed.
    check "footer frames never regress to an earlier step" \
          'awk "NR>1 && \$1<p {exit 1} {p=\$1}" <<< "$frames"'
    check "the elapsed counter actually ticks (proves it is alive, not hung)" \
          '[[ $(tr -d "\r" < "'"$L"'" | grep -oE "[0-9]+s" | sort -u | wc -l) -ge 2 ]]'
    check "it sets a scroll region"  'grep -q "\[1;[0-9]*r" "'"$L"'"'
    check "and RESETS it on finish"  'grep -q "\[r" "'"$L"'"'
    rm -f "$L"
else
    echo "  skip - pty run (powos-pty-run not found)"
fi

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
