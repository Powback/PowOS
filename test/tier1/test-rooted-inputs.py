#!/usr/bin/env python3
"""test-rooted-inputs.py - every file the rooted deploy installs on the phone starts a rooted deploy when it changes.

tools/phone/ship.sh's rooted_inputs() decides whether a commit runs `targets/android/rooted/rooted.sh deploy`. It was a
hand list and fell behind what the deploy installs: lib/devices (efcf8483), then most of lib/apps (11-24: the Steam
stall fix a27864d4 in lib/apps/powos-sleep-gui would never have shipped).

Checks, running ship.sh's REAL rooted_inputs() (cut out of ship.sh) against a fake `git diff` that reports every
candidate file as changed:
  (1) every file the deploy installs (tools/phone/rooted-inputs.py --files: rooted.sh's pushes narrowed to what
      powos-deploy.sh installs; it fails on a push it can't resolve) is reported - none missing;
  (2) the derivation still sees the known installs (anchors), so a parser that silently finds nothing fails;
  (3) staged-but-not-installed, shell, APK and excluded files (node_modules, pkgs/*/test) are NOT reported.

Usage:  python3 test/tier1/test-rooted-inputs.py
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
FAILS = []
ANCHORS = ["lib/apps/powos-sleep-gui", "lib/apps/powos-sleep", "lib/apps/powos-units", "lib/apps/powos-terms",
           "bin/powos", "lib/config.sh", "lib/devices/powos-deviced", "targets/android/play/powos-steam",
           "targets/android/rooted/powos-deploy.sh", "targets/android/session/powos-android-app",
           "lib/ai/agents/powos-agentsd", "tools/app-api/appcap_serve.py", "lib/powos_py/common.py"]
NEGATIVE = ["lib/apps/powos-noroot-services", "shell/index.html", "targets/android/app/build.gradle.kts",
            "lib/ai/sandbox/node_modules/x/index.js", "targets/android/pkgs/kwin/test/run.sh",
            "targets/android/rooted/app-frida.sh", "README.md"]


def check(cond, msg):
    print(f"  {'ok  ' if cond else 'FAIL'} - {msg}")
    if not cond:
        FAILS.append(msg)


def main():
    print("rooted deploy inputs (ship.sh rooted_inputs vs what rooted.sh deploy installs)")
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools/phone/rooted-inputs.py"), "--files"], cwd=ROOT,
                       capture_output=True, text=True)
    check(r.returncode == 0, f"tools/phone/rooted-inputs.py resolves every push ({r.stderr.strip()[:300]})")
    installed = [f for f in r.stdout.split() if "/node_modules/" not in f and not re.search(r"^targets/android/pkgs/[^/]*/test/", f)]
    for a in ANCHORS:
        check(a in installed, f"the derivation finds {a}")

    src = open(os.environ.get("SHIP_SH") or os.path.join(ROOT, "tools/phone/ship.sh")).read()   # SHIP_SH: check another copy
    m = re.search(r"^  rooted_inputs\(\) .*?(?=^  # )", src, re.S | re.M)
    check(bool(m), "ship.sh defines rooted_inputs()")
    if not m:
        return
    with tempfile.TemporaryDirectory() as t:
        cand = os.path.join(t, "candidates")
        with open(cand, "w") as f:
            f.write("\n".join(installed + NEGATIVE) + "\n")
        matcher = os.path.join(t, "match.py")
        with open(matcher, "w") as f:
            f.write("""import fnmatch, sys
specs = sys.argv[sys.argv.index('--') + 1:]
for p in open(sys.argv[1]).read().split():
    if any(fnmatch.fnmatchcase(p, s) if any(c in s for c in '*?[') else (p == s or p.startswith(s + '/')) for s in specs):
        print(p)
""")
        # git diff is faked (every candidate "changed"); B="" makes rooted-inputs.py read the working tree.
        script = (f"git() {{ if [ \"$1\" = diff ]; then python3 {matcher!r} {cand!r} \"$@\"; else command git \"$@\"; fi; }}\n"
                  f"unset SHIP_ROOTED_INPUTS\n{m.group(0)}\nrooted_inputs BASE ''\n")
        out = subprocess.run(["bash", "-c", script], cwd=ROOT, capture_output=True, text=True)
    got = set(out.stdout.split())
    check("rooted-inputs.py failed" not in out.stderr, f"rooted_inputs() used the derivation ({out.stderr.strip()[:200]})")
    missing = [f for f in installed if f not in got]
    check(not missing, f"every installed file starts a rooted deploy ({len(installed)} files; missing: {missing[:12]})")
    extra = [f for f in NEGATIVE if f in got]
    check(not extra, f"staged-only/shell/APK/excluded files start none ({extra})")


main()
print(f"{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failure(s)")
sys.exit(1 if FAILS else 0)
