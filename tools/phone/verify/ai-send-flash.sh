#!/bin/bash
# ai-send-flash.sh [OUT] (board ai-page-black-flash-after-sending-a-message): sending on home's AI page stays in place.
# Home, the swipe to the AI page, then while the ON display is screenrecorded: one harmless test message typed into the
# page's own field and submitted (CDP: the field's value + its form's submit, the same send() the send button runs).
# PASS = no PowosAiActivity start/new-intent in the events log since the send, and 0 black frames in the recording
# (a frame's mean luma under max(12, 30% of the clip's median)). Restores home. Exit 0 pass, 1 fail, 3 a real touch /
# screen not awake (re-queued), 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/ai-send-flash-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
MSG="flash check from a test script, please ignore - just reply: ok"
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
home() { sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; }
. "$here/window-lock.sh"; window_lock ai-send-flash.sh 90
trap 'home; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\"" | grep -q true && { echo "locked - stopping"; exit 5; }
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }
DID=$(sh_ "dumpsys display" | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)",.* state ON,.*/\1/p' | head -1)
[ -n "$DID" ] || { echo "no display is on"; exit 3; }
echo "on: ${W}x${H} display $DID"
home; chk home
sh_ "input swipe $((W * 3 / 10)) $((H / 2)) $((W * 9 / 10)) $((H / 2)) 350"; sleep 1.5; chk page
shown=$("$T/cdp.sh" eval home '!!document.querySelector(".ai-screen.shown .ai-compose textarea")' 2>&1 | tail -1)
[ "$shown" = true ] || { echo "the AI page's field isn't showing ($shown)"; exit 5; }
since=$(sh_ "date +%m-%d\ %H:%M:%S.000")
V=/data/local/tmp/ai-send-flash.mp4
"$A" shell "su -c 'rm -f $V; screenrecord --display-id $DID --bit-rate 20000000 --time-limit 7 $V'" >/dev/null 2>&1 &
rp=$!; sleep 2; chk before-send
"$T/cdp.sh" eval home '(()=>{const f=document.querySelector(".ai-screen.shown .ai-compose");const t=f.querySelector("textarea");t.value='"\"$MSG\""';t.dispatchEvent(new Event("input",{bubbles:true}));f.requestSubmit();return "sent"})()' 2>&1 | tail -1
wait $rp; chk after-send
sent=$("$T/cdp.sh" eval home 'document.querySelector(".ai-screen.shown")?.textContent.includes('"\"$MSG\""')' 2>&1 | tail -1)
starts=$(sh_ "logcat -d -b events -T \"$since\"" | grep -E "wm_(create_activity|new_intent|restart_activity).*PowosAiActivity")
"$A" exec-out "su -c 'cat $V'" > "$OUT/ai-send-flash.mp4"; sh_ "rm -f $V"
"$T/shot.sh" "$OUT/ai-send-flash-after.png" >/dev/null 2>&1
home; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
docker run --rm -v "$OUT":/w -w /w linuxserver/ffmpeg:latest -loglevel error -i ai-send-flash.mp4 \
  -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=luma.txt" -f null - 2>&1 | tail -3
python3 - "$OUT/luma.txt" "$sent" "$starts" <<'PY'
import re, statistics, sys
ys = [float(m) for m in re.findall(r"YAVG=([0-9.]+)", open(sys.argv[1]).read())]
sent, starts = sys.argv[2], sys.argv[3].strip()
if not ys: print("verify FAIL: no frames in the recording"); sys.exit(1)
med = statistics.median(ys); cut = max(12.0, 0.3 * med)
black = [i for i, y in enumerate(ys) if y < cut]
print(f"{len(ys)} frames, median luma {med:.1f}, min {min(ys):.1f}, black (<{cut:.1f}): {len(black)} {black[:20]}")
print(f"message on the page: {sent}; PowosAiActivity starts since the send: {len(starts.splitlines()) if starts else 0}")
if starts: print(starts)
ok = not black and not starts and sent == "true"
print("verify PASS: sending on the AI page stays in place, 0 black frames" if ok else
      f"verify FAIL: {len(black)} black frames, {len(starts.splitlines()) if starts else 0} activity starts, sent={sent}")
sys.exit(0 if ok else 1)
PY
