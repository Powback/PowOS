#!/bin/bash
# test-base.sh - unit tests for `powos base` pure logic (name mapping, listing,
# validation). No podman/reboot/disk — those are I/O and need a VM.

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling. That produced random failures (test-windows.sh swung between 4
# and 11 "failures" on identical runs). Last-command status is the correct
# semantics for an assertion anyway.
set -u

# Prefer the WORKING TREE over the installed copy. This used to be the other
# way round, which meant running the suite inside a PowOS image silently
# tested /usr/lib/powos (the baked, possibly months-old code) instead of the
# changes under test — failures then looked like real regressions when the
# working tree was never loaded at all.
LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/base.sh
[[ -f "$LIB" ]] || LIB="/usr/lib/powos/base.sh"
# shellcheck disable=SC1090
source "$LIB"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1 (got: ${2:-})"; FAIL=$((FAIL+1)); }

echo "== image → base-name mapping =="
[[ "$(base_name_from_image ghcr.io/ublue-os/bazzite-nvidia-open:stable)" == "nvidia-open" ]] && ok "nvidia-open image" || bad "open"
[[ "$(base_name_from_image ghcr.io/ublue-os/bazzite-nvidia:stable)" == "nvidia" ]] && ok "closed nvidia image" || bad "closed"
[[ "$(base_name_from_image ghcr.io/ublue-os/bazzite:stable)" == "main" ]] && ok "amd/intel image" || bad "main"
r=$(base_name_from_image ghcr.io/ublue-os/bluefin:latest); [[ "$r" == "bluefin-latest" ]] && ok "other bootc image → derived name ($r)" || bad "other" "$r"

echo "== listing + validation against a fake USB layers dir =="
tmp="$(mktemp -d)"; mkdir -p "$tmp/base-nvidia-open" "$tmp/base-main"
names=$(base_list_names "$tmp")
echo "$names" | grep -qx "nvidia-open" && ok "lists nvidia-open" || bad "list open" "$names"
echo "$names" | grep -qx "main"        && ok "lists main"        || bad "list main" "$names"
base_name_valid "nvidia-open" "$tmp" && ok "validates present base" || bad "valid present"
base_name_valid "closed"      "$tmp" && bad "should reject absent base" || ok "rejects absent base"
rm -rf "$tmp"

echo "== version-swap naming (newer/older tags) =="
[[ "$(base_name_from_image ghcr.io/ublue-os/bazzite:41)" == "main" ]] && ok "older bazzite tag still maps main" || bad "old tag"

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
