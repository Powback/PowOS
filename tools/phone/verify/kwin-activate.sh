#!/bin/bash
# lanes: phone
# kwin-activate.sh [--dry-run] [OUT]: makes the KWin the rooted deploy installed the RUNNING one - a session restart in
# the verify queue's idle window - when nothing the user has open would be lost (coordinator decision 2026-11-23,
# docs/AGENT-HANDBOOK.md "KWin activation"). Queued by tools/phone/kwin-pending.sh after a rooted deploy left the session's
# kwin_wayland on the old package (libkwin mapped "(deleted)"); `queue.sh add kwin-activation tools/phone/verify/kwin-activate.sh`.
#   - already running the installed KWin (kwin_new=1): PASS, nothing done
#   - a game runs (game-lib.sh game_up: Steam's reaper), or a Linux app other than Steam has a window, or the phone
#     didn't answer: exit 3 - stays queued for the next idle window. A game is never closed; a Linux app never either.
#   - Steam only: closed gracefully (thawed, `steam -shutdown`), session restarted (kwin-up.sh kwin_restart: `android-
#     request power logout`), Steam started again the way it was: with its window through home's launch call when it
#     had one, else out of sight (powos-steam-resident's autostart does it; `steam -silent` when that is off)
#   - nothing open: session restarted
# --dry-run: reads the phone and prints the decision only (no lock, no restart, no input) - "DRY-RUN: would ...".
# Ship status: ${SHIP_DIR:-~/.cache/powos-ship-queue}/kwin-activation (kwin-activate-lib.sh kwact_status), shown by
# `tools/phone/ship.sh status` as "kwin X installed, active after next idle window" / "kwin X active".
# No touch injection anywhere (bridge calls and shell only). A finger between the decision and the restart: exit 3.
# Exit: 0 PASS (active); 1 FAIL; 3 not now (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
OUT=${1:-$HOME/.cache/powos-verify/kwin-activate-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
ST=${KWACT_STATUS:-${SHIP_DIR:-$HOME/.cache/powos-ship-queue}/kwin-activation}
. "$here/kwin-activate-lib.sh"
. "$here/game-lib.sh"
. "$here/kwin-up.sh"
. "$here/base.sh"  # sh_ and the shared check helpers (tools/phone/verify/base.sh)
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '\''/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}'\'' /proc/interrupts"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; [ $DRY = 1 ] || [ "${ACTIVE:-0}" = 1 ] || kwact_status "$ST" failed "${KV:-?}" "$*"; exit 1; }
# hcall: a call on home's bridge exactly as the page makes it (linux-win-lib.sh's).
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=913400+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
# The Linux apps with a window (home's windows.list, l:<id>), "none", or ERR...
linux_apps() { hcall windows.list "[]" "l=>{const a=[...new Set((l||[]).map(w=>String(w.app||'')).filter(k=>k.startsWith('l:')))];return a.length?a.join(' '):'none'}"; }
# powos-steam-resident's own test: Steam's pid file points at a live steam (or FEX running it).
steam_state() { us 'case $(readlink "/proc/$(cat "$HOME/.steam/steam.pid" 2>/dev/null || echo 0)/exe" 2>/dev/null) in */steam|*/FEX*) echo up ;; *) echo down ;; esac' | tail -1; }
steam_close() {
  us 'timeout 2 dbus-send --session --print-reply=literal --reply-timeout=1500 --dest=dev.powos.Sleep /Gui dev.powos.Sleep.Gui.Wake string:steam >/dev/null 2>&1
      (timeout -k 1 10 steam -shutdown >/dev/null 2>&1 </dev/null &)
      for i in $(seq 60); do case $(readlink "/proc/$(cat "$HOME/.steam/steam.pid" 2>/dev/null || echo 0)/exe" 2>/dev/null) in */steam|*/FEX*) sleep 0.5 ;; *) echo closed; exit 0 ;; esac; done; echo still-up' | tail -1; }

[ $DRY = 1 ] || { . "$here/window-lock.sh"; window_lock kwin-activate.sh 120; trap '[ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$HOME/.cache/powos-verify.lock"' EXIT; }
KV=$(kwin_installed); [ -n "$KV" ] || { echo "ENV: can't read the installed kwin (pacman -Q kwin)"; exit 5; }
echo "VERSION kwin $KV"
s=$(kwin_state); kn=$(sed -n 's/.*kwin_new=\([01]\).*/\1/p' <<<"$s")
I0=$(irq)
g=$(game_up)
apps=none; stw=down; steam=""
if [ "$kn" = 0 ] && [ "$g" = none ]; then
  apps=$(linux_apps); steam=$(steam_state)
fi
d=$(kwact_decide "${kn:-?}" "$g" "$apps" "$steam")
log "kwin $KV, running: $s; game: ${g:-?}; Linux windows: ${apps:-?}; Steam: ${steam:-?} -> $d"
case " $apps " in *" l:steam "*) stw=window ;; esac

if [ $DRY = 1 ]; then
  case $d in
    active) echo "DRY-RUN: kwin $KV is already the running KWin - nothing to do" ;;
    restart) echo "DRY-RUN: would restart the session now (nothing open)" ;;
    restart-steam) echo "DRY-RUN: would close Steam ($stw), restart the session, start Steam again" ;;
    wait*) echo "DRY-RUN: would wait - ${d#wait }" ;;
  esac
  echo "PASS: dry run - decision '${d%% *}' (nothing changed)"; exit 0
fi

case $d in
  active) kwact_status "$ST" active "$KV"; echo "PASS: kwin $KV active ($s)"; exit 0 ;;
  wait*) kwact_status "$ST" waiting "$KV" "${d#wait }"; echo "not now: ${d#wait } - stays queued"; exit 3 ;;
esac
[ "$(irq)" = "$I0" ] || { echo "STOP: a real touch before the restart - not now"; exit 3; }
if [ "$d" = restart-steam ]; then
  log "closing Steam gracefully (it had $([ $stw = window ] && echo a window || echo no window))"
  c=$(steam_close); log "Steam: ${c:-?}$([ "$c" = still-up ] && echo ' after 30 s - the session restart ends it')"
fi
# The last look before the session goes: a game started meanwhile (or a finger) keeps everything as it is.
g=$(game_up); [ "$g" = none ] || { log "a game came up (${g:-unknown}) - not now"; kwact_status "$ST" waiting "$KV" "a game came up"; exit 3; }
[ "$(irq)" = "$I0" ] || { echo "STOP: a real touch before the restart - not now"; exit 3; }
log "restarting the Linux session for kwin $KV"
kwin_restart || fail "KWin didn't come back as a new process on the installed $KV: $KWIN_WHY"
s=$(kwin_state); [[ $s == *kwin_new=1* ]] || fail "after the restart the running KWin is still not the installed $KV ($s)"
kwact_status "$ST" active "$KV"; ACTIVE=1   # a Steam relaunch FAIL below is its own; KWin stays recorded active
log "kwin $KV active: $s"
if [ "$d" = restart-steam ]; then
  if [ $stw = window ]; then
    r=; for _ in $(seq 20); do r=$(hcall apps.launch "['l:steam']" "()=>'ok'"); [ "$r" = ok ] && break; sleep 3; done
    [ "$r" = ok ] || fail "kwin $KV active, but Steam's window couldn't be started again (home's apps.launch: $r)"
    for _ in $(seq 20); do [ "$(steam_state)" = up ] && break; sleep 3; done
    [ "$(steam_state)" = up ] || fail "kwin $KV active, but Steam didn't come back within 60 s of its launch"
    log "Steam started again with its window"
  elif us '[ -e "${XDG_CONFIG_HOME:-$HOME/.config}/powos/steam-resident-off" ] && echo off' | grep -q off; then
    us 'cd "$HOME"; setsid -f steam -silent </dev/null >/dev/null 2>&1; echo started' >/dev/null
    log "Steam started again out of sight (steam -silent; powos-steam-resident is off)"
  else
    log "Steam comes back out of sight with the session (powos-steam-resident's autostart)"
  fi
fi
echo "PASS: kwin $KV active ($s)"
