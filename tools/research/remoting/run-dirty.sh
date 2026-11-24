#!/usr/bin/env bash
# Experiment 2: dirty-memory rate per app and state (soft-dirty + pagemap, bin/dirty.py), apps as direct clients of
# the headless sway in the comp container on .58. One command:
#   tools/research/remoting/run-dirty.sh            # full matrix -> results/dirty.jsonl
#   tools/research/remoting/run-dirty.sh kate       # one app spec: firefox-wiki | firefox-news | kate | dolphin
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); dc="$here/dc"; res="$here/results"; mkdir -p "$res"
"$dc" build comp >/dev/null
"$dc" up -d comp >/dev/null 2>&1
NEWS=https://www.theguardian.com/international
run_app() {
  local spec=$1 app page="" kind=wiki settle=12
  case $spec in
    firefox-wiki) app=firefox; settle=25 ;;
    firefox-news) app=firefox; page=$NEWS; kind=news; settle=30 ;;
    *) app=$spec ;;
  esac
  echo "== dirty $spec" >&2
  "$dc" exec -T -u u comp comp-start local >&2
  "$dc" exec -T -u u -e PAGE="$page" comp app-start local "$app" >&2
  sleep "$settle"
  local root; root=$("$dc" exec -T comp pgrep -o -x "$app")
  local states="idle typing scroll"; [ "$kind" = news ] && states="idle scroll"
  for st in $states; do for iv in 0.1 1; do
    "$dc" exec -d -T -u u comp rm-act "$app" "$st" 11 "$kind"
    sleep 0.5
    "$dc" exec -T comp dirty.py "$root" "$iv" 10 | python3 -c "import json,sys; r=json.load(sys.stdin); r.update(app='$spec', state='$st'); print(json.dumps(r))" | tee -a "$res/dirty.jsonl"
    sleep 2
  done; done
  "$dc" exec -T -u u comp app-stop || true
}
if [ $# -ge 1 ]; then for a in "$@"; do run_app "$a"; done; exit; fi
for a in firefox-wiki firefox-news kate dolphin; do run_app "$a"; done
