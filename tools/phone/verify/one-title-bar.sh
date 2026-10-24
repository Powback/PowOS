#!/bin/bash
# lanes: phone
# one-title-bar.sh [OUT] (board one-title-bar-per-window-no-duplicate-on-csd-app): one title bar per window on the
# unfolded home, for a phone left unattended:
#   1. KWin with "decor" (pkgs/kwin 0026, 6.7.5-3.30+) running: linux-float.sh installs the newest built kwin package
#      first (and a fresh session) when the running KWin lacks it;
#   2. Kate (KWin draws its title bar, which a task doesn't show) through home's launch path: its frame HAS PowOS's bar
#      (window "PowOS window bar <task>"), logcat WindowTasks "decor N: KWin's title bar";
#   3. Steam (it draws its own title bar: client-side decorations) the same way: its frame has NO bar, only the grip
#      ("PowOS window grip <task>"), logcat "its own title bar"; a screencap (OUT/steam.png: one bar, Steam's own);
#   4. a drag on Steam's own title bar moves its task (KWin "move" -> the frame's drag): its bounds follow the finger.
# Restores: the windows it opened closed, home, `cmd device_state state reset`. Steam or Kate open already (the
# user's): not now. Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/one-title-bar-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
. "$here/linux-win-lib.sh"

kwin_with "draws its own title bar" "decor (pkgs/kwin 0026)"
. "$here/window-lock.sh"
window_lock one-title-bar.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
[ "$(us "pgrep -xc kate" | tail -1)" = 0 ] || { echo "Kate runs already (the user's?): not now"; exit 3; }
unfolded_home
# Steam may run resident with no window: only a Steam WINDOW is the user's.
[ "$(steam_window)" = none ] || { echo "Steam has a window already (the user's?): not now"; exit 3; }
LIN0=$(lin)
livelog one-title-bar 280

# 2. Kate keeps PowOS's bar.
KT=$(launch_task l:org.kde.kate 40); MINE="$MINE kate"; chk kate
[ -n "$KT" ] || fail "no window task for Kate within 40 s"
sleep 3; live
[ "$(frame_has "bar" "$KT")" = 1 ] || fail "Kate's window (task $KT) has no PowOS title bar - $(grep -a "decor" "$OUT/live.txt" | tail -2 | tr '\n' ' ')"
pass "Kate (KWin's title bar, not shown in a task) keeps PowOS's bar (task $KT)"
hcall tasks.remove "[$KT]" "()=>'ok'" >/dev/null; sleep 2

# 3. Steam: its own bar only.
ST=$(launch_task l:steam 150); MINE="$MINE steam"; chk steam
[ -n "$ST" ] || fail "no window task for Steam within 150 s"
sleep 6; live
"$T/shot.sh" "$OUT/steam.png" >/dev/null 2>&1
grep -a "decor" "$OUT/live.txt" | tail -3 | tee -a "$OUT/log.txt"
[ "$(frame_has "bar" "$ST")" = 0 ] || fail "Steam's window (task $ST) has PowOS's title bar over its own - $(grep -a "decor" "$OUT/live.txt" | tail -2 | tr '\n' ' ')"
[ "$(frame_has "grip" "$ST")" = 1 ] || fail "Steam's window (task $ST) has no frame at all (no grip): not framed"
pass "Steam (its own title bar) has no PowOS bar, only the grip - one title bar (OUT/steam.png)"

# 4. Its own bar moves it.
read -r l t r b <<<"$(tbounds "$ST")"
[ -n "${b:-}" ] || fail "no bounds for Steam's task $ST"
x=$((l + (r - l) * 55 / 100)); y=$((t + 30)); dx=-240; dy=160
log "drag Steam's own title bar at $x,$y by $dx,$dy (task at $l $t $r $b)"
sh_ "input motionevent DOWN $x $y; sleep 0.25; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do input motionevent MOVE \$(( $x + $dx * i / 12 )) \$(( $y + $dy * i / 12 )); done; sleep 0.3; input motionevent UP $((x + dx)) $((y + dy))"
sleep 2; chk drag; live
read -r l2 t2 r2 b2 <<<"$(tbounds "$ST")"
log "after: $l2 $t2 $r2 $b2; $(grep -aE "move [0-9]+:|moved by its own title bar|move not taken" "$OUT/live.txt" | tail -2 | tr '\n' ' ')"
[ $((l - l2)) -ge $((-dx / 2)) ] && [ $((t2 - t)) -ge $((dy / 2)) ] || fail "a drag on Steam's own title bar didn't move its window ($l $t -> ${l2:-?} ${t2:-?}; KWin 'move' seen: $(grep -ac "its own title bar dragged" "$OUT/live.txt"))"
pass "a drag on Steam's own title bar moves its window ($l,$t -> $l2,$t2)"
echo "all passed; artefacts: $OUT"
