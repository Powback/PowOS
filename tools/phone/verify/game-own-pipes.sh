#!/bin/bash
# lanes: phone
# game-own-pipes.sh (board rooted-app-launches-don-t-inherit-the-powos-app; 27461ba1 RootedGuest.launch): starts
# Broforce (APP, default 274190) the way a drawer tap does - home's own apps.launch "l:<its .desktop id>", so the app's
# rooted launch path runs - and, once its Steam launch chain is up, reads every fd of Steam and of the game's process
# tree as Android root. PASS = none of them holds a pipe the PowOS app (com.powos.app) holds: then an APK update that
# restarts the app leaves no reader-less pipe to SIGPIPE the game. A game this check started is closed after (bf-stop.sh;
# Steam stays). `--probe-script` prints the root probe only (the fixture). Exit 0 PASS, 1 FAIL, 3 touched/no game yet.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); APP=${APP:-274190}
probe() { cat <<EOF
app=\$(pidof com.powos.app | awk '{print \$1}'); [ -n "\$app" ] || { echo NOAPP; exit; }
ai=" \$(ls -l /proc/\$app/fd 2>/dev/null | grep -o 'pipe:\[[0-9]*\]' | sort -u | tr '\n' ' ') "
rp=\$(pgrep -f "SteamLaunch AppId=$APP" | head -1); [ -n "\$rp" ] || { echo NOGAME; exit; }
tree=\$(ps -A -o PID=,PPID= | awk -v r="\$rp" '{c[\$2]=c[\$2]" "\$1} END{q=r; while(q!=""){n=split(q,a," "); q=""; for(i=1;i<=n;i++){o=o" "a[i]; q=q c[a[i]]}} print o}')
echo "TREE \$(echo \$tree | wc -w)"
for p in \$(cat /data/powos/root/home/powos/.steam/steam.pid 2>/dev/null) \$tree; do
  for f in \$(ls -l /proc/\$p/fd 2>/dev/null | grep -o 'pipe:\[[0-9]*\]' | sort -u); do
    case "\$ai" in *" \$f "*) echo "SHARED \$p \$(cat /proc/\$p/comm 2>/dev/null) \$f" ;; esac
  done
done
EOF
}
[ "${1:-}" = --probe-script ] && { probe; exit; }
. "$here/e2e-lib.sh"; OUT=$HOME/.cache/powos-verify/game-own-pipes-$(date +%m%d-%H%M); mkdir -p "$OUT"
. "$here/window-lock.sh"; window_lock game-own-pipes 120; e2e_touchwatch >/dev/null 2>&1; I0=$(irq); mine=
trap '[ -n "$mine" ] && "$T/user.sh" "$here/bf-stop.sh" >/dev/null 2>&1; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
r=$(probe | ash); case $r in NOAPP*) echo "SKIP: ENV: com.powos.app isn't running"; exit 5 ;; esac
if [ "$r" = NOGAME ]; then
  desk=$(us "f=\$(grep -lx 'Exec=steam steam://rungameid/$APP' /home/powos/.local/share/applications/*.desktop | head -1); basename \"\${f:-Broforce.desktop}\" .desktop")
  v=$(hcall apps.launch "['l:$desk']" "()=>'ok'"); [ "$v" = ok ] || { echo "FAIL: drawer launch l:$desk: $v"; exit 1; }; mine=1
  for _ in $(seq 30); do sleep 5; r=$(probe | ash); [ "$r" != NOGAME ] && break; done
  [ "$r" = NOGAME ] && { echo "precondition: l:$desk launched from the drawer, no Steam launch chain for $APP in 150 s - again later"; exit 3; }
  sleep 20; r=$(probe | ash)   # the game itself up under the reaper
fi
[ "$(irq)" = "$I0" ] || { echo "the user touched the phone - again later"; exit 3; }
echo "game-own-pipes: ${desk:+launched l:$desk; }$(grep -m1 '^TREE' <<<"$r" | cut -d' ' -f2) processes in the game's tree + Steam"
sh=$(grep '^SHARED' <<<"$r"); [ -n "$sh" ] && { echo "FAIL: game/Steam hold the PowOS app's pipes: $(cut -d' ' -f2- <<<"$sh" | head -4 | tr '\n' ';')"; exit 1; }
echo "PASS: Steam and the drawer-launched game hold none of com.powos.app's pipes - an APK update can't SIGPIPE them"
