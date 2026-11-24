#!/bin/bash
# test-android-probe.sh - lib/android.sh _android_probe: finds adbd's Wireless debugging port on loopback when the app's
# mDNS can't (S25 11-23), and only a port that answers adb's CNXN with STLS - never another service.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0 fail=0
check() { if eval "$2"; then echo "  ok   - $1"; pass=$((pass + 1)); else echo "  FAIL - $1"; fail=$((fail + 1)); fi; }
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
command -v python3 >/dev/null || { echo "test-android-probe: 0 passed, 0 failed (no python3)"; exit 0; }

# A fake adbd (answers STLS) and a decoy that answers something else, on free ports in the probed range. Disjoint
# ranges, decoy below adbd (the probe goes up, so it meets the decoy first): from one shared range, both bound the same
# port under SO_REUSEADDR (Linux allows it until one listens), the second listen() failed and no adbd ever came up (CI).
python3 - "$T" <<'PY' &
import socket, sys, threading
def serve(reply, name, lo, hi):
    for port in range(lo, hi):
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try: s.bind(("127.0.0.1", port)); s.listen(8); break
        except OSError: s.close()
    open(f"{sys.argv[1]}/{name}", "w").write(str(port))
    while True:
        c, _ = s.accept()
        try:  # the scan's plain connect-and-close must not end the server
            if c.recv(64): c.sendall(reply)
        except OSError:
            pass
        finally:
            c.close()
threading.Thread(target=serve, args=(b"HTTP/1.1 400 Bad Request\r\n\r\n", "decoy", 41000, 45000), daemon=True).start()
serve(b"STLS" + b"\0" * 20, "adbd", 45000, 49000)
PY
for _ in $(seq 50); do [[ -s "$T/adbd" && -s "$T/decoy" ]] && break; sleep 0.1; done
[[ -s "$T/adbd" && -s "$T/decoy" ]] || { echo "  FAIL - the fake adbd and decoy didn't start"; exit 1; }

# shellcheck source=/dev/null
POWOS_LIB="$ROOT/lib" source "$ROOT/lib/android.sh" 2>/dev/null
export XDG_CACHE_HOME="$T/cache"
got=$(_android_probe)
check "finds the port that answers STLS" '[[ -n "$got" && "$got" == "$(cat "$T/adbd")" ]]'
check "not the decoy" '[[ "$got" != "$(cat "$T/decoy")" ]]'
check "remembers it" '[[ -n "$got" && "$(cat "$T/cache/powos/adb-port")" == "$got" ]]'
echo 1 > "$T/cache/powos/adb-port"
check "a stale remembered port is re-probed" '[[ "$(_android_probe)" == "$(cat "$T/adbd")" ]]'
check "own addresses list no loopback" '! _android_own_addrs | grep -q "^127\."'
echo "test-android-probe: $pass passed, $fail failed"
(( fail == 0 ))
