#!/bin/bash
# test-verify-base.sh - tools/phone/verify/base.sh, the shared base of the phone checks, against a fake adb, cdp.sh and
# shot.sh (no phone): sh_ is the pasted root-shell form but quote-safe (' " $ ` \ and newlines reach a fake phone's
# root shell intact, tools/phone/su-quote.sh), its SH_T / step caps hold, tap/swipe/drag validate their
# integers and a drag is ONE on-device shell, hcall retries a transport miss, cdp_val unquotes, the verdict lines and
# exit codes are the queue's, `within` kills an over-time command, and a check's own helpers are never replaced.
# Then the lint: no verify script pastes a copy of base.sh's sh_ or hcall forms again (source base.sh instead).
# No pipefail here on purpose (see run-all.sh): assertions use `grep -c` on captured output.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BASE="$ROOT/tools/phone/verify/base.sh"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; FAIL=$((FAIL+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want: $3
got:  $2"; }
W=$(mktemp -d "${TMPDIR:-/tmp}/vbase.XXXXXX"); trap 'rm -rf "$W"' EXIT
LOG=$W/adb.log
# The fake adb: each call appends "CALL <args>" (and for `sh -s` its stdin, "IN <line>") to $LOG; prints $W/adb.out with \r line
# ends and "noise" on stderr; sleeps $W/adb.sleep seconds first when that file exists.
cat > "$W/adb.sh" <<'EOF'
#!/bin/bash
d=$(dirname "$0"); echo "CALL $*" >> "$d/adb.log"
case "$*" in *"sh -s"*) while IFS= read -r l; do echo "IN $l" >> "$d/adb.log"; done ;; esac
[ -f "$d/adb.sleep" ] && sleep "$(cat "$d/adb.sleep")"
[ -f "$d/adb.out" ] && sed 's/$/\r/' "$d/adb.out"
echo noise >&2
EOF
# The fake cdp.sh: "eval <page> <js>" -> logs it, prints the next line of $W/cdp.answers (consumed), else "ok".
cat > "$W/cdp.sh" <<'EOF'
#!/bin/bash
d=$(dirname "$0"); echo "CDP $2 $3" >> "$d/cdp.log"
if [ -s "$d/cdp.answers" ]; then head -1 "$d/cdp.answers"; sed -i.bak 1d "$d/cdp.answers"; else echo '"ok"'; fi
EOF
printf '#!/bin/bash\necho "saving $1"; echo "saved $1 (inner)"\n' > "$W/shot.sh"
chmod +x "$W/adb.sh" "$W/cdp.sh" "$W/shot.sh"
reset() { rm -f "$LOG" "$W/adb.out" "$W/adb.sleep" "$W/cdp.log" "$W/cdp.answers"; }
# run <bash snippet>: a fresh bash that sourced base.sh with T=$W, A=$W/adb.sh; stdout+stderr, then "rc=N".
run() { reset; ( cd "$W" && T=$W A=$W/adb.sh here=$W bash -c ". '$BASE'; $1" 2>&1; echo "rc=$?" ); }
calls() { grep -c '^CALL' "$LOG" 2>/dev/null || echo 0; }

echo "== sh_: the pasted form (root shell, \\r stripped, stderr dropped) =="
out=$( reset; printf 'a\nb\n' > "$W/adb.out"; cd "$W" && T=$W A=$W/adb.sh bash -c ". '$BASE'; sh_ \"ls /data\" | od -c | grep -c '\\\\r'" )
is "no \\r in its output" "$out" 0
run 'sh_ "dumpsys power" >/dev/null' >/dev/null
is "one adb call: shell su -c '<cmd>'" "$(cat "$LOG")" "CALL shell su -c 'dumpsys power'"
out=$(run 'sh_ "x"'); is "stderr dropped" "$(printf '%s\n' "$out" | grep -c noise)" 0

echo "== sh_: any command - ' \" \$ \` \\ and newlines reach the root shell intact (tools/phone/su-quote.sh) =="
# A fake phone: adb.sh runs `shell <arg>` in sh (the phone's shell), `su -c <s>` runs <s> in sh (the root shell).
P=$W/phone; mkdir -p "$P/bin" "$P/g"; touch "$P/g/g1" "$P/g/g2"
printf '#!/bin/sh\n[ "$1" = shell ] || exit 64\nshift\nPATH="%s/bin:$PATH" exec sh -c "$*"\n' "$P" > "$P/adb.sh"
printf '#!/bin/sh\n[ "$1" = -c ] || exit 64\nexec sh -c "$2"\n' > "$P/bin/su"
chmod +x "$P/adb.sh" "$P/bin/su"
# prun <cmd>: sh_ <cmd> on the fake phone, then rc (pipefail, so adb's rc is sh_'s).
prun() { ( cd "$W" && G=$P/g A=$P/adb.sh T=$W here=$W bash -c 'set -o pipefail; . "$1"; sh_ "$2"; echo "rc=$?"' _ "$BASE" "$1" 2>&1 ); }
# want: the same command straight in sh (what the check author meant), rc appended.
want() { ( G=$P/g sh -c "$1" 2>/dev/null; echo "rc=$?" ); }
nl='
'
i=0
for c in "grep -c 'x y' /dev/null; true" "date -r 0 +'%s %S'" "echo 'it'\"'\"'s' \"dq \\\"in\\\"\"" \
  'echo $((1+2)) "$G" `echo bt` $(echo cs)' 'printf "%s|" a\\b "c\\\\d"; echo' "echo one${nl}echo 'two'${nl}echo \"three\"" \
  "ls \$G/g* | wc -l | tr -d ' '" "echo 'out'; echo 'err' >&2; exit 7" "x='\$HOME'; echo \"\$x\"" "printf '%s\\n' '\`not run\`' '\\'"; do
  i=$((i + 1)); is "quote-safe $i: $(printf '%s' "$c" | tr '\n' '~' | cut -c1-48)" "$(prun "$c")" "$(want "$c")"
done
is "plain form kept when there is no ' (same bytes as before)" "$(. "$ROOT/tools/phone/su-quote.sh"; su_q 'ls "$G" $X')" "su -c 'ls \"\$G\" \$X'"
case $(. "$ROOT/tools/phone/su-quote.sh"; su_q "echo 'a'") in "su -c 'eval \"\$(echo "*" | base64 -d)\"'") ok "a ' goes base64 (only [A-Za-z0-9+/=] in the quotes)" ;; *) bad "su_q's ' form" ;; esac
is "a big command (8 KiB, quotes in it)" "$(prun "$(printf "echo '%s' >/dev/null; " $(seq 1 600)) echo done")" "done${nl}rc=0"
# shq: one more shell level (the Linux user's powos-run.sh "<cmd>"): fake powos-run.sh = sh -c "$1".
printf '#!/bin/sh\nexec sh -c "$1"\n' > "$P/bin/powos-run.sh"; chmod +x "$P/bin/powos-run.sh"
c="echo 'it'\''s' \"dq\" \$((2*3)) \`echo bt\` 'a\\b'${nl}printf '%s\\n' 'two'"
got=$( cd "$W" && A=$P/adb.sh bash -c '. "$1"; "$A" shell "$(su_q "powos-run.sh $(shq "$2")")"; echo "rc=$?"' _ "$ROOT/tools/phone/su-quote.sh" "$c" 2>&1 )
is "shq + su_q: a command two shells deep arrives intact" "$got" "$(want "$c")"
out=$(cd "$W" && printf 'piped in\n' | A=$P/adb.sh T=$W here=$W bash -c '. "$1"; sh_ "cat; echo '"'"'q'"'"'"' _ "$BASE")
is "stdin still reaches the command (uncapped sh_)" "$out" "piped in${nl}q"
# The local sh_/su_ forks (not sourcing base.sh) use su_q too: no `su -c '$*'` / `'$1'` left in tools/phone.
raw=$(cd "$ROOT/tools/phone" && grep -nE "su -c '\\\$(\*|1|@|\{1\})'" ./*.sh verify/*.sh 2>/dev/null)
[ -z "$raw" ] && ok "no raw su -c '\$*' helper left in tools/phone (use su_q)" || bad "raw su -c '\$*' helpers (use \"\$(su_q \"\$*\")\")" "$raw"

if command -v perl >/dev/null; then
  echo "== caps: SH_T and a step's cap =="
  out=$(reset; echo 5 > "$W/adb.sleep"; cd "$W" || exit; t0=$(date +%s); T=$W A=$W/adb.sh SH_T=1 bash -c ". '$BASE'; sh_ x" >/dev/null 2>&1; echo $(( $(date +%s) - t0 )))
  [ "$out" -le 3 ] && ok "SH_T=1 caps a hung adb (${out}s)" || bad "SH_T=1 didn't cap a 5 s adb (${out}s)"
  out=$(run 'step slow 1 >/dev/null; sleep 2; sh_ "input tap 1 2"')
  is "past the step cap: a FAIL line" "$(printf '%s\n' "$out" | grep -c '^FAIL: step slow: past its 1 s cap')" 1
  is "past the step cap: nothing sent" "$(calls)" 0
  out=$(run 'step fast 30 >/dev/null; sh_ "input tap 1 2"; step free >/dev/null; sh_ y')
  is "inside the cap / after an uncapped step: sent" "$(calls)" 2
  out=$(run 'within 1 hang sleep 5'); is "within: over its cap" "$(printf '%s\n' "$out" | tr '\n' ' ')" "FAIL: hang: over its 1 s cap rc=124 "
  out=$(run 'within 5 quick true'); is "within: in time" "$out" "rc=0"
  out=$(run 'within 5 own false'); is "within: the command's own rc" "$out" "rc=1"
else
  echo "  skip - no perl here (the Mac and .58 have it): caps not tested"
fi

echo "== tap / swipe / drag =="
run 'tap 10 20' >/dev/null; is "tap x y" "$(cat "$LOG")" "CALL shell su -c 'input tap 10 20'"
run 'p="30 40"; tap "$p"' >/dev/null; is "tap \"x y\" (one quoted arg)" "$(cat "$LOG")" "CALL shell su -c 'input tap 30 40'"
for b in '1.5 2' "\"'10'\" 2" '10' '1 2 3' 'x 2' '- 2' '1- 2'; do
  out=$(run "tap $b"); n=$(printf '%s\n' "$out" | grep -cE '^(FAIL: tap: bad coordinates|rc=2$)')
  [ "$(calls)" = 0 ] && [ "$n" = 2 ] && ok "tap $b: refused, nothing sent" || bad "tap $b" "$out"
done
run 'tap -5 20' >/dev/null; is "tap: negative ints pass" "$(cat "$LOG")" "CALL shell su -c 'input tap -5 20'"
run 'swipe 1 2 3 4' >/dev/null; is "swipe default 300 ms" "$(cat "$LOG")" "CALL shell su -c 'input swipe 1 2 3 4 300'"
run 'swipe 1 2 3 4 900' >/dev/null; is "swipe ms" "$(cat "$LOG")" "CALL shell su -c 'input swipe 1 2 3 4 900'"
out=$(run 'swipe 1 2 3 y'); is "swipe: bad int refused" "$(calls)" 0
run 'drag 0 0 120 240 1000 400 4' >/dev/null
is "drag: ONE adb call" "$(calls)" 1
is "drag: root sh on stdin" "$(grep '^CALL' "$LOG")" "CALL shell su -c 'sh -s'"
want="IN input motionevent DOWN 0 0
IN sleep 1.000
IN input motionevent MOVE 30 60
IN sleep 0.100
IN input motionevent MOVE 60 120
IN sleep 0.100
IN input motionevent MOVE 90 180
IN sleep 0.100
IN input motionevent MOVE 120 240
IN sleep 0.100
IN input motionevent UP 120 240"
is "drag: DOWN, hold, 4 MOVEs over 400 ms, UP" "$(grep '^IN' "$LOG")" "$want"
run 'drag 0 0 10 10' >/dev/null
is "drag defaults: no hold, 12 MOVEs" "$(grep -c 'MOVE' "$LOG") $(grep -c 'sleep 0.033' "$LOG") $(grep -c 'sleep 0.000' "$LOG")" "12 12 0"
out=$(run 'drag 0 0 10 1.5'); is "drag: bad args refused" "$(calls)" 0
run 'drag 0 0 0 20 0 200 2 1500' >/dev/null
want="IN input motionevent DOWN 0 0
IN input motionevent MOVE 0 10
IN sleep 0.100
IN input motionevent MOVE 0 20
IN sleep 0.100
IN sleep 1.500
IN input motionevent UP 0 20"
is "drag: end hold before UP (a scrub resting on its letter)" "$(grep '^IN' "$LOG")" "$want"
out=$(run 'drag 0 0 0 20 0 200 2 x'); is "drag: bad end hold refused" "$(calls)" 0

echo "== cdp / hcall / shot =="
out=$(run 'printf "%s\n" "\"opened\"" > cdp.answers; cdp_val "1" app'); is "cdp_val unquotes a JSON string" "$out" "opened
rc=0"
is "cdp_val: page and js" "$(cat "$W/cdp.log")" "CDP app 1"
out=$(run 'printf "%s\n" "{\"a\":1}" > cdp.answers; cdp_val "1"'); is "cdp_val: a JSON object stays JSON" "$out" '{"a": 1}
rc=0'
out=$(run 'printf "x\r\n" > cdp.answers; cdp_eval home 1 | tr -dc "\\r" | wc -c | tr -d " "'); is "cdp_eval strips \\r" "$out" "0
rc=0"
out=$(run 'hcall tasks.list "[]" "l=>l.length"'); is "hcall: an answer" "$out" "ok
rc=0"
grep -q "id=910300+" "$W/cdp.log" && grep -q "'tasks.list',JSON.stringify(\[\])" "$W/cdp.log" && ok "hcall: default id base, method, args" || bad "hcall js" "$(cat "$W/cdp.log")"
out=$(run 'HCALL_ID=910400; hcall a "[]" "v=>v"'); grep -q "id=910400+" "$W/cdp.log" && ok "hcall: HCALL_ID" || bad "HCALL_ID" "$(cat "$W/cdp.log")"
out=$(run 'printf "\n\"yes\"\n" > cdp.answers; hcall m "[]" "v=>v"')
is "hcall: an empty answer is retried" "$(printf '%s\n' "$out" | tr '\n' '|')" "hcall []: try 1: ''|yes|rc=0|"
out=$(run 'HCALL_TRACE=0; printf "\n\"yes\"\n" > cdp.answers; hcall m "[]" "v=>v"'); is "hcall: HCALL_TRACE=0" "$out" "yes
rc=0"
out=$(run 'shot a.png'); is "shot: shot.sh's last line" "$out" "saved a.png (inner)
rc=0"

echo "== verdicts =="
out=$(run 'pass one; fail two; fail three; result "all"'); is "fails counted -> FAIL, rc 1" "$(printf '%s\n' "$out" | tr '\n' '|')" "PASS: one|FAIL: two|FAIL: three|FAIL: 2 step(s) failed|rc=1|"
out=$(run 'pass one; result "all good"'); is "no fails -> PASS, rc 0" "$(printf '%s\n' "$out" | tr '\n' '|')" "PASS: one|PASS: all good|rc=0|"
out=$(run 'skip "folded (needs the inner screen)"; echo after'); is "skip: SKIP: line, rc 0, stops" "$(printf '%s\n' "$out" | tr '\n' '|')" "SKIP: folded (needs the inner screen)|rc=0|"
out=$(run 'OUT=$PWD/o; mkdir -p "$OUT"; step "s1" >/dev/null; fail x >/dev/null; cat "$OUT/log.txt"'); is "OUT/log.txt gets the lines" "$(printf '%s\n' "$out" | tr '\n' '|')" "== s1|FAIL: x|rc=0|"

echo "== a check's own helpers win =="
out=$(reset; cd "$W" && T=$W A=$W/adb.sh bash -c "fail() { echo mine; }; sh_() { echo own-sh; }; . '$BASE'; fail x; sh_ y; tap() { echo later; }; tap 1 2")
is "defined before: kept; after: theirs" "$(printf '%s\n' "$out" | tr '\n' '|')" "mine|own-sh|later|"
out=$( (unset here T A; cd "$W" && bash -c ". '$BASE'; echo \"\$T|\$A\"") )
is "here/T/A default from base.sh's own place" "$out" "$ROOT/tools/phone/verify/..|$ROOT/tools/phone/verify/../adb.sh"
out=$(cd "$W" && T=$W A=$W/adb.sh bash -c "set -euo pipefail; . '$BASE'; tap 1 2 >/dev/null; echo fine" 2>&1); is "set -euo pipefail safe" "$out" "fine"
command -v /bin/bash >/dev/null && { /bin/bash -n "$BASE" && ok "bash -n (/bin/bash)" || bad "bash -n"; }
python3 "$ROOT/tools/agents/shell-pitfalls.py" "$BASE" >/dev/null 2>&1 && ok "shell-pitfalls clean" || bad "shell-pitfalls" "$(python3 "$ROOT/tools/agents/shell-pitfalls.py" "$BASE" 2>&1)"

echo "== lint: no pasted copy of base.sh's forms in tools/phone/verify =="
# The forms 52 / 8 / 1 checks pasted before base.sh (11-24). Another fork of them is fine; a copy is not.
SH_FORM="sh_() { \"\$A\" shell \"su -c '\$*'\" 2>/dev/null | tr -d '\\r'; }"  # lint-ok: the pasted form, searched for
HC_RETRY="hcall() { local v i; for i in 1 2 3 4; do v=\$(hcall_once \"\$@\"); case \$v in \"\"|\"cdp: adb\"*|*\"isn't running\"*|\"no page\"*)"
HC_TRACE="$HC_RETRY echo \"hcall \$2: try \$i: '\${v}'\" >&2; sleep 2 ;; *) echo \"\$v\"; return ;; esac; done; echo \"ERR no answer after 4 tries (\${v:-empty})\"; }"
HC_QUIET="$HC_RETRY sleep 2 ;; *) echo \"\$v\"; return ;; esac; done; echo \"ERR no answer after 4 tries (\${v:-empty})\"; }"
pasted() { grep -lxF -e "$SH_FORM" -e "$HC_TRACE" -e "$HC_QUIET" -- "$@" 2>/dev/null; }
for f in sh:SH_FORM trace:HC_TRACE quiet:HC_QUIET; do
  eval "printf '%s\n' \"x=1\" \"\$${f#*:}\"" > "$W/pasted.sh"
  [ -n "$(pasted "$W/pasted.sh")" ] && ok "the lint sees a pasted ${f%%:*} form" || bad "the lint misses the ${f%%:*} form"
done
grep -qxF "$HC_TRACE" <(sed -n '/^declare -F hcall >/s/^declare -F hcall >\/dev\/null || //p' "$BASE" | sed 's/\[ "\${HCALL_TRACE:-1}" = 0 \] || //') &&
  ok "the lint's traced hcall form is base.sh's" || bad "HC_TRACE drifted from base.sh's hcall"
hits=$(cd "$ROOT/tools/phone/verify" && pasted *.sh | grep -vx base.sh)
[ -z "$hits" ] && ok "no copies of sh_/hcall - source base.sh" || bad "pasted base.sh forms (replace with: . \"\$here/base.sh\")" "$hits"

echo ""; echo "== Results: $PASS passed, $FAIL failed =="; [ "$FAIL" -eq 0 ]
