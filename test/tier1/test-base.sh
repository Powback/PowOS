#!/bin/bash
# test-base.sh - unit tests for `powos base` pure logic (name mapping, listing,
# validation). No podman/reboot/disk — those are I/O and need a VM.

set -uo pipefail

LIB="/usr/lib/powos/base.sh"
[[ -f "$LIB" ]] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/base.sh"
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
