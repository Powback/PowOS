# shellcheck shell=bash
# tools/phone/verify/kwin-activate-lib.sh (sourced by kwin-activate.sh and test/tier1/test-kwin-activate.sh): the
# decision of WHETHER a KWin the rooted deploy installed may be activated now (a session restart). Pure: no adb, no
# phone - the inputs are what kwin-activate.sh read off the phone, so the policy is tested on the Mac.
# Policy (coordinator decision 2026-11-23, docs/AGENT-HANDBOOK.md "KWin activation"): the rooted deploy installs a new
# kwin package but the session's kwin_wayland keeps running the old one (its libkwin mapped "(deleted)") until the
# Linux session restarts. The verify queue's idle window (window-lock.sh: nobody touched the phone for its idle
# threshold) activates it - but never over a game, and never over a Linux app the user started (a session restart
# ends both). Steam alone is no blocker: it is closed gracefully and started again after the restart.
#
# kwact_decide <kwin_new> <game> <apps> <steam>
#   kwin_new  1 = the running KWin is the installed package already; 0 = stale; anything else = unknown
#   game      game_up's answer: "none", a Steam app id, or "" (adb didn't say)
#   apps      the Linux apps with a window (windows.list's l:<id> keys, space separated, l:steam allowed), "none", or
#             "ERR..." / "" (home's bridge didn't answer)
#   steam     up | down | "" (unknown)
# Prints one line, first word the verdict:
#   active                 nothing to do (already running the installed KWin)
#   restart                restart the session now
#   restart-steam          close Steam gracefully, restart, start Steam again
#   wait <why>             not now (stays queued): a game, a user's Linux app, or something the phone didn't answer
kwact_decide() {
  local kn=$1 game=$2 apps=$3 steam=$4 a others=""
  case $kn in 1) echo active; return ;; 0) ;; *) echo "wait the running KWin's state is unknown ($kn)"; return ;; esac
  case $game in
    none) ;;
    '') echo "wait the phone didn't say whether a game runs"; return ;;
    *) echo "wait a game runs (Steam app $game) - never closed for a KWin activation"; return ;;
  esac
  case $apps in ''|ERR*) echo "wait home's window list didn't answer (${apps:-no answer})"; return ;; esac
  for a in $apps; do
    case $a in none|l:steam) ;; l:*) others="$others ${a#l:}" ;; esac
  done
  [ -z "$others" ] || { echo "wait Linux apps open:$others - a session restart would close them"; return; }
  case $steam in
    up) echo restart-steam ;;
    down) echo restart ;;
    *) echo "wait whether Steam runs is unknown" ;;
  esac
}

# kwact_status <file> <state> <version> [why...]: the ship status line's record (ship.sh status reads it):
# "<state> <version> <epoch> <why>" - pending | waiting | active | failed.
kwact_status() { local f=$1 s=$2 v=$3; shift 3; mkdir -p "$(dirname "$f")"; printf '%s %s %s %s\n' "$s" "$v" "$(date +%s)" "$*" > "$f"; }
# kwact_status_line <file>: what ship.sh status prints for it, or nothing.
kwact_status_line() { local s v t why
  [ -s "$1" ] || return 0
  read -r s v t why < "$1"
  case $s in
    pending) echo "kwin $v installed, active after next idle window" ;;
    waiting) echo "kwin $v installed, active after next idle window (last try $(date -r "$t" +%H:%M 2>/dev/null || date -d "@$t" +%H:%M): $why)" ;;
    active) echo "kwin $v active (since $(date -r "$t" '+%m-%d %H:%M' 2>/dev/null || date -d "@$t" '+%m-%d %H:%M'))" ;;
    failed) echo "kwin $v installed, activation FAILED: $why" ;;
  esac; }
