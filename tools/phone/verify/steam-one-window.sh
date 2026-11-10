#!/bin/bash
# lanes: phone
# needs: kwin
# steam-one-window.sh [OUT] (board steam-opens-as-two-windows-only-one-window-for-i; Mac side, queue it with --budget 600):
# ONE tap on Steam gives ONE window - kwin 0052 (6.7.5-3.59) offers an X11 window with no desktop file by its WM_CLASS
# ("steam"), so Steam's window takes its launch placeholder ("l:steam") instead of opening a second, unnamed window
# beside it (2026-11-02: two windows). On the unfolded home, no Steam window up yet: a tap on the dock's Steam cell
# (else home's launch call), then up to 180 s for Steam's window to go live, then 15 s for a late second one.
# PASS: exactly one window of Steam's - web windows with key l:steam plus old-path windows (windows.list app l:steam)
# - and no other window appeared since the tap (no unnamed "" window); its body is live (Steam's frames, not the
# placeholder). Artefacts: OUT/log.txt, OUT/steam.png, OUT/fail.png. Steam is left running and shown (as steam-tap.sh).
# NEEDS: the user's "you may launch games for tests" - it starts Steam. Exit: 0 pass; 1 FAIL; 3 a real touch / not
# now; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/steam-one-window-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
MIN=${KWIN_MIN:-6.7.5-3.59}
. "$here/linux-win-lib.sh"
. "$here/window-lock.sh"
window_lock steam-one-window.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
printf 'v=$(pacman -Q kwin | cut -d" " -f2); echo "$v $(vercmp "$v" %s)"\n' "$MIN" > "$OUT/q.sh"
kv=$("$T/root.sh" "$OUT/q.sh" 2>/dev/null | tail -1 | tr -d '\r'); log "kwin $kv (needs >= $MIN)"
[ "${kv##* }" -ge 0 ] 2>/dev/null || fail "KWin ${kv%% *} older than $MIN (queue kwin-install.sh $MIN first)"
unfolded_home
GAME_GATE_PREFIX=""; . "$(dirname "$0")/game-lib.sh"; game_gate   # one test for every check (game-lib.sh)

hcall_page() { "$T/cdp.sh" eval home "$1" 2>&1 | tr -d '"\r' | tail -1; }
# Every window home knows: "<web|task>:<id>:<key>" per line (web windows, then the old path's).
allwins() {
  hcall webwindows.list "[]" "l=>l.map(w=>'web:'+w.id+':'+(w.key||'')).join(' ')" | tr ' ' '\n'
  hcall windows.list "[]" "l=>l.map(w=>'task:'+w.id+':'+(w.app||w.pkg||'')).join(' ')" | tr ' ' '\n'
}
steamwins() { allwins | grep -c ':l:steam$'; }
W0=$(allwins | grep -v '^ERR' | sort); echo "$W0" > "$OUT/before.txt"
[ "$(steamwins)" = 0 ] || { echo "Steam has a window already (the user's?): not now"; exit 3; }
LIN0=$(lin); MINE="steam"

xy=$("$T/cdp.sh" eval home "(()=>{const e=document.querySelector('.home .dock .app[data-key=\"l:steam\"]');if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.left+r.width/2)*d)+' '+Math.round((r.top+r.height/2)*d)})()" 2>&1 | tr -d '"\r' | tail -1)
if [[ $xy =~ ^[0-9]+\ [0-9]+$ ]]; then log "tap: the dock's Steam cell at $xy"; sh_ "input tap $xy"
else log "tap: no Steam cell in the dock ($xy) - home's launch call"; hcall apps.launch "['l:steam']" "()=>'ok'" >/dev/null; fi
t0=$SECONDS; state=none
while [ $((SECONDS - t0)) -lt 180 ]; do
  sleep 3; chk "waiting for Steam"
  id=$(allwins | grep ':l:steam$' | head -1 | cut -d: -f2)
  [ -n "$id" ] || continue
  state=$(hcall_page "(()=>{const e=document.querySelector('.webwindow[data-wwid=\"$id\"] .webwindow-body');return e?(e.classList.contains('live')?'live':'placeholder'):'old-path'})()")
  [ "$state" = placeholder ] || break
done
log "Steam's window: ${id:-none} ($state) $((SECONDS - t0)) s after the tap"
[ -n "${id:-}" ] || fail "no Steam window $((SECONDS - t0)) s after the tap"
[ "$state" != placeholder ] || fail "Steam's window $id is still its placeholder after 180 s (Steam's own window went elsewhere?)"
sleep 15; chk settle
"$T/shot.sh" "$OUT/steam.png" >/dev/null 2>&1
W1=$(allwins | grep -v '^ERR' | sort); echo "$W1" > "$OUT/after.txt"
new=$(comm -13 <(echo "$W0") <(echo "$W1")); n=$(steamwins)
log "windows new since the tap: $(echo "$new" | xargs)"
[ "$n" = 1 ] || fail "$n windows of Steam's (want 1): $(echo "$new" | xargs)"
others=$(echo "$new" | grep -v ':l:steam$' | grep -v '^$')
[ -z "$others" ] || fail "one tap on Steam opened another window too: $(echo "$others" | xargs)"
pass "one tap on Steam: one window ($id, $state)"
