#!/usr/bin/env bash
# loopback-unix (targets/android/app/engine/native-src/launcher/loopback-unix.c): PowOS's no-root services' TCP ports
# become Unix sockets only PowOS's uid can open (docs/research/nonroot-parity.md, "Who can reach SpacetimeDB and the
# App API"). Real programs under the preload, on Linux/aarch64:
#   1. a server binding 127.0.0.1:3410 listens on <dir>/3410.sock (mode 0600) and on NO TCP port,
#   2. a client of the same uid reaching http://127.0.0.1:3410 gets the server (getsockname/peer faked as TCP),
#   3. another uid can't: the socket file refuses it, and a peer that gets past the file (root) is dropped by
#      SO_PEERCRED before the server sees a request,
#   4. other ports and addresses are untouched.
# Needs a C compiler for aarch64 Linux: `cc` here, else gcc:14 through docker; SKIP without either.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$HERE/targets/android/app/engine/native-src/launcher/loopback-unix.c

if [ "${LOOPBACK_INNER:-}" != 1 ]; then
  if [ "$(uname -s)/$(uname -m)" = Linux/aarch64 ] && command -v cc >/dev/null && [ "$(id -u)" = 0 ]; then
    LOOPBACK_INNER=1 exec bash "$0"
  elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    # An x86 host without arm64 emulation (binfmt/qemu) can't start the image: exec format error, rc 255 with no
    # output - that red-lined master CI for a week (issue #10). Probe once; the workflow installs qemu so CI runs it.
    docker run --rm --platform linux/arm64 gcc:14 true >/dev/null 2>&1 || {
      echo "SKIP test-loopback-unix: docker can't run linux/arm64 here (no qemu binfmt)"; exit 0; }
    exec docker run --rm --platform linux/arm64 -e LOOPBACK_INNER=1 -v "$HERE:$HERE:ro" gcc:14 bash "$HERE/test/tier1/test-loopback-unix.sh"
  fi
  echo "SKIP test-loopback-unix: no aarch64 Linux C compiler (cc as root, or docker with gcc:14)"
  exit 0
fi

W=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$W"' EXIT
cc -O2 -Wall -Werror -shared -fPIC -nostdlib -ffreestanding -fno-stack-protector -o "$W/shim.so" "$SRC"
mkdir -p "$W/sock" && chown nobody "$W/sock" && chmod 700 "$W/sock" && chmod 755 "$W"
export POWOS_LOOPBACK_DIR=$W/sock POWOS_LOOPBACK_PORTS=3410,3411
PRE=$W/shim.so
fail() { echo "FAIL test-loopback-unix: $*"; exit 1; }

cat >"$W/server.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"hello {self.client_address[0]} on {self.server.server_address[1]}".encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a):
        open(sys.argv[2], "a").write(self.requestline + "\n")
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
# The server as an ordinary uid (nobody), as PowOS's services run as the app's uid.
setpriv --reuid=nobody --regid=nogroup --clear-groups env LD_PRELOAD="$PRE" python3 "$W/server.py" 3410 "$W/sock/log" &
for _ in $(seq 50); do [ -S "$W/sock/3410.sock" ] && break; sleep 0.1; done
[ -S "$W/sock/3410.sock" ] || fail "no $W/sock/3410.sock (the bind wasn't redirected)"
[ "$(stat -c %a "$W/sock/3410.sock")" = 600 ] || fail "socket mode $(stat -c %a "$W/sock/3410.sock"), want 600"

# 1. no TCP listener at all: a client without the preload is refused
python3 -c 'import socket
try:
    socket.create_connection(("127.0.0.1", 3410), 1); print("open")
except OSError: print("refused")' | grep -qx refused || fail "127.0.0.1:3410 is open over TCP"

# 2. the same uid through the preload: the server answers, both ends think it's TCP
out=$(setpriv --reuid=nobody --regid=nogroup --clear-groups env LD_PRELOAD="$PRE" python3 -c 'import urllib.request
print(urllib.request.urlopen("http://127.0.0.1:3410/x", timeout=3).read().decode())')
[ "$out" = "hello 127.0.0.1 on 3410" ] || fail "same-uid client got: $out"
grep -q 'GET /x' "$W/sock/log" || fail "the server saw no request"

# 3a. another uid (daemon) through the preload: the 0600 socket refuses it - as "connection refused", never TCP
out=$(setpriv --reuid=daemon --regid=daemon --clear-groups env LD_PRELOAD="$PRE" python3 -c 'import urllib.request
try:
    urllib.request.urlopen("http://127.0.0.1:3410/other-uid", timeout=3); print("reached")
except Exception as e: print("refused", e)')
case $out in refused*) ;; *) fail "another uid reached the server: $out" ;; esac
# 3b. root gets past the file's mode: SO_PEERCRED drops it before the server reads a request
python3 - "$W/sock/3410.sock" <<'PY' || fail "a peer of another uid got an answer"
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1])
s.sendall(b"GET /root-peer HTTP/1.0\r\n\r\n")
try:
    data = s.recv(100)
except (ConnectionResetError, socket.timeout):
    data = b""
sys.exit(1 if data else 0)
PY
sleep 0.2
! grep -q 'other-uid\|root-peer' "$W/sock/log" || fail "the server saw another uid's request"
# the server still serves afterwards (the refused accept didn't stop it)
out=$(setpriv --reuid=nobody --regid=nogroup --clear-groups env LD_PRELOAD="$PRE" python3 -c 'import urllib.request
print(urllib.request.urlopen("http://127.0.0.1:3410/again", timeout=3).read().decode())')
[ "$out" = "hello 127.0.0.1 on 3410" ] || fail "server stopped serving after a refused peer: $out"

# 4. other ports stay TCP under the preload
setpriv --reuid=nobody --regid=nogroup --clear-groups env LD_PRELOAD="$PRE" python3 "$W/server.py" 3499 "$W/sock/log2" &
for _ in $(seq 50); do python3 -c 'import socket; socket.create_connection(("127.0.0.1", 3499), 1)' 2>/dev/null && break; sleep 0.1; done
python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:3499/", timeout=3)' || fail "port 3499 (not protected) didn't stay TCP"
[ ! -e "$W/sock/3499.sock" ] || fail "an unprotected port was redirected"

echo "PASS test-loopback-unix"
