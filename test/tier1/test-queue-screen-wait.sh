#!/bin/bash
# test-queue-screen-wait.sh: a job on the wrong screen WAITS, it never burns a try. 11-11 06:55: ww-resize ended
# "SKIP folded (needs the inner screen)" + rc 3 three times while the phone sat folded, and the runner turned job
# 20261111-034846-37174 into "FAIL precondition, no more retries". Drives queue.sh's own screen_now / screen_wrong /
# screen_held / job_wscreen / job_held / select_jobs with a fake `wm size`, and checks the runner's rc 3 branch wiring.
# Both paths: a --screen inner job is not selected while the phone is folded (one "waits for" line), selected once
# unfolded; a check whose rc 3 says the screen is wrong gets wscreen= (held from then on), no ptries/tries.
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)/tools/phone/verify/queue.sh
fns=$(sed -n '/^rc3_waits() {/p; /^screen_now() {/,/echo "\$s"; }$/p; /^screen_wrong() {/,/  esac; }$/p; /^screen_held() {/,/no try counted"; }$/p; /^job_wscreen() {/,/mv -f "\$tmp" "\$1"; }$/p' "$src")
sel=$(sed -n '/^  job_held() {/,/^    return 1; }$/p; /^  select_jobs() {/,/^    done; }$/p' "$src")
for f in screen_now screen_wrong screen_held job_wscreen; do grep -q "^$f() {" <<<"$fns" || { echo "FAIL couldn't find $f in queue.sh"; exit 1; }; done
[ -n "$sel" ] || { echo "FAIL couldn't find job_held/select_jobs in queue.sh"; exit 1; }
eval "$fns"; eval "$sel"
shipped() { return 0; }; closes_game() { return 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/screen-wait.XXXXXX"); trap 'rm -rf "$T"' EXIT
Q=$T/q; mkdir -p "$Q/done"; phone=$T/phone; mkdir -p "$phone"
fails=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1${2:+ - $2}"; fails=$((fails + 1)); }
# The fake phone: `adb.sh shell wm size` answers the panel in $T/size; a call counter shows the cache.
cat > "$phone/adb.sh" <<EOF
#!/bin/bash
echo x >> "$T/calls"; echo "Physical size: \$(cat "$T/size")"
EOF
chmod +x "$phone/adb.sh"
fold() { echo 1116x2484 > "$T/size"; rm -f "$Q/screen.now"; }; unfold() { echo 2268x2440 > "$T/size"; rm -f "$Q/screen.now"; }

# screen_now: the Open's panels, either orientation; unknown geometry = empty (never a hold on a guess).
fold; [ "$(screen_now)" = cover ] && ok "1116x2484 = the cover screen (folded)" || bad "folded reads cover" "$(screen_now)"
unfold; [ "$(screen_now)" = inner ] && ok "2268x2440 = the inner screen (unfolded)" || bad "unfolded reads inner"
echo 2440x2268 > "$T/size"; rm -f "$Q/screen.now"; [ "$(screen_now)" = inner ] && ok "rotated inner reads inner" || bad "rotated inner"
echo 1080x2400 > "$T/size"; rm -f "$Q/screen.now"; [ -z "$(screen_now)" ] && ok "unknown geometry reads empty" || bad "unknown geometry" "$(screen_now)"
fold; : > "$T/calls"; screen_now >/dev/null; screen_now >/dev/null; [ "$(wc -l < "$T/calls" | tr -d ' ')" = 1 ] && ok "cached: one wm size for two asks" || bad "cache" "$(wc -l < "$T/calls")"

# Path 1: --screen inner, phone folded -> held with one line; unfolded -> selected.
mk() { printf 'task=%s\ntries=0\nafter=0\nneed=\nqt=0\ncwd=.\nrel=0\nscreen=%s\ncmd=(true)\n' "$2" "$3" > "$Q/$1.job"; }
mk 20261111-034846-37174-native-windows ww-resize inner
mk 20261111-040000-1-other other ''
fold; out=$(select_jobs "" ; echo "sel=${#sel[@]} held=$held ${sel[*]}")
grep -q 'native-windows: waits for the inner screen (phone folded) - stays queued, no try counted' <<<"$out" && ok "folded: the --screen inner job logs 'waits for the inner screen (phone folded)'" || bad "wait line" "$out"
[ "$(grep -c 'waits for' <<<"$out")" = 1 ] && ok "one line for the window" || bad "one line" "$out"
grep -q 'sel=1 held=1 .*040000-1-other.job' <<<"$out" && ok "folded: held, the job behind it still runs" || bad "folded selection" "$out"
unfold; select_jobs "" >/dev/null; [ ${#sel[@]} = 2 ] && ok "unfolded: the inner job is selected" || bad "unfolded selection" "${sel[*]}"
mk 20261111-034846-37174-native-windows ww-resize cover; select_jobs "" >/dev/null
[ ${#sel[@]} = 1 ] && ok "a --screen cover job waits while unfolded" || bad "cover job while unfolded" "${sel[*]}"
echo 1080x2400 > "$T/size"; rm -f "$Q/screen.now"; select_jobs "" >/dev/null
[ ${#sel[@]} = 2 ] && ok "screen unknown: runs (the check says so itself)" || bad "unknown screen runs" "${sel[*]}"

# Path 2: a check with no --screen ends rc 3 "SKIP folded (needs the inner screen)" -> a wait, not a precond try.
printf 'build: x\ntime: window lock after 0 s\nSKIP folded (needs the inner screen)\n' > "$T/a.log"
[ "$(screen_wrong "$T/a.log")" = inner ] && ok "screen_wrong: 'SKIP folded (needs the inner screen)' -> inner" || bad "screen_wrong folded"
printf 'SKIP: requested cover but actual display is inner (2268 x 2440); fold to the requested screen before rerunning\n' > "$T/b.log"
[ "$(screen_wrong "$T/b.log")" = cover ] && ok "screen_wrong: 'requested cover but actual display is inner' -> cover" || bad "screen_wrong requested"
printf 'SKIP folded (needs the inner screen)\nINVALID game wasnt on the screen\n' > "$T/c.log"
screen_wrong "$T/c.log" >/dev/null && bad "only the LAST reason line counts" || ok "only the LAST reason line counts (a later INVALID is no screen wait)"
printf 'SKIP phone in use: touched\n' > "$T/d.log"; screen_wrong "$T/d.log" >/dev/null && bad "a touch is no screen wait" || ok "a touch is no screen wait"
j=$Q/20261111-034846-37174-native-windows.job; mk 20261111-034846-37174-native-windows ww-resize ''
job_wscreen "$j" inner; job_wscreen "$j" inner
[ "$(grep -c '^wscreen=inner$' "$j")" = 1 ] && ! grep -q '^ptries=' "$j" && grep -q '^tries=0$' "$j" && ok "job_wscreen: wscreen=inner once, no ptries, tries 0" || bad "job_wscreen" "$(cat "$j")"
fold; out=$(select_jobs ""; echo "sel=${#sel[@]}")
grep -q 'waits for the inner screen (phone folded)' <<<"$out" && grep -q 'sel=1' <<<"$out" && ok "after it said so, it waits for the inner screen (no --screen given)" || bad "wscreen hold" "$out"
unfold; select_jobs "" >/dev/null; [ ${#sel[@]} = 2 ] && ok "unfolded: it runs again" || bad "wscreen unfolded" "${sel[*]}"

# The runner's rc 3 branch: a screen kind never reaches rc3_precond or rc3_requeue, and a mid-window fold holds it.
grep -qF 'ws=$(screen_wrong "$log") && kind=screen' "$src" && ok "rc 3 classifies a wrong-screen exit as kind=screen" || bad "kind=screen wiring"
grep -qF 'if [ "$kind" = screen ]; then' "$src" && grep -qF 'job_wscreen "$j" "$ws"' "$src" && ok "kind=screen: job_wscreen, no rc3_requeue" || bad "screen branch wiring"
grep -qF 'screen_held "$(basename "$j" .job)" && continue' "$src" && ok "each job re-checks its screen before it runs" || bad "per-job screen check"
[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
