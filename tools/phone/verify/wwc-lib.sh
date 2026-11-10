# shellcheck shell=bash
# tools/phone/verify/wwc-lib.sh (sourced; set NAME first): the frame of the small web-window checks (switcher-launch,
# ww-clamp, ww-close-min, ww-opens, ww-popup-x11, ww-stop) - ww-lib.sh's helpers plus what each would repeat: the free
# window, the unfold, a verdict that is never a FAIL for a user's touch, and putting back ONLY what the check opened.
#   wwc_start          idle 2+ min (idle.sh --wait; the runner's window already is), screen on, home in front (its page
#                      visible), folded -> unfolded (cmd device_state, reset after)
#   wwc_pick a b ...   the first of those KDE apps the user isn't running (its process name), rc 1 when all run
#   wwc_open <app>     opens org.kde.<app> through home's launch path (ww_open: live window), WID="w<id>"; closed after
#   wwc_ses <cmd>      a command in the Plasma session's own environment (kwin-hung-client.sh's ses)
#   bad <why>          one FAIL line (counted); wwc_end <summary> -> PASS / FAIL / not judged (a touch came: rc 3)
# Exit codes (queue.sh): 0 PASS, 1 FAIL, 3 not now / touched (stays queued).
T=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$T/verify/ww-lib.sh"
A="$T/adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/$NAME-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
NF=0 MINE_W="" MINE_P="" UNFOLDED=0 T0=0
say() { echo "$*" | tee -a "$OUT/log.txt"; }
sh_() { "$A" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }
bad() { say "FAIL $*"; NF=$((NF + 1)); }
wwc_skip() { say "SKIP $*"; wwc_clean; exit 3; }
# touched: a real finger since wwc_start (idle.sh's touch idle is shorter than the run).
touched() { local i; i=$("$T/idle.sh" | sed -nE 's/.*idle=([0-9]+).*/\1/p'); [ -n "$i" ] && [ "$i" -lt $((SECONDS - T0)) ]; }
# fold <state>: cmd device_state, marked as the tools' own input (powos-selfinput, window-lock.sh): the panels' resume
# moves the touch IRQs with no finger, which touched() would read as the user.
fold() { sh_ "echo \$(( \$(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; cmd device_state state $1"; }
wwc_clean() { local w p
  for w in $MINE_W; do ww_close "$w"; done; [ -n "$MINE_W" ] && sleep 1.5
  for p in $MINE_P; do ww_us "pkill -x '$p'; true" >/dev/null; done
  declare -F wwc_extra >/dev/null && wwc_extra
  [ "$UNFOLDED" = 1 ] && fold reset
  MINE_W="" MINE_P="" UNFOLDED=0; }
trap wwc_clean EXIT
# wwc_home: home's page in front and visible. Hidden (another activity in front - 11-09 21:52 a bare
# PowosWindowActivity and PowTerm were) its page calls hang to cdp.sh's 120 s timeout and hcall makes each 4 times:
# switcher-launch and ww-clamp spent their whole 300 s budget in ww_ready without a line of output. Short CDP
# timeouts here, so a page that doesn't answer is a quick "not now", never the budget.
wwc_vis() { CDP_TIMEOUT_S=15 ev "document.visibilityState"; }
# The shared helper (tools/phone/home-front.sh): the lock face dismissed, home the top resumed activity, its page
# visible over CDP.
wwc_home() { local o; o=$("$T/home-front.sh"); local rc=$?; say "$o"; return $rc; }
wwc_start() { local s
  # The runner (LOCK_HELD=1) starts a check only in a free window it already waited for; waiting again for 2 idle
  # minutes inside the check's 300 s budget can only spend it. Run by hand, the wait stays.
  if [ "${LOCK_HELD:-0}" != 1 ]; then
    "$T/idle.sh" --wait 120 1800 >/dev/null || { echo "SKIP phone busy (not idle 2 min within 30 min)"; exit 3; }; fi
  s=$("$T/idle.sh"); case $s in *screen=Awake*) ;; *) echo "SKIP screen not on ($s)"; exit 3 ;; esac
  T0=$SECONDS
  wwc_home || wwc_skip "home's page isn't visible after going home ($(wwc_vis | head -c 60))"
  CDP_TIMEOUT_S=20 ww_ready || { fold 3; UNFOLDED=1; sleep 3; }
  CDP_TIMEOUT_S=20 ww_ready || wwc_skip "home shows no web windows even unfolded (web windows off?)"; }
wwc_pick() { local a; for a in "$@"; do ww_running "$a" || { echo "$a"; return 0; }; done; return 1; }
wwc_open() { MINE_P="$MINE_P $1"   # not in $(...): MINE_* must stay set for wwc_clean
  WID=$(ww_open "l:org.kde.$1" 45) || { bad "open $1: $WID"; WID=""; return 1; }
  MINE_W="$MINE_W $WID"; say "opened $1 as $WID"; }
wwc_ses() { ww_us "P=\$(pgrep -x plasmashell | head -1); while IFS= read -r -d '' kv; do export \"\$kv\"; done < /proc/\$P/environ; $1"; }
wwc_end() {
  if [ "$NF" = 0 ]; then say "PASS $NAME: $*"; exit 0; fi
  touched && { say "STOP: a real touch during the run - not judged, stays queued"; exit 3; }
  "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; say "RESULT $NAME: FAIL ($NF) - $OUT"; exit 1; }
