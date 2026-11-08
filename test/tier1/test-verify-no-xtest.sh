#!/bin/bash
# test-verify-no-xtest.sh: no verify check sends X input through XTEST (11-08 02:02: bf-play's `xdotool key` made KWin
# start its "Remote Control" prompt (kwin_eis_prompter) for the XTEST client; the prompt took the focus, Broforce
# minimized itself and the keys were lost - docs/research/broforce-fps.md). The prompt's settings are the owner's
# (security), so checks send input the way the user's arrives: the on-screen controls' pad (pad-lib.sh -> powos-padd)
# or Android `input tap/swipe/keyevent`. Read-only X queries (xdotool search/getwindow*, windowactivate, xprop,
# xwininfo) stay.
#   - guard: no xdotool key/keydown/keyup/type/click/mouse*, xte or ydotool in tools/phone/verify (comments aside);
#     the guard itself catches the old forms (chained `windowactivate ... key`, `mousemove ... click 1`);
#   - pad_press sends PAD2 press + release packets, in order, to @powos.padd (a fake padd here), X key names mapped
#     (Return -> A, Escape -> B, Up -> d-pad up); an unknown key is refused without connecting;
#   - bf-play presses through pad_press; bf-pacing's play marks its keys' run as the tools' own (self_input_for), whose
#     mark is the epoch line idle.sh reads.
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)
V=$src/tools/phone/verify
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }

RE='xdotool[^|;&]*[[:space:]](key|keydown|keyup|type|click|mousemove|mousemove_relative|mousedown|mouseup)([[:space:]]|$|")|(^|[^[:alnum:]_-])(xte|ydotool)[[:space:]]|XTestFake'
hits=$(grep -rnE "$RE" "$V" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
[ -z "$hits" ] && ok "no verify script sends XTEST input" || bad "verify scripts send XTEST input (use pad-lib.sh pad_press or adb input)" "$hits"
for old in 'xdotool key --delay 80 "$k"' 'xdotool windowactivate --sync "$w" key --clearmodifiers Return' \
           'us "$X; xdotool mousemove --window $SW $x $y click 1"' 'xdotool key Escape'; do
  printf '%s\n' "$old" | grep -qE "$RE" || bad "guard misses: $old"
done
printf '%s\n' 'xdotool search --onlyvisible --class x' 'xdotool windowactivate --sync "$w"' 'xdotool getwindowname "$w"' \
  | grep -qE "$RE" && bad "guard flags a read-only query" || ok "guard: catches the old input forms, leaves queries"

# pad_press against a fake powos-padd (Linux abstract socket).
if [ "$(uname)" = Linux ]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/no-xtest.XXXXXX"); trap 'kill $sp 2>/dev/null; rm -rf "$T"' EXIT
  python3 - "$T/got" <<'PY' & sp=$!
import socket, struct, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind("\0powos.padd"); s.listen(1)
open(sys.argv[1] + ".ready", "w").close()
c, _ = s.accept(); buf = b""
while True:
    d = c.recv(4096)
    if not d: break
    buf += d
out = []
while len(buf) >= 40:
    m, b = struct.unpack_from("<4sI", buf); out.append("%s %d" % (m.decode(), b)); buf = buf[40:]
open(sys.argv[1], "w").write("\n".join(out) + ("\nleft %d" % len(buf) if buf else "") + "\n")
PY
  for _ in $(seq 50); do [ -e "$T/got.ready" ] && break; sleep 0.1; done
  out=$(PAD_HOLD_S=0.01 PAD_GAP_S=0.01 bash -c ". '$V/pad-lib.sh'; pad_press Return Escape Up" 2>&1)
  wait $sp
  want=$'PAD2 1\nPAD2 0\nPAD2 2\nPAD2 0\nPAD2 2048\nPAD2 0'
  [ "$(cat "$T/got" 2>/dev/null)" = "$want" ] && [ "$out" = "pad: A B up" ] && ok "pad_press: press + release per key, in order" \
    || bad "pad_press packets" "out: $out / got: $(tr '\n' ';' < "$T/got" 2>/dev/null)"
  bash -c ". '$V/pad-lib.sh'; pad_press F13" >/dev/null 2>&1 && bad "pad_press took an unknown key" || ok "pad_press refuses an unknown key"
else
  echo "SKIP pad_press socket test (needs Linux abstract sockets)"
fi

grep -qE '^[[:space:]]*pad_press "\$k"' "$V/bf-play.sh" && ok "bf-play presses through pad_press" || bad "bf-play doesn't use pad_press"
grep -q 'ASUSER_PRE=$(self_input_for' "$V/bf-pacing.sh" && grep -q 'powos-pad-lib.sh' "$V/bf-pacing.sh" \
  && ok "bf-pacing play: pad-lib pushed, keys' run marked as the tools' own" || bad "bf-pacing play: pad-lib push or self-input mark missing"
m=$(bash -c ". '$V/window-lock.sh'; self_input_for 30; echo; echo \"\$SELF_INPUT\"")
d=$(mktemp -d); m1=$(head -1 <<<"$m" | sed "s#/data/local/tmp#$d#"); now=$(date +%s); sh -c "$m1"
v=$(cat "$d/powos-selfinput"); rm -rf "$d"
[ "$v" -ge $((now + 29)) ] && [ "$v" -le $((now + 31)) ] && [ "$(tail -1 <<<"$m")" = 'echo $(( $(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; ' ] \
  && ok "self_input_for: the epoch mark idle.sh reads; SELF_INPUT unchanged" || bad "self_input_for" "$m / $v"

[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
