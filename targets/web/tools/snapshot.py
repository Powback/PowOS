#!/usr/bin/env python3
"""Drives native QEMU to a small snapshot the browser resumes (targets/web/build-snapshot.sh).

    snapshot.py <serial-socket> <serial-log> <qmp-socket> <state-file>

The guest prepares itself: build-snapshot.sh boots it with a systemd.run= command (systemd's run generator, as
root, no login) that waits for the boot to finish, drops the page cache, compacts memory - with init_on_free=1
(web/machine.json) freed pages are zeros, which the migration stream stores as a few bytes each - prints its memory
use, and then a ready marker. This script:
1. waits for the marker on the serial console;
2. migrates the RUNNING machine to the state file. Not stopped first: QEMU carries the run state over, and a state
   saved paused resumes paused in the browser. QEMU stops it once the migration completes;
3. quits (closing the disk writes the chunked overlay).
"""
import json, os, re, socket, sys, time

serial_path, log_path, qmp_path, state = sys.argv[1:5]
MARKER = "POWOS-SNAPSHOT-42"  # printed by the guest as POWOS-SNAPSHOT-$((6*7)): its echo can't match


class Serial:
    def __init__(self, path):
        for _ in range(100):
            try:
                self.s = socket.socket(socket.AF_UNIX)
                self.s.connect(path)
                break
            except OSError:
                time.sleep(0.2)
        self.s.settimeout(0.5)
        self.buf = ""
        self.log = open(log_path, "a")

    def expect(self, pattern, timeout):
        rx = re.compile(pattern, re.M)
        end = time.time() + timeout
        while time.time() < end:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return m
            try:
                data = self.s.recv(65536).decode(errors="replace")
                self.buf += data
                self.log.write(data)
                self.log.flush()
            except socket.timeout:
                pass
        sys.exit(f"snapshot: no {pattern!r} on the serial console within {timeout}s")


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile("rw")
        self.f.readline()  # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "error" in r:
                raise RuntimeError(f"snapshot: {name}: {r['error']}")
            if "return" in r:
                return r["return"]


con = Serial(serial_path)
# The guest prints POWOS-SNAPSHOT-FAILED instead when its desktop never came up: no state is saved then.
if con.expect(re.escape(MARKER) + "|POWOS-SNAPSHOT-FAILED", 3600).group(0) != MARKER:
    sys.exit("snapshot: the guest's desktop never came up (POWOS-SNAPSHOT-FAILED; see serial.log) - nothing saved")
time.sleep(3)

q = QMP(qmp_path)
os.makedirs(os.path.dirname(state), exist_ok=True)
try:
    q.cmd("screendump", filename=os.path.join(os.path.dirname(state), "screen.ppm"))  # what is being saved
except RuntimeError as e:
    print(e, "(continuing: the picture is only for checking)", file=sys.stderr)
q.cmd("migrate", uri=f"file:{state}")
while True:
    st = q.cmd("query-migrate").get("status")
    if st == "completed":
        break
    if st in ("failed", "cancelled"):
        sys.exit(f"snapshot: migration {st}")
    time.sleep(0.5)
print(f"snapshot: {state} {os.path.getsize(state) / 1e6:.1f} MB")
try:
    q.cmd("quit")
except Exception:
    pass  # QEMU exits before answering
