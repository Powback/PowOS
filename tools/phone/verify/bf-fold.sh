#!/bin/bash
# lanes: phone
# bf-fold.sh: (Mac side; queue it: queue.sh add [--close] <board-task> bf-fold.sh) Broforce survives folding the phone
# mid-game (skill powos-games). In one free window: KWin 3.21+ (pkgs/kwin 0017: a full-screen window task keeps its
# size and is scaled to fit) installed and running (a fresh session if the running one is older than the installed
# one - never while a Broforce runs on the old KWin: exit 3, next window), Broforce up the way the user starts it
# (powos-open-task: a Broforce the user started and left, frozen in the background, is resumed; else a launch) and
# past its sleep grace, then unfolded -> forced CLOSED
# (cmd device_state state 0) -> 25 s later (past the 15 s sleep timer) -> forced OPENED (state 3), each step: the
# game's reaper + X window unchanged, its size kept, not frozen, its window changing (x11grab), SurfaceFlinger
# presents of the window task, and a screencap's black bars (letterboxed on the cover). The forced state is always
# reset; a Broforce it started is closed, one the user had left is frozen again (`powos game 274190 freeze`).
# Artefacts ~/.cache/powos-verify/bf-fold-<date>/. Exit 3 = no window/touched.
#   KWIN_MIN=<ver-rel> the oldest KWin with the fix (default 6.7.5-3.21); an older one installed: FAIL, nothing installed.
#   KWIN_PKG=<pkg.tar.xz> installs that package first, only when it is NEWER than the installed KWin (pacman -U). Never
#   a downgrade: an old kit's KWIN_PKG (3.21) once replaced the installed 3.22 (2026-10-23 02:02).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); P=$here/..; A=$P/adb.sh; repo=$(cd "$here/../../.." && pwd)
APP=${APP:-274190} WIN_NAME=${WIN_NAME:-Broforce}  # any Steam game (one-word window name); default the test case
case "$APP$WIN_NAME" in *[!A-Za-z0-9_.-]*) echo "APP / WIN_NAME: one word each"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/bf-fold-$(date +%F_%H%M)}; mkdir -p "$OUT"
PKG=${KWIN_PKG:-} MIN=${KWIN_MIN:-6.7.5-3.21}
WANT=$([ -n "$PKG" ] && basename "$PKG" | sed -E 's/^kwin-([^-]+-[^-]+)-.*/\1/')
WL_TRAP='"$A" shell cmd device_state state reset >/dev/null 2>&1'
. "$here/window-lock.sh"; window_lock bf-fold.sh 120
trap '"$A" shell cmd device_state state reset >/dev/null 2>&1; [ "${WL_LOCK:-}" ] && rm -rf "$WL_LOCK"' EXIT
log() { echo "$(date +%T) $*" | tee -a "$OUT/run.txt"; }
BF_ADB=$A . "$here/bf-lib.sh"   # pill <step>: the status pill's sub-step
pill "checking KWin's version"
"$A" push "$here/bf-fold-phone.sh" /data/local/tmp/powos-bf-fold-phone.sh >/dev/null
"$A" push "$here/bf-stop.sh" /data/local/tmp/powos-bf-stop.sh >/dev/null
"$A" push "$here/bf-lib.sh" /data/local/tmp/powos-bf-lib.sh >/dev/null
# bf-lib.sh's xframes body is bf-xframes.py (split out for test-complexity.sh's length budget), also pushed here.
"$A" push "$here/bf-xframes.py" /data/local/tmp/powos-bf-xframes.py >/dev/null
"$A" shell "su -c 'cp /data/local/tmp/powos-bf-fold-phone.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-xframes.py /data/powos/root/var/tmp/; chmod 644 /data/powos/root/var/tmp/powos-bf-*.sh /data/powos/root/var/tmp/powos-bf-xframes.py'"
kwin() {  # kwin=<pid> kwin_new=<1|0>: 0 = it still runs a libkwin the package replaced (needs a fresh session)
  printf '%s\n' 'k=$(pgrep -x kwin_wayland | head -1); n=0; [ -n "$k" ] && ! grep -q "libkwin.*(deleted)" /proc/$k/maps && n=1; echo "kwin=${k:--} kwin_new=$n"' > "$OUT/kw.sh"
  "$P/root.sh" "$OUT/kw.sh" 2>/dev/null | tail -1 | tr -d '\r'; }
ph() { "$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP WIN_NAME=$WIN_NAME bash /var/tmp/powos-bf-fold-phone.sh $*\"'" | tr -d '\r'; }
irq() { "$A" shell "cat /proc/interrupts" | awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}'; }
I0=$(irq); touched() { [ "$(irq)" != "$I0" ] && { log "user input - stopping"; return 0; }; return 1; }

# 1. The KWin with the fix, installed and running.
vc() { printf 'vercmp %s %s\n' "$1" "$2" > "$OUT/vc.sh"; "$P/root.sh" "$OUT/vc.sh" 2>/dev/null | tail -1 | tr -d '\r'; }
have=$(printf 'pacman -Q kwin | cut -d" " -f2\n' > "$OUT/q.sh"; "$P/root.sh" "$OUT/q.sh" 2>/dev/null | tail -1 | tr -d '\r')
log "kwin installed $have, needs >= $MIN${PKG:+, package $WANT ($PKG)}"
if [ -n "$PKG" ] && [ "$(vc "$WANT" "$have")" -gt 0 ] 2>/dev/null; then
  [ -f "$PKG" ] || { log "no package $PKG"; exit 1; }
  pill "installing KWin $WANT"
  "$A" push "$PKG" /data/local/tmp/powos-kwin.pkg.tar.xz >/dev/null
  # The package goes in through Android's side (root.sh runs inside PowOS: /data/local/tmp isn't there).
  "$A" shell "su -c 'mv /data/local/tmp/powos-kwin.pkg.tar.xz /data/powos/root/var/tmp/'"
  cat > "$OUT/install.sh" <<EOF
set -e; mkdir -p /var/cache/powos
# Rollback copy of the running KWin's files (no package of it is cached): tar -xf it over / to go back.
pacman -Qlq kwin | while read -r f; do [ -f "\$f" ] && echo "\$f"; done | tar -cf /var/cache/powos/kwin-$have-files.tar -T -
pacman -U --noconfirm /var/tmp/powos-kwin.pkg.tar.xz >/dev/null && rm -f /var/tmp/powos-kwin.pkg.tar.xz
pacman -Q kwin
EOF
  "$P/root.sh" "$OUT/install.sh" 2>&1 | tail -2 | tee -a "$OUT/run.txt"
  have=$WANT
elif [ -n "$PKG" ]; then log "installed $have is not older than $WANT: nothing installed"; fi
[ "$(vc "$have" "$MIN")" -ge 0 ] 2>/dev/null || { log "FAIL: KWin $have is older than $MIN (the fold fix, pkgs/kwin 0017)"; exit 1; }
st="$(kwin) $(ph state)"; log "state: $st"
if [[ $st != *kwin_new=1* ]]; then
  [[ $st == *reaper=-* ]] || { log "$WIN_NAME runs on the old KWin (the user's?): not restarting the session now"; exit 3; }
  touched && exit 3
  pill "fresh session for the new KWin"
  ph logout | tee -a "$OUT/run.txt"; sleep 20
  for _ in $(seq 40); do st="$(kwin) $(ph state 2>/dev/null)"; [[ $st == *kwin_new=1* && $st != *root=x* ]] && break; sleep 5; done
  log "after the fresh session: $st"
  if [[ $st != *kwin_new=1* ]]; then
    log "KWin didn't come back: rolling back to $have"
    printf 'tar -xf /var/cache/powos/kwin-%s-files.tar -C /\n' "$have" > "$OUT/rollback.sh"; "$P/root.sh" "$OUT/rollback.sh"
    ph logout; exit 1
  fi
  sleep 15
fi

# 2. Broforce up.
touched && exit 3
pill "$WIN_NAME up (Steam, the window, 2 min sleep grace)"
r=$(ph start); echo "$r" >> "$OUT/run.txt"; mine=$([[ $r == *mine=1* ]] && echo 1 || echo 0)
stop() {  # what it started: closed; a Broforce the user had left (frozen in the background): frozen again
  if [ "$mine" = 1 ]; then pill "closing the game"
    log "closed the Broforce it started: $("$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP bash /var/tmp/powos-bf-stop.sh\"'" 2>&1 | tr -d '\r' | tail -1)"
  elif [[ ${r:-} == *mine=0* ]]; then pill "freezing the user's $WIN_NAME again"; log "the user's $WIN_NAME: $(ph refreeze | tail -1)"; fi; }
[[ $r == *"user input"* ]] && { log "user input during the start"; exit 3; }  # bf-lib closed what it started
[[ $r == *FAIL* || $r != *mine=* ]] && { log "FAIL: $WIN_NAME didn't come up: $(echo "$r" | grep -m1 FAIL)"; stop; exit 1; }

# SurfaceFlinger presents over 2 s, summed over the window tasks' SurfaceViews (the game's task is the busy one).
sf() { "$A" shell 'L=$(dumpsys SurfaceFlinger --list | sed -E "s/^RequestedLayerState\{//; s/ parentId=.*//" | grep -E "SurfaceView\[com.powos.app/andro.marchy.PowosWindowActivity\]" | grep -vE "Background|Bounds|ActivityRecord" | head -4)
  echo "$L" | while read -r l; do [ -n "$l" ] || continue; a=$(dumpsys SurfaceFlinger --latency "$l" | awk "NR>1 && \$3>0 && \$3<9e18 {m=\$3} END{print m+0}")
    echo "$l|$a"; done > /data/local/tmp/powos-sf0; sleep 2; n=0
  while IFS="|" read -r l a; do c=$(dumpsys SurfaceFlinger --latency "$l" | awk -v a="$a" "NR>1 && \$3>a && \$3<9e18 {c++} END{print c+0}"); [ "$c" -gt "$n" ] && n=$c; done < /data/local/tmp/powos-sf0
  rm -f /data/local/tmp/powos-sf0; echo "$n"' | tr -d '\r'; }
bars() {  # bars <png>: black rows/columns at each edge of a screencap (top bottom left right) and the centre's brightness
  local r c
  r=$(ffmpeg -nostdin -loglevel error -i "$1" -vf "format=gray,scale=1:ih:flags=area" -f rawvideo - 2>/dev/null | od -An -v -tu1 | tr -s ' \n' ' ')
  c=$(ffmpeg -nostdin -loglevel error -i "$1" -vf "format=gray,scale=iw:1:flags=area" -f rawvideo - 2>/dev/null | od -An -v -tu1 | tr -s ' \n' ' ')
  awk -v r="$r" -v c="$c" 'function edge(s, rev,   a, n, i, k) { n = split(s, a, " "); for (k = 0; k < n; k++) {
      i = rev ? n - k : k + 1; if (a[i] > 12) return k }; return n }
    BEGIN { n = split(r, a, " "); printf "top=%d bottom=%d left=%d right=%d mid=%d\n", edge(r, 0), edge(r, 1), edge(c, 0), edge(c, 1), a[int(n / 2)] }'; }
fails=0; first=
probe() {  # probe <label> [cover|inner]
  local st c f s
  pill "$1: checking the game (window, frames, screen)"
  st="$(kwin) $(ph state)"; c=$(ph changes 3); f=$(sf)
  "$P/shot.sh" "$OUT/$1.png" >/dev/null 2>&1 && s=$(bars "$OUT/$1.png") || s="no screencap"
  log "$1: $st $c sf_presents_2s=$f screen: $s"
  [ -z "$first" ] && first=$st
  local bad=
  [[ $st == *frozen=no* ]] || bad+=" frozen"
  [[ $st == *reaper=-* ]] && bad+=" game-gone"
  [ "${st%% *}" = "${first%% *}" ] || bad+=" kwin-restarted"
  [ "$(echo "$st" | grep -o 'reaper=[^ ]*')" = "$(echo "$first" | grep -o 'reaper=[^ ]*')" ] || bad+=" game-restarted"
  [ "$(echo "$st" | grep -o 'win=[^ ]* geom=[0-9x]*')" = "$(echo "$first" | grep -o 'win=[^ ]* geom=[0-9x]*')" ] || bad+=" window-changed"
  [ "${c#changes=}" -ge 3 ] 2>/dev/null || bad+=" not-drawing"
  [ "${f:-0}" -ge 20 ] 2>/dev/null || bad+=" not-on-screen"
  local t=${s#*top=}; t=${t%% *}; local b=${s#*bottom=}; b=${b%% *}; local l=${s#*left=}; l=${l%% *}
  if [ "${2:-}" = cover ]; then  # 2268x2440 fitted into 1116x2484: ~640 px bars above and below
    [ "${t:-0}" -ge 300 ] 2>/dev/null && [ "${b:-0}" -ge 300 ] 2>/dev/null || bad+=" not-letterboxed"
  else  # its own size on the inner screen: no bars expected (scale 1) - a note only, dark game art reads as bars too
    [ "${t:-999}" -lt 80 ] 2>/dev/null && [ "${b:-999}" -lt 80 ] 2>/dev/null && [ "${l:-999}" -lt 80 ] 2>/dev/null \
      || log "  $1 note: dark edges unfolded (bars? the task's buffer smaller than the game): $s"
  fi
  [ -n "$bad" ] && { fails=$((fails + 1)); log "  $1 bad:$bad"; }
  return 0
}
now=$("$A" shell cmd device_state print-state | tr -d '\r'); log "device state $now"
[ "$now" = 3 ] || { "$A" shell cmd device_state state 3; sleep 6; }
touched && { [ "$mine" = 1 ] && stop; exit 3; }  # the user is back: a Broforce of theirs is left as it is
probe unfolded inner
pill "folding (forced CLOSED)"; "$A" shell cmd device_state state 0; sleep 6; log "forced CLOSED (cover)"
probe folded cover
pill "folded: 20 s past the sleep timer"; sleep 20; probe folded-25s cover
pill "unfolding (forced OPENED)"; "$A" shell cmd device_state state 3; sleep 6; log "forced OPENED (inner)"
probe unfolded-again inner
"$A" shell cmd device_state state reset >/dev/null 2>&1
ph sleeplog >> "$OUT/run.txt"
stop
"$A" shell "su -c 'rm -f /data/local/tmp/powos-bf-fold-phone.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-xframes.py /data/powos/root/var/tmp/powos-bf-fold-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-xframes.py'"
r="RESULT bf-fold: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails bad steps)") - game kept $(echo "$first" | grep -o 'geom=[^ ]*') through fold/unfold; artefacts $OUT"
log "$r"
[ $fails = 0 ]
