#!/bin/bash
# test-variant-select.sh - unit tests for boot-time GPU variant selection.
# Pure logic, no hardware. Verifies auto-detect, manual override, and fallbacks.

set -uo pipefail

LIB="/usr/lib/powos/boot/variant-select.sh"
[[ -f "$LIB" ]] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/boot/variant-select.sh"
# shellcheck disable=SC1090
source "$LIB"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1 (got: ${2:-})"; FAIL=$((FAIL+1)); }

# sel <override> <gpu> <available> -> chosen variant (drops the reason)
sel() { variant_select "$1" "$2" "$3" | cut -f1; }

echo "== GPU → variant mapping =="
[[ "$(variant_from_gpu nvidia-desktop)" == "nvidia" ]] && ok "nvidia-desktop → nvidia" || bad "nvidia map"
[[ "$(variant_from_gpu nvidia-mobile)"  == "nvidia" ]] && ok "nvidia-mobile → nvidia"  || bad "nvidia-mobile map"
[[ "$(variant_from_gpu amd-desktop)"    == "main"   ]] && ok "amd → main"              || bad "amd map"
[[ "$(variant_from_gpu intel)"          == "main"   ]] && ok "intel → main"            || bad "intel map"
[[ "$(variant_from_gpu unknown)"        == "main"   ]] && ok "unknown → main"          || bad "unknown map"

echo "== Auto-detect (override empty/auto) =="
r=$(sel "" nvidia-desktop "nvidia,main"); [[ "$r" == "nvidia" ]] && ok "nvidia GPU picks nvidia" || bad "auto nvidia" "$r"
r=$(sel "auto" amd "nvidia,main");        [[ "$r" == "main" ]]   && ok "amd GPU picks main"      || bad "auto amd" "$r"
r=$(sel "auto" intel "main");             [[ "$r" == "main" ]]   && ok "intel picks main"        || bad "auto intel" "$r"

echo "== Manual override =="
r=$(sel "main" nvidia-desktop "nvidia,main"); [[ "$r" == "main" ]] && ok "override main beats nvidia GPU" || bad "override main" "$r"
r=$(sel "nvidia" amd "nvidia,main");          [[ "$r" == "nvidia" ]] && ok "override nvidia beats amd GPU" || bad "override nvidia" "$r"

echo "== Override for a variant not on the USB → falls back to auto =="
r=$(sel "nvidia" amd "main"); [[ "$r" == "main" ]] && ok "missing nvidia variant → auto main" || bad "override-missing" "$r"

echo "== Fallbacks when detected variant absent =="
r=$(sel "auto" nvidia-desktop "main"); [[ "$r" == "main" ]] && ok "nvidia GPU but only main on USB → main" || bad "fallback main" "$r"
r=$(sel "auto" nvidia-desktop "nvidia"); [[ "$r" == "nvidia" ]] && ok "only nvidia on USB → nvidia" || bad "single variant" "$r"

echo "== variant_available helper =="
variant_available nvidia "nvidia,main" && ok "finds present variant" || bad "available present"
variant_available foo "nvidia,main"    || ok "rejects absent variant"

echo "== USB manifest discovery (base-*/ dirs) =="
tmp="$(mktemp -d)"; mkdir -p "$tmp/base-nvidia" "$tmp/base-main"
avail="$(variant_list_available "$tmp")"
# order isn't guaranteed; check membership
( variant_available nvidia "$avail" && variant_available main "$avail" ) \
    && ok "lists both base-* variants ($avail)" || bad "manifest discovery" "$avail"
rm -rf "$tmp"

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
