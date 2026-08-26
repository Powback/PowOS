#!/usr/bin/env bash
# build/verify-variant-store.sh <oci-layout-dir> [expected-tag ...]
#
# Prove an OCI layout is COMPLETE, not merely present.
#
# The check this replaces was `skopeo inspect --raw oci:<dir>:<tag>`, which
# reads the manifest and stops. A manifest is a few hundred bytes; it resolves
# fine while the multi-gigabyte layers it names are half-copied or absent. On a
# stick that difference is the whole story: the installer selects a variant,
# starts unpacking it, and fails on a machine with no network.
#
# So this walks index.json -> manifest -> config + every layer, and asserts each
# blob exists at the size its descriptor declares.
set -uo pipefail
DIR="${1:?usage: verify-variant-store.sh <oci-dir> [tag ...]}"; shift || true
S() {
    # Prime the credential cache with its own stdin, then run with -n so the
    # caller's stdin reaches the command. See build/cycle-lib.sh for the bug
    # the obvious `echo pass | sudo -S "$@"` form causes.
    sudo -n true 2>/dev/null || echo "${POWOS_SUDO_PASS:-powos}" | sudo -S -v 2>/dev/null
    sudo -n "$@" 2>/dev/null
}
S cat "$DIR/index.json" 2>/dev/null | DIR="$DIR" EXPECT="$*" python3 -c '
import json, os, sys, subprocess

d = os.environ["DIR"]; expect = os.environ["EXPECT"].split()
def read(path):
    try: return open(path, "rb").read()
    except PermissionError:
        return subprocess.run(["sudo","-n","cat",path], capture_output=True).stdout
def blob(dig):
    return os.path.join(d, "blobs", *dig.split(":", 1))

idx = json.load(sys.stdin)
found, bad = {}, []
for m in idx.get("manifests", []):
    tag = (m.get("annotations") or {}).get("org.opencontainers.image.ref.name")
    if not tag: continue
    found[tag] = m["digest"]

for tag, dig in sorted(found.items()):
    n = miss = 0
    try:
        man = json.loads(read(blob(dig)))
    except Exception as e:
        bad.append(f"{tag}: manifest unreadable ({e})"); continue
    descs = []
    if "config" in man: descs.append(man["config"])
    descs += man.get("layers", [])
    # An image index (multi-arch) points at further manifests.
    for sub in man.get("manifests", []):
        try:
            sm = json.loads(read(blob(sub["digest"])))
            if "config" in sm: descs.append(sm["config"])
            descs += sm.get("layers", [])
        except Exception:
            bad.append("%s: sub-manifest %s unreadable" % (tag, sub["digest"][:19]))
    for de in descs:
        n += 1
        p = blob(de["digest"])
        try: sz = os.path.getsize(p)
        except OSError:
            miss += 1; continue
        if "size" in de and sz != de["size"]:
            miss += 1
    if miss: bad.append(f"{tag}: {miss} of {n} blobs missing or wrong size")
    else:    print(f"  ok   - variant {tag}: all {n} blobs present at declared size")

for t in expect:
    if t not in found: bad.append(f"expected variant {t} is not in the index")

for b in bad: print(f"  FAIL - {b}")
sys.exit(1 if bad else 0)
'
