#!/bin/bash
# test-android-probe.sh - lib/android.sh _android_probe: finds adbd's Wireless debugging port on loopback when the app's
# mDNS can't (S25 11-23), and only a port that answers adb's CNXN with STLS - never another service.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0 fail=0
check() { if eval "$2"; then echo "  ok   - $1"; pass=$((pass + 1)); else echo "  FAIL - $1"; fail=$((fail + 1)); fi; }
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
command -v python3 >/dev/null || { echo "test-android-probe: 0 passed, 0 failed (no python3)"; exit 0; }

# A fake adbd (answers STLS) and a decoy that answers something else, on free ports in the probed range.
python3 - "$T" <<'PY' &
import socket, sys, threading
def serve(reply, name):
    for port in range(41000, 49000):
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try: s.bind(("127.0.0.1", port)); break
        except OSError: s.close()
    s.listen(8); open(f"{sys.argv[1]}/{name}", "w").write(str(port))
    while True:
        c, _ = s.accept()
        try:  # the scan's plain connect-and-close must not end the server
            if c.recv(64): c.sendall(reply)
        except OSError:
            pass
        finally:
            c.close()
threading.Thread(target=serve, args=(b"HTTP/1.1 400 Bad Request\r\n\r\n", "decoy"), daemon=True).start()
serve(b"STLS" + b"\0" * 20, "adbd")
PY
for _ in $(seq 50); do [[ -s "$T/adbd" && -s "$T/decoy" ]] && break; sleep 0.1; done

# shellcheck source=/dev/null
POWOS_LIB="$ROOT/lib" source "$ROOT/lib/android.sh" 2>/dev/null
export XDG_CACHE_HOME="$T/cache"
got=$(_android_probe)
check "finds the port that answers STLS" '[[ "$got" == "$(cat "$T/adbd")" ]]'
check "not the decoy" '[[ "$got" != "$(cat "$T/decoy")" ]]'
check "remembers it" '[[ -n "$got" && "$(cat "$T/cache/powos/adb-port")" == "$got" ]]'
echo 1 > "$T/cache/powos/adb-port"
check "a stale remembered port is re-probed" '[[ "$(_android_probe)" == "$(cat "$T/adbd")" ]]'
check "own addresses list no loopback" '! _android_own_addrs | grep -q "^127\."'
echo "test-android-probe: $pass passed, $fail failed"
(( fail == 0 ))
