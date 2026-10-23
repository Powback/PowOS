#!/bin/bash
# shade-wide.sh (board "Unfolded shade: notifications left, controls right"; queue.sh runs it with LOCK_HELD=1): the
# unfolded shade is two columns. A finger from the status bar's left part, then its right part, opens it; each time,
# over CDP (read-only): .panel-body.two, the notifications column left of the controls, data-from = the side pulled.
# A screencap of the first goes to the phone (/home/powos/design-qa) and its path to the manager (comms, --from shade).
# Back + Home after. Changes no setting. Exit 1 + "FAIL" on a miss, 3 (SKIP) folded / not live yet / a real touch.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
[ -n "${LOCK_HELD:-}" ] || { echo "shade-wide: run it through tools/phone/verify/queue.sh add"; exit 3; }
OUT=$HOME/.cache/powos-verify/shade-wide-$(date +%m%d-%H%M); mkdir -p "$OUT"
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
q() { "$T/cdp.sh" eval "$1" "$2" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
home() { sh_ "input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1; }
trap home EXIT
[ "$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")" = Awake ] || { echo "SKIP shade-wide: the screen is off - not woken (rule)"; exit 3; }
sh_ "cmd statusbar collapse; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5
[ "$(q home 'fetch("/ui/notifications.tsx").then(r=>r.text()).then(t=>t.includes("wideShade"))')" = true ] ||
  { echo "SKIP shade-wide: the two-column shell isn't live on the phone yet"; exit 3; }
[ "$(q home 'innerWidth >= 700')" = true ] || { echo "SKIP shade-wide: the phone is folded - needs it unfolded"; exit 3; }
read -r W H < <(sh_ "dumpsys display" | sed -nE 's/.*DisplayDeviceInfo.*uniqueId="local:[0-9]+", ([0-9]+) x ([0-9]+),.* state ON,.*/\1 \2/p' | head -1)
[ -n "${H:-}" ] || { echo "SKIP shade-wide: no display on"; exit 3; }
L='(()=>{const b=document.querySelector(".notif-panel.shown .panel-body");if(!b)return "shut";const n=b.querySelector(":scope>.notif-col")?.getBoundingClientRect(),c=b.querySelector(":scope>.cc-col")?.getBoundingClientRect();return [b.classList.contains("two"),b.dataset.from,!!(n&&c&&n.right<=c.left+1),Math.round(n?.width||0),Math.round(c?.width||0)].join(" ")})()'
I0=$(irq); fails=()
# A finger down on the status bar at x, pulled to 40% of the screen in one phone call, let go.
pull() {
  local c="input motionevent DOWN $1 8; " i
  for i in $(seq 1 20); do c+="input motionevent MOVE $1 $((8 + i * H / 50)); "; done
  "$A" shell "$c input motionevent UP $1 $((8 + 20 * H / 50))" >/dev/null; sleep 1.5
  [ "$(irq)" = "$I0" ] || { echo "SKIP shade-wide: a real touch - stopped"; exit 3; }
}
pull $((W / 5)); left=$(q shade "$L")
shot=$OUT/shade-wide.png; "$T/shot.sh" "$shot" >/dev/null 2>&1 || shot=""
[[ "$left" == "true notifications true"* ]] || fails+=("from the left: not two columns opened on notifications ($left)")
home
pull $((W * 4 / 5)); right=$(q shade "$L")
[[ "$right" == "true control true"* ]] || fails+=("from the right: not two columns opened on the controls ($right)")
on=""
if [ -n "$shot" ]; then
  on=$("$T/review-image.sh" "$shot" 2>/dev/null | sed -n 's/^on phone: //p' | tail -1)
  if [ -n "$on" ]; then
    m=$OUT/mail.sh; printf 'powos comms send manager %q --from shade\n' "Unfolded shade, two columns (notifications left, controls right): $on" >"$m"
    "$T/user.sh" "$m" >/dev/null 2>&1 || on="$on (mail failed)"
  fi
fi
echo "shade-wide: left=[$left] right=[$right] shot=${shot:-none} phone=${on:-none}"
[ ${#fails[@]} -eq 0 ] && { echo "PASS shade-wide: unfolded two columns, notifications left, controls right; left pull -> notifications, right -> controls; shot $on"; exit 0; }
echo "FAIL shade-wide: ${fails[*]}"; exit 1
