#!/bin/bash
# test-window-bench-arm.sh - window-bench.sh's in-page tap timing (arm_js): the limit counts from the tap's pointerdown,
# not from the arming. 11-10 p1: under Mac load the hops between arming and the tap took > 2 s, so every storm close read
# "-", and close-host was timed on the Mac's clock (1.5-3 s for a host close that took 30 ms on the phone). Runs the
# generated JS in node against a fake page: a tap 2.5 s after arming, the condition true 40 ms after the tap.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$ROOT/tools/phone/verify/window-bench.sh"
command -v node >/dev/null || { echo "  skip test-window-bench-arm: no node"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# The functions, as the bench defines them.
{ echo "WW=\"Promise.resolve([])\""; sed -n '/^arm_js() {/,/^}/p; /^pagegone()/p; /^hostgone()/p' "$B"; } > "$T/f.sh"
grep -q '^arm_js()' "$T/f.sh" || { bad "arm_js not found in window-bench.sh"; exit 1; }
js=$(bash -c ". '$T/f.sh'; arm_js __wbHg \"\$(hostgone w7)\" 3000")

# A fake page: virtual clock, rAF every 16 ms, a pointerdown at $TAP ms after arming, the host's list loses id 7 at
# TAP+40 ms. Prints window.__wbHg at the end.
cat > "$T/run.js" <<'EOF'
let now = 0; const TAP = +process.argv[2], code = process.argv[3];
const ls = []; const raf = [];
global.performance = { now: () => now };
global.requestAnimationFrame = f => raf.push(f);
global.document = { addEventListener: (t, f) => ls.push(f), removeEventListener: () => {}, querySelector: () => null };
global.window = global;
global.importShim = async () => ({ powos: { webwindows: { list: async () => now >= TAP + 40 ? [] : [{ id: 7 }] } } });
eval(code);
(async () => {
  let tapped = false;
  while (now < 40000 && window.__wbHg == null) {
    now += 16;
    if (!tapped && now >= TAP) { tapped = true; ls.splice(0).forEach(f => f({ timeStamp: now })); }
    const q = raf.splice(0); q.forEach(f => f(now));
    for (let i = 0; i < 5; i++) await null;
  }
  console.log(String(window.__wbHg));
})();
EOF
v=$(node "$T/run.js" 2500 "$js")
case $v in [2-5][0-9]) ok "a tap 2.5 s after arming is timed from the tap: $v ms" ;; *) bad "a tap 2.5 s after arming: '$v' (want 40 ms, +-16)" ;; esac
v=$(node "$T/run.js" 100 "$js")
case $v in [2-5][0-9]) ok "a prompt tap: $v ms" ;; *) bad "a prompt tap: '$v'" ;; esac
# Control: the old rule (limit from the arming, 2 s) reads "-" for the late tap - the check can fail.
old=${js//n-t0>3000:n-t1>30000/n-t1>2000:n-t1>2000}
v=$(node "$T/run.js" 2500 "$old")
[ "$v" = - ] && ok "control: limit-from-arming reads '-' for the late tap" || bad "control: old rule gave '$v', not '-'"
exit $fail
