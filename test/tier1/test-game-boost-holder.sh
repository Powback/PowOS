#!/bin/bash
# game-boost.sh's holder (the PowOS app's per-game CPU boost) on a fake cpufreq tree: lifts every big policy's max to
# its hw max and its min to the boost step, re-asserts a max someone set back, restores the originals when the lease
# goes stale - and does that with shell builtins: 11-06 live capture (Broforce, real play) had the holder at 6-13 % of
# a core, mostly a cat/grep fork per thread per 5 s and ~14 forks per second for the cpufreq limits.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); GB=$ROOT/targets/android/app/app/src/main/assets/game-boost.sh
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P=$T/cpufreq
pol() {  # pol <name> <cpus> <hw max> <min now> <max now> <steps...>
  local d=$P/$1; mkdir -p "$d"; echo "$2" > $d/related_cpus; echo "$3" > $d/cpuinfo_max_freq; echo 300000 > $d/cpuinfo_min_freq
  echo "$4" > $d/scaling_min_freq; echo "$5" > $d/scaling_max_freq; shift 5; echo "$*" > $d/scaling_available_frequencies; }
pol policy0 "0 1 2" 2016000 300000 1459200 300000 1459200 2016000
pol policy3 "3 4 5 6" 2803200 614400 1920000 614400 1920000 2246400 2803200
pol policy7 "7" 3187200 864000 1708800 864000 1708800 2476800 3187200
mkdir -p $T/cpuctl $T/state; touch $T/lease
export GAME_BOOST_STATE=$T/state GAME_BOOST_CPUCTL=$T/cpuctl GAME_BOOST_CPUFREQ=$P GAME_BOOST_SETTINGS=true LEASE_S=2
# No such game: the holder lifts and holds until the lease (not touched) goes stale, then restores.
sh "$GB" hold steam_app_999999999 $T/lease &
h=$!; sleep 1.5
ok "policy3 max lifted" "$(cat $P/policy3/scaling_max_freq)" 2803200
ok "policy3 min = highest step <= 80 %" "$(cat $P/policy3/scaling_min_freq)" 1920000
ok "policy7 max lifted" "$(cat $P/policy7/scaling_max_freq)" 3187200
ok "policy7 min" "$(cat $P/policy7/scaling_min_freq)" 2476800
ok "little cluster untouched" "$(cat $P/policy0/scaling_max_freq)" 1459200
echo 1708800 > $P/policy7/scaling_max_freq   # someone sets it back: re-asserted on the next tick
sleep 1.2
ok "policy7 max re-asserted" "$(cat $P/policy7/scaling_max_freq)" 3187200
wait $h
ok "policy3 restored" "$(cat $P/policy3/scaling_min_freq) $(cat $P/policy3/scaling_max_freq)" "614400 1920000"
ok "policy7 restored" "$(cat $P/policy7/scaling_min_freq) $(cat $P/policy7/scaling_max_freq)" "864000 1708800"
ok "fight logged" "$(grep -c 'policy7: max set back to 1708800 by someone else' $T/state/log)" 1
ok "stale lease logged" "$(grep -c 'restore - the app.s lease is' $T/state/log)" 1
# Under a thermal controller (horae on OxygenOS): its cap stands and only the prime policy's min goes up to it - the
# gold cluster clocks on demand (less heat, which is what moves the controller's gear).
cp $T/state/log $T/log.before; rm -f $T/state/log; touch $T/lease
echo 1920000 > $P/policy3/scaling_max_freq; echo 1708800 > $P/policy7/scaling_max_freq
GAME_BOOST_OWNER=horaeCb sh "$GB" hold steam_app_999999999 $T/lease &
h=$!; sleep 1.5
ok "thermal: prime min up to its cap" "$(cat $P/policy7/scaling_min_freq) $(cat $P/policy7/scaling_max_freq)" "1708800 1708800"
ok "thermal: gold min left on demand" "$(cat $P/policy3/scaling_min_freq) $(cat $P/policy3/scaling_max_freq)" "614400 1920000"
ok "thermal: logged prime-only" "$(grep -c 'min held on policy7 only' $T/state/log)" 1
wait $h
ok "thermal: prime min restored" "$(cat $P/policy7/scaling_min_freq)" 864000
# Placement: a busy game thread is pinned to the prime core, and pinned again when its mask is reset under it (the
# kernel does that on a cpuset change; 11-06 live play had the main thread on cpu4 with Cpus_allowed 0-7). Needs a
# second cpu to tell the prime from the rest.
N=$(nproc)
if [ "$N" -ge 2 ] && command -v taskset > /dev/null; then
  Q=$T/cpufreq2; P0=$P; P=$Q
  pol policy0 "0" 2016000 300000 2016000 300000 2016000
  pol policy1 "0" 2803200 300000 2803200 300000 2803200
  pol policy2 "$((N - 1))" 3187200 300000 3187200 300000 3187200
  P=$P0; rm -f $T/state/log
  SteamAppId=999999998 sh -c 'while :; do :; done' & g=$!
  ( while kill -0 $g 2>/dev/null; do touch $T/lease; sleep 0.5; done ) & tl=$!
  GAME_BOOST_CPUFREQ=$Q sh "$GB" hold steam_app_999999998 $T/lease &
  h=$!; sleep 7
  ok "placement: busy thread on the prime core" "$(awk '/Cpus_allowed_list/ {print $2}' /proc/$g/status)" "$((N - 1))"
  taskset -p -c 0-$((N - 1)) $g > /dev/null
  sleep 5.5
  ok "placement: re-pinned after a reset" "$(awk '/Cpus_allowed_list/ {print $2}' /proc/$g/status)" "$((N - 1))"
  ok "placement: reset logged" "$(grep -c 'its mask was reset' $T/state/log)" 1
  ok "placement: holder off the prime core" "$(awk '/Cpus_allowed_list/ {print $2}' /proc/$h/status)" 0
  kill $g; wait $g 2>/dev/null; wait $h; kill $tl 2>/dev/null
  ok "placement: restored after the game" "$(grep -c 'placement resets: 1)' $T/state/log)" 1
  ok "placement: mask restored" "$(grep -c 'threads restored: ' $T/state/log)" 1
else
  echo "skip placement (nproc $N)"
fi
# The per-second path forks nothing for the limits: no $(cat ...) left in freqs_lift / ticks.
body=$(sed -n '/^freqs_lift()/,/^}/p; /^ticks()/,/^}/p' "$GB")
ok "no cat forks in the per-second path" "$(echo "$body" | grep -c '\$(cat ')" 0
echo "Results: $pass passed, $fail failed"
[ $fail = 0 ]
