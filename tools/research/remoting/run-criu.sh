#!/usr/bin/env bash
# Experiment 3: CRIU pre-copy hand-off between two rootless containers on .58 (same ISA). One command:
#   tools/research/remoting/run-criu.sh                       # full matrix -> results/criu.jsonl
#   tools/research/remoting/run-criu.sh vim-big 3 8,4,1       # WORKLOAD ITER NET
# Freeze = final dump start (the app stops) -> restore done on criu-b, including the transfer.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); dc="$here/dc"; res="$here/results"; mkdir -p "$res"
"$dc" build comp >/dev/null
"$dc" --profile criu up -d criu-a criu-b >/dev/null 2>&1
run_one() {
  local wl=$1 n=$2 net=$3
  echo "== criu $wl iter=$n net=$net" >&2
  "$dc" exec -T criu-a net-set "$net" >/dev/null; "$dc" exec -T criu-b net-set "$net" >/dev/null
  "$dc" exec -T criu-b sh -c 'pkill -f '^tmux'; pkill -x vim; pkill -x criu-dst; sleep 0.5; true'
  "$dc" exec -d -T criu-b criu-dst
  sleep 1
  "$dc" exec -T criu-a criu-src "$wl" "$n"
  for i in $(seq 100); do "$dc" exec -T criu-b grep -q '^restore' /ck/dst.log 2>/dev/null && break; sleep 0.2; done
  local src dst alive
  src=$("$dc" exec -T criu-a cat /ck/src.log); dst=$("$dc" exec -T criu-b cat /ck/dst.log)
  alive=$("$dc" exec -T criu-b sh -c 'pgrep -x vim >/dev/null && tmux capture-pane -p -t w | grep -c xxxx || echo 0')
  python3 - "$wl" "$n" "$net" "$alive" "$src" "$dst" <<'PY' | tee -a "$res/criu.jsonl"
import json, re, sys
wl, n, net, alive, src, dst = sys.argv[1:]
r = {'workload': wl, 'iter': int(n), 'net': net, 'restored_lines_with_typing': int(alive.split()[-1] or 0)}
pre = [dict(zip(['dump_ms', 'send_ms', 'bytes'], map(int, re.findall(r'dump_ms (\d+) send_ms (\d+) bytes (\d+)', l)[0])))
       for l in src.splitlines() if l.startswith('pre ')]
fin = src.splitlines()[-1]
g = lambda k, s: int(re.search(k + r' (\d+)', s).group(1))
m = re.search(r'restore rc=(\d+) (\d+) (\d+)', dst)
r['rss_kb'] = g('rss_kb_vim', src)
r['pre'] = pre
r['final'] = {'rc': int(re.search(r'rc=(\d+)', fin).group(1)), 'dump_ms': g('dump_ms', fin), 'send_ms': g('send_ms', fin), 'bytes': g('bytes', fin)}
if m:
    r['restore_rc'] = int(m.group(1)); r['restore_ms'] = int(m.group(3)) - int(m.group(2))
    r['freeze_ms'] = int(m.group(3)) - g('freeze_start', fin); r['total_ms'] = int(m.group(3)) - g('t0', fin)
r['bytes_total'] = sum(p['bytes'] for p in pre) + r['final']['bytes']
print(json.dumps(r))
PY
  "$dc" exec -T criu-a net-set none >/dev/null; "$dc" exec -T criu-b net-set none >/dev/null
}
if [ $# -ge 3 ]; then run_one "$@"; exit; fi
for wl in vim-small vim-big; do for net in none 3,2,0 8,4,1; do for n in 0 3; do run_one $wl $n $net; done; done; done
