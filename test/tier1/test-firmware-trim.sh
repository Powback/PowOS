#!/usr/bin/env bash
# Deck firmware trim — and the trees that must survive it.
#
# linux-firmware lands in every variant, so a Deck carries ~285M of blobs it can
# never load. Removing them is easy; removing the wrong one costs you wifi.
#
#   ath*   THE WIFI. The LCD Deck (Jupiter) uses a Qualcomm Atheros QCA6174, so
#          ath10k is required. It reads like a removable vendor blob and is not
#          — it very nearly went into a removal list on exactly that basis.
#   qcom   the OLED Deck (Galileo) uses a WCN6855.
#   amdgpu the GPU.
set -uo pipefail
PASS=0; FAIL=0
check(){ if ( eval "$2" ) >/dev/null 2>&1; then echo "  ok   - $1"; PASS=$((PASS+1));
         else echo "  FAIL - $1"; FAIL=$((FAIL+1)); fi }
CF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/Containerfile"

echo "== deck firmware trim =="
check "the trim exists and is deck-gated" \
      'grep -q "dropped nvidia/intel/i915/mediatek" "$CF"'
for v in nvidia intel i915 mediatek; do
  check "drops $v (no such hardware on a Deck)" 'grep -q "/usr/lib/firmware/'"$v"'" "$CF"'
done
for k in amdgpu ath10k qcom; do
  check "NEVER drops $k" '! grep -qE "rm -rf[^;]*firmware/'"$k"'" "$CF"'
done
check "the build FAILS if wifi/gpu firmware went missing" \
      'grep -q "the Deck needs it (gpu/wifi)" "$CF"'
check "non-deck variants keep the full set" \
      'grep -q "firmware: left complete" "$CF"'
echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
