#!/bin/bash
# test-cdp-home.sh - page checks reach home (11-10 window-bench triage: the queue woke the phone with the lock face over
# home, its hidden page never answered): tools/phone/cdp.sh resolves the devtools socket fresh per call for one
# explicit serial, cdp.ts picks the live target among several matches, tools/phone/home-front.sh brings home to the
# front without input, and preflight.sh's `needs: home` runs it. Fakes for adb, docker and the page: no phone.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/tools/phone"
T=$(mktemp -d)
trap 'rm -rf "$T"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null' EXIT
fail=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# ── cdp.sh: socket resolution ───────────────────────────────────────────────────────────────────────────────────
# Fake adb: `shell <lookup>` answers pid=$FAKE_PIDS and the sockets in $FAKE_SOCKS; forward is logged with the serial.
cat >"$T/adb" <<'EOF'
#!/bin/bash
echo "serial=$PHONE_SERIAL $*" >>"$FAKE_D/adb.log"
case "$1" in
  shell) [ -n "${FAKE_ADB_FAIL:-}" ] && { echo "adb: device offline" >&2; exit 1; }
    echo "pid=${FAKE_PIDS-}"; for s in ${FAKE_SOCKS-}; do printf '@webview_devtools_remote_%s\r\n' "$s"; done ;;
  forward) echo "$*" >>"$FAKE_D/forward" ;;
esac
exit 0
EOF
# Fake docker: the warm exec path, echoing what cdp.ts would run with.
cat >"$T/docker" <<'EOF'
#!/bin/bash
case "$1" in
  inspect) shift 3; for n in "$@"; do echo "/$n|vadb|true|id"; done ;;
  exec) for a in "$@"; do case "$a" in CDP_PORT=*) port=${a#*=} ;; esac; done
    while [ "$1" != sh ]; do shift; done; touch "$CDP_WARM_DIR/$5"; shift 6; echo "cdp.ts port=$port $*" ;;
esac
exit 0
EOF
chmod +x "$T/adb" "$T/docker"
cdp() { rm -rf "$T/d"; mkdir -p "$T/d"; env -u PHONE_SERIAL -u POWOS_PHONE_ADDR -u POWOS_DEVICE CDP_FWD_CACHE_S=0 CDP_WARM_OK_S=0 CDP_ADB="$T/adb" CDP_DOCKER="$T/docker" \
  FAKE_D="$T/d" CDP_WARM_DIR="$T/w" CDP_WARM_NAME=warm-test "$@" "$P/cdp.sh" eval home 1 2>"$T/d/err"; }

echo "cdp.sh: the devtools socket, fresh per call"
out=$(cdp FAKE_PIDS=4242 FAKE_SOCKS="999 4242") rc=$?
[ $rc = 0 ] && grep -q 'forward tcp:9333 localabstract:webview_devtools_remote_4242$' "$T/d/forward" && [ "$out" = "cdp.ts port=9333 eval home 1" ] \
  && ok "forwards the running pid's socket, not another app's" || bad "socket: rc=$rc out=$out fwd=$(cat "$T/d/forward" 2>/dev/null)"
out=$(cdp FAKE_PIDS="111 222" FAKE_SOCKS="222") rc=$?
[ $rc = 0 ] && grep -q 'webview_devtools_remote_222$' "$T/d/forward" && ok "two pids (a restart): the one with a socket" || bad "restart: rc=$rc $(cat "$T/d/forward" 2>/dev/null)"
out=$(cdp FAKE_PIDS=4242 FAKE_SOCKS="") rc=$?
[ $rc = 0 ] && grep -q 'webview_devtools_remote_4242$' "$T/d/forward" && ok "no socket list readable: pidof's pid as before" || bad "no list: rc=$rc"
out=$(cdp FAKE_PIDS=5000 FAKE_SOCKS="4242") rc=$?
[ $rc = 1 ] && [ ! -s "$T/d/forward" ] && grep -q 'no devtools socket' "$T/d/err" && ok "a pid without its socket: rc 1, no stale forward" || bad "stale: rc=$rc err=$(cat "$T/d/err")"
out=$(cdp FAKE_PIDS="" FAKE_SOCKS="") rc=$?
[ $rc = 1 ] && grep -q "isn't running" "$T/d/err" && ok "app not running: rc 1, said so" || bad "not running: rc=$rc err=$(cat "$T/d/err")"
out=$(cdp FAKE_ADB_FAIL=1) rc=$?
[ $rc = 2 ] && grep -q 'cdp: adb failed' "$T/d/err" && ok "adb failure: rc 2, never silent" || bad "adb fail: rc=$rc err=$(cat "$T/d/err")"
out=$(cdp FAKE_PIDS=7 FAKE_SOCKS=7) rc=$?
[ "$(grep -vc '^serial=10.13.13.7:5555 ' "$T/d/adb.log")" = 0 ] && ok "every adb call names the OnePlus's serial by default" || bad "serial: $(cat "$T/d/adb.log")"
out=$(cdp POWOS_PHONE_ADDR=192.168.50.203:33919 FAKE_PIDS=7 FAKE_SOCKS=7) rc=$?
[ "$(grep -vc '^serial=192.168.50.203:33919 ' "$T/d/adb.log")" = 0 ] && ! grep -q 'tcp:9333 ' "$T/d/forward" && [ "${out#cdp.ts port=9333}" = "$out" ] \
  && ok "another phone: its serial everywhere, its own port" || bad "razr: $(cat "$T/d/adb.log") out=$out"
printf '#!/bin/bash\nexec sleep 5\n' >"$T/hang"; chmod +x "$T/hang"
s=$SECONDS; out=$(cdp CDP_ADB_TIMEOUT_S=1 CDP_ADB="$T/hang") rc=$?
[ $rc = 2 ] && [ $((SECONDS - s)) -lt 4 ] && ok "a hung adb is cut at CDP_ADB_TIMEOUT_S" || bad "hang: rc=$rc $((SECONDS - s))s"

# Mac-paired TLS devices must never use the container's adb server or cached forward.
mkdir -p "$T/macbin" "$T/mac"
cat >"$T/macbin/adb" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_D/adb.log"
[ "$1" = -s ] && shift 2
case "$1" in
  shell) printf 'pid=77\n@webview_devtools_remote_77\n' ;;
  forward) echo "$*" >"$FAKE_D/forward" ;;
esac
EOF
cat >"$T/macbin/node" <<'EOF'
#!/bin/bash
printf 'local-node port=%s args=%s\n' "$CDP_PORT" "$*"
EOF
chmod +x "$T/macbin/adb" "$T/macbin/node"
out=$(env PATH="$T/macbin:$PATH" CDP_MAC_ADB="$T/macbin/adb" PHONE_SERIAL=razr-tls FAKE_D="$T/mac" \
  "$P/cdp.sh" eval home 1) rc=$?
[ "$rc" = 0 ] && grep -q '^-s razr-tls shell ' "$T/mac/adb.log" && \
  grep -q 'webview_devtools_remote_77$' "$T/mac/forward" && [[ "$out" == local-node*'eval home 1' ]] \
  && ok "Mac-paired device: explicit serial and local node, no container" || bad "Mac lane: rc=$rc out=$out"

# ── cdp.ts: the target ──────────────────────────────────────────────────────────────────────────────────────────
echo "cdp.ts: the live target among several"
if command -v node >/dev/null && node -e 'process.exit(Number(+process.versions.node.split(".")[0] < 22))'; then
  cat >"$T/srv.mjs" <<'EOF'
import http from "node:http";
const d = (o) => JSON.stringify(o);
const pages = [
  { type: "page", url: "https://shell.powos/index.html", title: "", webSocketDebuggerUrl: "ws://x/1", description: d({ attached: false, empty: true, visible: false }) },
  { type: "page", url: "https://shell.powos/index.html?mode=lock", title: "", webSocketDebuggerUrl: "ws://x/2", description: d({ attached: true, empty: false, visible: true }) },
  { type: "page", url: "https://shell.powos/index.html", title: "", webSocketDebuggerUrl: "ws://x/3", description: d({ attached: true, empty: false, visible: false, n: 3 }) },
  { type: "page", url: "https://shell.powos/index.html", title: "", webSocketDebuggerUrl: "ws://x/4", description: d({ attached: true, empty: false, visible: true, n: 4 }) },
];
const s = http.createServer((q, r) => r.end(JSON.stringify(pages))).listen(0, "127.0.0.1", () => console.log(s.address().port));
EOF
  node "$T/srv.mjs" >"$T/port" & SRV=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/port" ] && break; sleep 0.3; done
  out=$(CDP_PORT=$(cat "$T/port") node --no-warnings "$P/cdp.ts" target home 2>&1)
  case "$out" in "https://shell.powos/index.html "*'"n":4'*) ok "home: the attached, visible page over a detached or hidden one" ;; *) bad "target home: $out" ;; esac
  out=$(CDP_PORT=$(cat "$T/port") node --no-warnings "$P/cdp.ts" target lock 2>&1)
  case "$out" in "https://shell.powos/index.html?mode=lock "*) ok "lock: by its mode" ;; *) bad "target lock: $out" ;; esac
else echo "  skip node >= 22 missing"; fi

# ── home-front.sh ───────────────────────────────────────────────────────────────────────────────────────────────
echo "home-front.sh: home in front, no input"
# Fake adb: the top resumed activity in $T/h/top, wakefulness in $T/h/wake; `am start` of HOME makes home the top
# unless FAKE_STUCK; every command logged.
cat >"$T/hadb" <<'EOF'
#!/bin/bash
H=$FAKE_H; echo "$*" >>"$H/log"
case "$*" in
  *"am start"*) [ -n "${FAKE_STUCK:-}" ] || echo com.powos.app/andro.marchy.HomeShell >"$H/top"; exit 0 ;;
  *topResumedActivity*) echo "  mWakefulness=$(cat "$H/wake")"
    echo "  topResumedActivity=ActivityRecord{1281303 u0 $(cat "$H/top") t3210}" ;;
esac
exit 0
EOF
cat >"$T/hcdp" <<'EOF'
#!/bin/bash
echo "cdp $*" >>"$FAKE_H/log"
[ "$(cat "$FAKE_H/top")" = com.powos.app/andro.marchy.HomeShell ] && echo '"visible"' || echo '"hidden"'
EOF
chmod +x "$T/hadb" "$T/hcdp"
hf() { rm -rf "$T/h"; mkdir -p "$T/h"; echo "$1" >"$T/h/top"; echo "${2:-Awake}" >"$T/h/wake"; shift 2
  env FAKE_H="$T/h" HOME_ADB="$T/hadb" HOME_CDP="$T/hcdp" HOME_POLL_S=0.1 "${@:2}" "$P/home-front.sh" $1; }
ninput() { grep -cE 'input |keyevent|tap|swipe' "$T/h/log"; }
out=$(hf com.powos.app/andro.marchy.HomeShell Awake "") rc=$?
[ $rc = 0 ] && ! grep -q 'am start' "$T/h/log" && ok "already in front and visible: nothing changed" || bad "front: rc=$rc out=$out"
out=$(hf com.powos.app/dev.omalauncher.shell.PowosLockActivity Awake "") rc=$?
[ $rc = 0 ] && grep -q 'wm dismiss-keyguard; am start .*category.HOME -p com.powos.app' "$T/h/log" && [ "$(ninput)" = 0 ] \
  && ok "lock face on top: dismissed, home started, page visible, no input" || bad "lock: rc=$rc out=$out log=$(cat "$T/h/log")"
out=$(hf com.powos.app/andro.marchy.PowosWindowActivity Awake "") rc=$?
[ $rc = 0 ] && case "$out" in *PowosWindowActivity*) true ;; *) false ;; esac && ok "a leftover window task: home over it ($out)" || bad "window task: rc=$rc out=$out"
out=$(hf com.powos.app/dev.omalauncher.shell.PowosLockActivity Dozing "") rc=$?
[ $rc = 3 ] && ! grep -q 'am start' "$T/h/log" && ! grep -q '^cdp' "$T/h/log" && ok "screen off: not now (3), never woken" || bad "dozing: rc=$rc out=$out"
out=$(hf com.powos.app/dev.omalauncher.shell.PowosLockActivity Awake --check) rc=$?
[ $rc = 1 ] && ! grep -q 'am start' "$T/h/log" && ok "--check: says what is in front, changes nothing" || bad "check: rc=$rc out=$out"
out=$(hf org.kde.kate/.Main Awake "--wait 1" FAKE_STUCK=1) rc=$?
[ $rc = 3 ] && case "$out" in *"not in front after 1s"*) true ;; *) false ;; esac && ok "stays covered: not now (3) after --wait" || bad "stuck: rc=$rc out=$out"

# ── preflight.sh: needs: home ───────────────────────────────────────────────────────────────────────────────────
echo "preflight.sh: needs: home"
printf '#!/bin/bash\n# needs: home\n' >"$T/chk-home.sh"; printf '#!/bin/bash\n# needs: ship:none\n' >"$T/chk-none.sh"
printf '#!/bin/bash\necho ran >>"%s/pf.log"; echo "home: %s"; exit %s\n' "$T" '${FAKE_HF_OUT:-front visible}' '${FAKE_HF_RC:-0}' >"$T/fakehf"; chmod +x "$T/fakehf"
rm -f "$T/pf.log"; out=$(PREFLIGHT_HOME="$T/fakehf" "$P/verify/preflight.sh" "$T/chk-home.sh") rc=$?
[ $rc = 0 ] && [ -s "$T/pf.log" ] && ok "a check that needs home: home-front runs first" || bad "needs home: rc=$rc out=$out"
rm -f "$T/pf.log"; out=$(PREFLIGHT_HOME="$T/fakehf" FAKE_HF_RC=3 FAKE_HF_OUT="not in front" "$P/verify/preflight.sh" "$T/chk-home.sh") rc=$?
[ $rc = 3 ] && case "$out" in "NOT NOW: home: not in front"*) true ;; *) false ;; esac && ok "home not reachable: rc 3 (not now), never a FAIL" || bad "not reachable: rc=$rc out=$out"
rm -f "$T/pf.log"; out=$(PREFLIGHT_HOME="$T/fakehf" "$P/verify/preflight.sh" "$T/chk-none.sh") rc=$?
[ $rc = 0 ] && [ ! -e "$T/pf.log" ] && ok "a check without it: home left as it is" || bad "no need: rc=$rc"
for c in ww-clamp switcher-launch plasma-modes ww-stop term-feel; do
  grep -qE '^# needs:.* home( |$)' "$P/verify/$c.sh" || bad "$c.sh doesn't declare needs: home"; done
ok "the page checks of the triage declare needs: home"

exit $fail
