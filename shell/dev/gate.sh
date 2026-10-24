#!/bin/bash
# The pre-push gate: what shell/push.sh (and apps/install.sh, for a PowOS app's UI) runs before anything reaches the
# phone. A pushed shell file that doesn't load leaves its pages without JS (2026-10-20: an in-progress apps/pages.ts
# with an import cycle - home and the lock face dead, the shade's window over everything), and nobody is told: so it
# never gets there.
#
#   shell/dev/gate.sh [--tree | --dir DIR | --installed DIR] [--overrides DIR] [--app APPDIR] [file...]
#
# The shell it checks is the one the phone will run after the push: the committed shell (git HEAD: what an APK is
# built from - build-app.sh refuses a dirty tree), the phone's current overrides over it (--overrides: push.sh pulls
# them), and the files being pushed, from the working tree, over that. Other agents' uncommitted edits elsewhere in
# shell/ are not part of it, as they aren't part of the phone. --tree: the working tree as it is instead; --dir: DIR
# as it is (nothing composed).
#   1. tsc --noEmit over that shell (the folder's own tsconfig and node_modules); the style lint (dev/lint-style.sh:
#      a raw colour, a line or a shadow outside theme.css's tokens fails, dev/style-allow.txt the exceptions); the
#      complexity lint (dev/lint-complexity.sh: a function over cyclomatic/cognitive 10, depth 3, 60 lines or 4 params
#      fails unless it's old debt in dev/complexity-baseline.json, which only shrinks);
#   2. every page of it (home, lock, shade, assist, aod, recents: each mode app.tsx renders) booted in a headless
#      Chromium against the mock bridge, served as the phone's WebView serves it (shell/dev/gate.mjs): any uncaught
#      error, failed module load, missing export or import-cycle error, or no ready (window.__powosAlive) in READY_MS
#      (default 8000) fails it. Then the idle check: settled, a page draws nothing - no requestAnimationFrame, no layer
#      paint, no endless animation for IDLE_MS (default 2000; IDLE_MS=0 skips it).
#   --app APPDIR (apps/<app>): also every page/widget entry of that app's built UI (out/ui), imported as the shell does.
#   3. the widgets (dev/preview.sh --fast): every widget at every size it allows, minSize to 4x4, on both screens'
#      cells, checked for fit - clipped text, a row cut in half, a side >12% empty, content covering <25% of the tile,
#      a tile that scrolls, a hard border; a widget's screen across the screen, its backdrop hiding what's behind.
#      A problem not in dev/preview/baseline.json fails it, with the widget and the size. Runs when the push brings
#      what draws widgets (ui/owl.tsx, island.tsx, grid.tsx, the panels, theme.css, shell.css, apps/stdb.ts,
#      dev/preview/), for --app (that app's widgets), with --widgets, or GATE_WIDGETS=1; GATE_WIDGETS=0 skips it.
#      ~1-2 min.
#   --shots DIR [--wallpaper FILE]: after the pages boot, every surface rendered at the phone's two screens into DIR
#      (dev/shots.mjs: PNGs + report.json with each text's measured contrast) - design QA's renders, never a pass/fail.
#      SHOTS_THEME / SHOTS_ONLY / SHOTS_SCALE / SHOTS_PROBE / SHOTS_STRICT pass through (STRICT=1: overlapping tiles
#      or missing glyphs fail it).
# Exit 0: pass. 1: failed (the reasons on stdout). 2: couldn't run (no docker...). Time: ~5-10 s, the image cached.
# GATE_ONLY=<regex>: only the browser runs so named (a case worked on alone); GATE_THROTTLE=N: every page's CPU slowed
# N times (a loaded Mac on demand: a case's waits must hold at 6). GATE_IMAGE overrides the Chromium image. Docker's
# build cache and images are never pruned here.
set -euo pipefail
SHELL_DIR=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${GATE_IMAGE:-zenika/alpine-chrome:with-puppeteer}
base=head dir="" installed="" overrides="" app="" shots="" wallpaper="" widgets=${GATE_WIDGETS:-} files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) base=tree; shift ;;
    --dir) base=dir; dir=$(cd "$2" && pwd); shift 2 ;;
    # The shell the installed APK ships (its assets/shell, push.sh pulls it): the base instead of git HEAD - the phone
    # runs that, not HEAD, while the APK lags behind (2026-10-21: HEAD's assist.tsx failed against the phone's
    # overrides though the phone ran the APK's). Composed like HEAD: the overrides and the files over it.
    --installed) base=installed; installed=$(cd "$2" && pwd); shift 2 ;;
    --overrides) overrides=$2; shift 2 ;;
    --app) app=$(cd "$2" && pwd); shift 2 ;;
    --shots) mkdir -p "$2"; shots=$(cd "$2" && pwd); shift 2 ;;
    --wallpaper) wallpaper=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2 ;;
    --widgets) widgets=1; shift ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) files+=("$1"); shift ;;
  esac
done
if [ -z "${GATE_STUB_SLEEP:-}" ]; then
  . "$SHELL_DIR/../tools/lib/need-docker.sh"
  need_docker || { echo "gate: no docker" >&2; exit 2; }
fi
t0=$(date +%s)
# The Mac's 1-min load, measured once up front: a fixed READY_MS can't tell a slow page from a starved one,
# and under real agent-swarm load (f30: load 25) a page that would boot fine at load 2 missed a fixed 8000 ms
# and failed the gate though nothing was wrong with the code - even after GATE_SLOTS/build-slot stop OUR OWN
# builds from piling on each other, OTHER agents' unrelated work still raises ambient load. So the ready
# budget scales with the load actually measured at this run, instead of a constant every run guesses at.
load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}'); [ -n "$load" ] || load=$(awk '{print int($1)}' /proc/loadavg 2>/dev/null)
load=${load:-0}
# Under $HOME, not $TMPDIR: Colima's VM mounts the home folder only (a /var/folders path is empty in the container).
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate"
# The slots (2026-10-23: ~8 agents gated at once, Mac load 17 - pages timed out and retried with longer READY_MS, and
# the ship service's pre-gate of the user's APK install waited 10+ min). At most GATE_SLOTS (2) agent gates at once,
# the rest wait; the ship's gate (GATE_PRIORITY=ship: ship.sh, ship-apk.sh, push.sh --pre-gate) never waits - a slot
# of its own - and while it runs no new agent gate starts. A slot is a mkdir lock under slots/ with its pid; a dead
# pid's is reclaimed. Agent gates run niced, their containers at --cpu-shares 256 (the ship's at the default 1024).
slots="${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/slots" slot=""
mkdir -p "$slots"
slot_live() {   # $1 a slot dir: held by a running gate (a fresh dir whose pid isn't written yet counts as held)
  local p; p=$(cat "$1/pid" 2>/dev/null) || p=""
  if [ -z "$p" ]; then [ -n "$(find "$1" -maxdepth 0 -mmin -1 2>/dev/null)" ]; return; fi
  kill -0 "$p" 2>/dev/null
}
slot_take() { mkdir "$1" 2>/dev/null || return 1; echo $$ > "$1/pid"; slot=$1; }
reap() { local d; for d in "$slots"/*; do [ -d "$d" ] && ! slot_live "$d" && rm -rf "$d"; done; return 0; }
running() { local d n=0; for d in "$slots"/*; do [ -d "$d" ] && slot_live "$d" && n=$((n + 1)); done; echo $n; }
trap 'rm -rf ${slot:+"$slot"}' EXIT
trap 'exit 130' INT TERM
if [ "${GATE_PRIORITY:-}" = ship ]; then
  rm -rf "$slots/ship.$$"; slot_take "$slots/ship.$$"
  cpu=""
else
  said=""
  while :; do
    reap
    if ! ls -d "$slots"/ship.* >/dev/null 2>&1; then
      for i in $(seq 0 $((${GATE_SLOTS:-2} - 1))); do slot_take "$slots/agent.$i" && break; done
      [ -n "$slot" ] && break
    fi
    [ -n "$said" ] || { echo "gate: waiting for a slot ($(running) running)"; said=1; }
    sleep "${GATE_SLOT_POLL_S:-2}"
  done
  [ -z "$said" ] || echo "gate: got a slot after $(($(date +%s) - t0)) s"
  renice -n 10 -p $$ >/dev/null 2>&1 || true
  cpu="--cpu-shares 256"
  export GATE_CPU_SHARES=256   # dev/preview.sh's container
fi
# GATE_STUB_SLEEP=N: the slots' test (shell/dev/gate-slots-test.sh) - holds the slot N s instead of gating.
if [ -n "${GATE_STUB_SLEEP:-}" ]; then
  echo "gate: stub ${GATE_PRIORITY:-agent} $(basename "$slot") start"; sleep "$GATE_STUB_SLEEP"
  echo "gate: stub ${GATE_PRIORITY:-agent} $(basename "$slot") end"; exit 0
fi
work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/run.XXXXXX")
trap 'rm -rf "$work" ${slot:+"$slot"}' EXIT
S=$work/shell
case $base in
  dir) S=$dir ;;
  tree) mkdir -p "$S" && (cd "$SHELL_DIR" && tar --exclude ./node_modules -cf - .) | tar -xf - -C "$S" ;;
  installed)
    mkdir -p "$S" && (cd "$installed" && tar -cf - .) | tar -xf - -C "$S"
    # The APK doesn't ship the type-checker's config: the committed one.
    [ -f "$S/tsconfig.json" ] || cp "$SHELL_DIR/tsconfig.json" "$S/tsconfig.json"
    ;;
  head)
    top=$(git -C "$SHELL_DIR" rev-parse --show-toplevel)
    rel=${SHELL_DIR#"$top"/}
    git -C "$top" archive HEAD "$rel" | tar -xf - -C "$work"
    [ "$rel" = shell ] || mv "$work/$rel" "$S"
    ;;
esac
if [ "$base" != dir ]; then
  # The phone's overrides, then the pushed files: what the phone serves after the push (ShellHost.open).
  [ -n "$overrides" ] && [ -d "$overrides" ] && (cd "$overrides" && tar -cf - .) | tar -xf - -C "$S"
  for f in ${files[@]+"${files[@]}"}; do
    [ -f "$SHELL_DIR/$f" ] || { echo "gate: no such shell file: $f" >&2; exit 2; }
    mkdir -p "$S/$(dirname "$f")" && cp "$SHELL_DIR/$f" "$S/$f"
  done
  ln -sfn "$SHELL_DIR/node_modules" "$S/node_modules"
fi
fail=0
# 1. Types.
if [ "${GATE_SHELL_PAGES:-1}" = 0 ]; then
  : # an app's UI alone (apps/install.sh): the shell isn't what changed
elif [ -x "$SHELL_DIR/node_modules/.bin/tsc" ]; then
  if out=$(cd "$S" && "$SHELL_DIR/node_modules/.bin/tsc" --noEmit -p . 2>&1); then echo "ok   tsc"
  else echo "$out" | grep -v '^ ' | head -40 | sed 's/^/FAIL tsc: /'; fail=1; fi
else
  echo "     tsc: skipped (no shell/node_modules - npm ci in shell/)"
fi
# 1b. The design language's style lint (docs/DESIGN-LANGUAGE.md): no raw colours, lines or shadows outside the tokens.
# A push: the files it brings (what's already on the phone isn't this push's to answer for); otherwise all of the shell.
if out=$("$SHELL_DIR/dev/lint-style.sh" "$S" ${files[@]+"${files[@]}"} 2>&1); then echo "$out"; else echo "$out" | head -30; fail=1; fi
# 1b'. The complexity lint (dev/lint-complexity.sh: per function cyclomatic/cognitive 10, depth 3, 60 lines, 4 params;
# old debt frozen in dev/complexity-baseline.json, which only shrinks). A push: the files it brings; else all.
# Fail closed: it installs its own deps if missing; only GATE_LINT=0 skips it.
# --app: the PowOS apps' UIs too (apps/*/ui, their own baseline).
cx=0; out=$("$SHELL_DIR/dev/lint-complexity.sh" --dir "$S" ${app:+--apps} ${files[@]+"${files[@]}"} 2>&1) || cx=$?
case $cx in 0|2) echo "$out" ;; *) echo "$out" | head -45; fail=1 ;; esac
# 1c. Every local file a page names (an html's href/src) or a script links in (a "./ui/x.css" it adds) is in what the
# phone will serve: the boot check below doesn't fail a stylesheet that 404s (2026-10-21: index.html's override named
# ui/rich.css before rich.css itself was on the phone - the assist page loaded without it). Push a page with what it
# names, in one push.
missing=$(cd "$S" && {
  for h in *.html; do
    grep -oE '(href|src)="[^"#?]+"' "$h" | sed -E 's/^(href|src)="//; s/"$//' |
      grep -vE '^([a-z]+:|/)' | while IFS= read -r r; do [ -e "${r#./}" ] || echo "$h names $r"; done
  done
  grep -ohE '"\./[A-Za-z0-9_/.-]+\.css"' ui/*.ts ui/*.tsx *.ts *.tsx 2>/dev/null | tr -d '"' | sort -u |
    while IFS= read -r r; do [ -e "${r#./}" ] || echo "a script links $r"; done
} 2>/dev/null)
if [ -z "$missing" ]; then echo "ok   referenced files"
else echo "$missing" | sed 's/^/FAIL missing: /; s/$/ (not in what the phone will serve: push it with this)/'; fail=1; fi
# 2. The pages, booted.
# Load-scaled ready budget (an explicit READY_MS still wins): 1500 ms/load-point, floor 8000 - calibrated off
# f30's own history (GATE_BOOTS alone passed at load 18.8 with the hand-set READY_MS=30000 workaround:
# 1500*18.8=28200, close enough), capped at 60000 so a truly wedged page still fails instead of hanging.
ready_default=$(( load * 1500 )); [ "$ready_default" -ge 8000 ] || ready_default=8000
[ "$ready_default" -le 60000 ] || ready_default=60000
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
# The shared transpile's cache (gate.mjs transpiled()): by source hash, so it never goes stale; pruned of week-old files.
tx="${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/tx"
mkdir -p "$tx" && find "$tx" -type f -mtime +7 -delete 2>/dev/null || true
mounts=(-v "$S:/shell:ro" -v "$SHELL_DIR/dev/gate.mjs:/usr/src/app/gate.mjs:ro" -v "$tx:/cache")
# node_modules is a link out of the composed folder: the browser half needs none of it.
if [ -n "$app" ]; then
  id=$(sed -n 's/^ *"id": *"\([^"]*\)".*/\1/p' "$app/powos-app.json" | head -1)
  [ -d "$app/out/ui" ] || { echo "FAIL app: $app/out/ui isn't built (apps/build.sh)"; exit 1; }
  mounts+=(-v "$app/powos-app.json:/apps/$id/powos-app.json:ro" -v "$app/out/ui:/apps/$id/ui:ro")
fi
set +e
# The Mac-wide build slot (tools/agents/build-slot.sh): booting the pages competes for CPU with
# compile-check/build-pkgs/warm-builder's docker runs, and a fixed READY_MS can't tell a slow page from a
# starved one - at load 25 pages missed READY_MS and the gate failed "not ready" though nothing was wrong
# with the code (f30, reopened x3 after GATE_BOOTS alone). Queueing for the slot instead of racing for CPU
# fixes the cause instead of raising the timeout.
"$SHELL_DIR/../tools/agents/build-slot.sh" "gate $base" -- \
docker run --rm --platform linux/arm64 --shm-size 512m $cpu "${mounts[@]}" -e READY_MS="${READY_MS:-$ready_default}" \
  ${GATE_SHELL_PAGES:+-e SHELL_PAGES="$GATE_SHELL_PAGES"} ${IDLE_MS:+-e IDLE_MS="$IDLE_MS"} ${IDLE_WAIT_MS:+-e IDLE_WAIT_MS="$IDLE_WAIT_MS"} ${GATE_SHARED_TX:+-e GATE_SHARED_TX="$GATE_SHARED_TX"} \
  ${GATE_ONLY:+-e GATE_ONLY="$GATE_ONLY"} ${GATE_THROTTLE:+-e GATE_THROTTLE="$GATE_THROTTLE"} \
  -w /usr/src/app --entrypoint node "$IMAGE" gate.mjs
rc=$?
set -e
[ $rc -eq 0 ] || fail=1
# 2b. The widgets' fit (dev/preview.sh): when this push brings what draws them, or asked.
if [ -z "$widgets" ]; then
  for f in ${files[@]+"${files[@]}"}; do
    case $f in ui/owl.tsx|ui/island.tsx|ui/grid.tsx|ui/agents.tsx|ui/recentwidget.tsx|theme.css|ui/shell.css|apps/stdb.ts|dev/preview/*) widgets=1 ;; esac
  done
  [ -n "$app" ] && widgets=1
fi
if [ "$widgets" = 1 ]; then
  wargs=(--dir "$S" --fast --out "$work/widgets")
  if [ -n "$app" ]; then
    wargs+=(--app "$app")
    # An app's UI alone (apps/install.sh): its widgets, not every widget there is.
    [ "${GATE_SHELL_PAGES:-1}" = 0 ] && wargs+=(--only "^$(sed -n 's/^ *"id": *"\([^"]*\)".*/\1/p' "$app/powos-app.json" | head -1 | sed 's/\./\\./g')\\.")
  fi
  set +e
  "$SHELL_DIR/dev/preview.sh" "${wargs[@]}" > "$work/widgets.log" 2>&1
  wrc=$?
  set -e
  grep -E "^(FAIL|known|       |preview:|     owl)" "$work/widgets.log" | sed 's/^FAIL /FAIL widget /' | head -80
  [ $wrc = 0 ] || fail=1
fi
# 3. Design QA's renders (not a check: they're looked at).
if [ -n "$shots" ]; then
  smounts=(-v "$S:/shell:ro" -v "$SHELL_DIR/dev/shots.mjs:/usr/src/app/shots.mjs:ro" -v "$shots:/out")
  [ -n "$wallpaper" ] && smounts+=(-v "$wallpaper:/wallpaper.jpg:ro")
  # The icon glyphs' font: shell/fonts/nerd_symbols.ttf is a link out of shell/ (the APK's res/font), which the
  # container can't follow - without it every icon glyph renders as tofu.
  nerd=$(cd "$SHELL_DIR/fonts" && cd "$(dirname "$(readlink nerd_symbols.ttf)")" 2>/dev/null && pwd -P)/nerd_symbols.ttf
  [ -f "$nerd" ] && smounts+=(-v "$nerd:/fonts/nerd_symbols.ttf:ro")
  docker run --rm --platform linux/arm64 --shm-size 512m $cpu "${smounts[@]}" ${SHOTS_THEME:+-e SHOTS_THEME="$SHOTS_THEME"} \
    ${SHOTS_ONLY:+-e SHOTS_ONLY="$SHOTS_ONLY"} ${SHOTS_SCALE:+-e SHOTS_SCALE="$SHOTS_SCALE"} ${SHOTS_PROBE:+-e SHOTS_PROBE="$SHOTS_PROBE"} ${SHOTS_STRICT:+-e SHOTS_STRICT="$SHOTS_STRICT"} -w /usr/src/app --entrypoint node "$IMAGE" shots.mjs ||
    { echo "     shots: the render run failed$([ "${SHOTS_STRICT:-}" = 1 ] && echo " (strict: overlapping tiles or missing glyphs, report.json)")"
      [ "${SHOTS_STRICT:-}" = 1 ] && fail=1; }
fi
[ $rc -le 1 ] || echo "FAIL gate: the browser run itself failed (exit $rc)"
echo "gate: $([ $fail = 0 ] && echo pass || echo FAIL) in $(($(date +%s) - t0)) s ($base$([ -n "$overrides" ] && echo " + phone overrides")$([ ${#files[@]} -gt 0 ] && echo " + ${#files[@]} pushed file(s)"))"
# A failure while the Mac is loaded (1-min load >= GATE_LOAD_FRICTION, 12) is friction: the gate may have failed for
# the load, not the code (2026-10-23: loads 17-25 timed pages out). Logged in the background, never failing the gate.
if [ $fail != 0 ]; then
  load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}'); [ -n "$load" ] || load=$(awk '{print int($1)}' /proc/loadavg 2>/dev/null)
  cli=$SHELL_DIR/../lib/ai/agents/powos-agents-cli
  if [ "${load:-0}" -ge "${GATE_LOAD_FRICTION:-12}" ] && [ -f "$cli" ] && [ -z "${GATE_NO_FRICTION:-}" ]; then
    ( perl -e 'alarm 60; exec @ARGV' python3 "$cli" friction add --area gate --kind flaky-check \
        "shell gate failed while the Mac's load was high" --repro "shell/dev/gate.sh ${files[*]:-} (load $load, ${GATE_PRIORITY:-agent} gate)" \
        --details "gate FAIL at 1-min load $load after $(($(date +%s) - t0)) s; base $base" --by gate >/dev/null 2>&1 & ) 2>/dev/null
  fi
fi
exit $fail
