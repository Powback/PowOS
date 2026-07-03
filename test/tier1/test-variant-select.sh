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

ALL="nvidia-open,nvidia,main"   # a USB carrying all three variants

echo "== GPU → variant mapping (open is default for NVIDIA) =="
[[ "$(variant_from_gpu nvidia-desktop)" == "nvidia-open" ]] && ok "nvidia-desktop → nvidia-open" || bad "nvidia map"
[[ "$(variant_from_gpu nvidia-mobile)"  == "nvidia-open" ]] && ok "nvidia-mobile → nvidia-open"  || bad "nvidia-mobile map"
[[ "$(variant_from_gpu amd-desktop)"    == "main"        ]] && ok "amd → main"                   || bad "amd map"
[[ "$(variant_from_gpu intel)"          == "main"        ]] && ok "intel → main"                 || bad "intel map"
[[ "$(variant_from_gpu unknown)"        == "main"        ]] && ok "unknown → main"               || bad "unknown map"

echo "== Auto-detect defaults NVIDIA to OPEN =="
r=$(sel "" nvidia-desktop "$ALL"); [[ "$r" == "nvidia-open" ]] && ok "nvidia GPU auto-picks OPEN" || bad "auto open" "$r"
r=$(sel "auto" amd "$ALL");        [[ "$r" == "main" ]]        && ok "amd GPU picks main"         || bad "auto amd" "$r"
r=$(sel "auto" intel "main");      [[ "$r" == "main" ]]        && ok "intel picks main"           || bad "auto intel" "$r"

echo "== User can SELECT closed proprietary (the whole point) =="
r=$(sel "nvidia" nvidia-desktop "$ALL"); [[ "$r" == "nvidia" ]] && ok "override 'nvidia' picks CLOSED over open default" || bad "select closed" "$r"
r=$(sel "nvidia-open" nvidia-desktop "$ALL"); [[ "$r" == "nvidia-open" ]] && ok "override 'nvidia-open' picks open" || bad "select open" "$r"
r=$(sel "main" nvidia-desktop "$ALL"); [[ "$r" == "main" ]] && ok "override 'main' picks amd/intel build" || bad "select main" "$r"

echo "== Override for a variant not on the USB → falls back to auto =="
r=$(sel "nvidia" amd "main"); [[ "$r" == "main" ]] && ok "missing closed variant → auto main" || bad "override-missing" "$r"

echo "== Fallbacks when detected variant absent =="
r=$(sel "auto" nvidia-desktop "main"); [[ "$r" == "main" ]] && ok "nvidia GPU but only main on USB → main" || bad "fallback main" "$r"
r=$(sel "auto" nvidia-desktop "nvidia"); [[ "$r" == "nvidia" ]] && ok "only closed nvidia on USB → nvidia" || bad "single variant" "$r"

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
