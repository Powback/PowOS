#!/bin/bash
# test-gate-host.sh - Tier-1 tests for the shell gate's host selection (shell/dev/gate-remote.sh: GATE_HOST=58).
#
# A fake `ssh` on PATH logs every call and answers `uname -m` with $FAKE_ARCH (or fails, FAKE_SSH_DOWN=1); a fake
# rsync accepts anything. Checks: GATE_HOST unset/local/0 never touches ssh; 58 means powos@192.168.50.58; GATE_REMOTE
# (the older name) still works; the remote's arch picks the platform; the image is fully qualified for podman; an
# unreachable host leaves GR_HOST empty and says it runs locally; gr_run's remote command carries nice 10, --cpus 24
# (GATE_HOST_CPUS overrides) and the platform.
#
# Usage:  bash test/tier1/test-gate-host.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../../shell/dev/gate-remote.sh"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
command -v perl >/dev/null || { echo "  skip - no perl"; echo "== Results: 0 passed, 0 failed, 1 skipped =="; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
# fake ssh: log the call; drop -o options; then the host and the remote command.
echo "$*" >> "$FAKE_LOG"
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
[ -n "${FAKE_SSH_DOWN:-}" ] && { echo "ssh: connect: Connection refused" >&2; exit 255; }
echo "$1" >> "$FAKE_LOG.hosts"; shift
case "$*" in
  "uname -m") echo "${FAKE_ARCH:-x86_64}" ;;
  'echo $HOME') echo /home/fake ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/rsync"
chmod +x "$T/bin/ssh" "$T/bin/rsync"
export PATH="$T/bin:$PATH" FAKE_LOG="$T/ssh.log"

# One gr_init in a fresh shell with the given environment; prints GR_HOST|GR_PLATFORM|GR_IMAGE and gr_init's output.
probe() {
  rm -f "$FAKE_LOG" "$FAKE_LOG.hosts"
  env -u GATE_HOST -u GATE_REMOTE -u GATE_HOST_CPUS "$@" bash -c '. "$1"; msg=$(gr_init zenika/alpine-chrome:with-puppeteer)
    echo "$msg" > "$FAKE_LOG.msg"; gr_init zenika/alpine-chrome:with-puppeteer >/dev/null; echo "$GR_HOST|$GR_PLATFORM|$GR_IMAGE"' _ "$LIB"
}

out=$(probe)
[ "$out" = "||" ] && [ ! -s "$FAKE_LOG" ] && ok "unset: local, no ssh" || bad "unset: got '$out', ssh log: $(cat "$FAKE_LOG" 2>/dev/null)"
for v in local 0; do
  out=$(probe GATE_HOST=$v)
  [ "$out" = "||" ] && [ ! -s "$FAKE_LOG" ] && ok "GATE_HOST=$v: local, no ssh" || bad "GATE_HOST=$v: got '$out'"
done

out=$(probe GATE_HOST=58)
[ "${out%%|*}" = powos@192.168.50.58 ] && ok "GATE_HOST=58 -> powos@192.168.50.58" || bad "GATE_HOST=58: got '$out'"
[ "$(sort -u "$FAKE_LOG.hosts")" = powos@192.168.50.58 ] && ok "every ssh call goes to .58" || bad "ssh hosts: $(sort -u "$FAKE_LOG.hosts" | paste -sd' ' -)"
case $out in *"|linux/amd64|"*) ok "x86_64 remote -> linux/amd64" ;; *) bad "x86_64 remote: '$out'" ;; esac
[ "${out##*|}" = docker.io/zenika/alpine-chrome:with-puppeteer ] && ok "image fully qualified for podman" || bad "image: '${out##*|}'"
grep -q 'docker pull' "$FAKE_LOG" && ok "the remote prepares the image (inspect || pull)" || bad "no image pull on the remote"

out=$(probe GATE_HOST=58 FAKE_ARCH=aarch64)
case $out in *"|linux/arm64|"*) ok "aarch64 remote -> linux/arm64" ;; *) bad "aarch64 remote: '$out'" ;; esac

out=$(probe GATE_REMOTE=me@box)
[ "${out%%|*}" = me@box ] && ok "GATE_REMOTE (older name) still selects the host" || bad "GATE_REMOTE: '$out'"
out=$(probe GATE_HOST=other@box GATE_REMOTE=me@box)
[ "${out%%|*}" = other@box ] && ok "GATE_HOST wins over GATE_REMOTE" || bad "GATE_HOST vs GATE_REMOTE: '$out'"
out=$(probe GATE_HOST=local GATE_REMOTE=me@box)
[ "$out" = "||" ] && ok "GATE_HOST=local wins over GATE_REMOTE" || bad "GATE_HOST=local + GATE_REMOTE: '$out'"

out=$(probe GATE_HOST=58 FAKE_SSH_DOWN=1)
[ "$out" = "||" ] && ok "unreachable: GR_HOST empty (local)" || bad "unreachable: '$out'"
grep -q 'unreachable - running locally' "$FAKE_LOG.msg" && ok "unreachable: says it runs locally" || bad "unreachable message: $(cat "$FAKE_LOG.msg")"

# gr_run: the remote docker command.
run_cmd() {
  rm -f "$FAKE_LOG"
  env -u GATE_HOST_CPUS "$@" bash -c '. "$1"; GR_HOST=powos@192.168.50.58 GR_PLATFORM=linux/amd64
    gr_run powos-gate-1-r1 -v "@/run/agent.0/shell:/shell:ro" img node gate.mjs' _ "$LIB" >/dev/null
  tail -1 "$FAKE_LOG"
}
c=$(run_cmd)
case $c in *"nice -n 10 docker run --rm --name powos-gate-1-r1 --cpus 24 "*) ok "gr_run: nice 10, --cpus 24" ;; *) bad "gr_run: '$c'" ;; esac
case $c in *"--platform linux/amd64"*) ok "gr_run: the remote's platform" ;; *) bad "gr_run platform: '$c'" ;; esac
case $c in *"/home/fake/.cache/powos-gate-remote/run/agent.0/shell:/shell:ro"*) ok "gr_run: @/ paths under the remote's root" ;; *) bad "gr_run mount: '$c'" ;; esac
c=$(run_cmd GATE_HOST_CPUS=8)
case $c in *"--cpus 8 "*) ok "GATE_HOST_CPUS=8 -> --cpus 8" ;; *) bad "GATE_HOST_CPUS=8: '$c'" ;; esac

echo "== Results: $PASS passed, $FAIL failed, 0 skipped =="
[ $FAIL = 0 ]
