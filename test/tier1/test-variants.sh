#!/bin/bash
# test-variants.sh - offline GPU-variant install store.
#
# The install media carries an OCI layout holding every published variant, so
# `bootc install --source-imgref oci:<dir>:<tag>` can lay down the right image
# for the hardware WITHOUT a network. These tests pin:
#
#   - the layout is discovered and its tags read the way the installer reads
#     them (the ref.name annotation in index.json)
#   - install-system emits --source-imgref/--target-imgref when the variant is
#     on the media, and does NOT when it is absent
#   - source and target differ ON PURPOSE: bytes come from the stick, but the
#     installed system tracks the registry so later upgrades work
#   - the wizard's flavor->variant map matches firstboot's, since two copies of
#     a mapping is exactly the kind of thing that silently drifts
#
# No root, no network, no real media: fixtures + shadowed tools.
#
# Usage:  bash test/tier1/test-variants.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Fixture: an OCI layout the way skopeo writes one ───────────────────────
make_layout() {
    local dir="$1"; shift
    mkdir -p "$dir/blobs/sha256"
    printf '{"imageLayoutVersion":"1.0.0"}\n' > "$dir/oci-layout"
    {
        printf '{"schemaVersion":2,"manifests":['
        local first=1 t
        for t in "$@"; do
            [[ $first -eq 1 ]] || printf ','
            first=0
            printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json",'
            printf '"digest":"sha256:%064d","size":1,' "${#t}"
            printf '"annotations":{"org.opencontainers.image.ref.name":"%s"}}' "$t"
        done
        printf ']}\n'
    } > "$dir/index.json"
}

# shellcheck source=/dev/null
source "$ROOT/lib/variants.sh"

echo "== layout discovery =="

LAYOUT="$TMP/variants"
make_layout "$LAYOUT" deck main nvidia-open
export POWOS_VARIANTS_DIR="$LAYOUT"

got=$(pv_list | tr '\n' ' ')
[[ "$got" == "deck main nvidia-open " ]] \
    && ok "reads every tag from index.json" \
    || bad "reads every tag from index.json" "got '$got'"

pv_have_variant deck        && ok "have deck"        || bad "have deck"
pv_have_variant nvidia-open && ok "have nvidia-open" || bad "have nvidia-open"
pv_have_variant bogus       && bad "absent variant reported present" || ok "absent variant reported absent"

got=$(pv_source_imgref deck)
[[ "$got" == "oci:$LAYOUT:deck" ]] \
    && ok "source imgref points at the media (oci: transport)" \
    || bad "source imgref points at the media" "got '$got'"

got=$(pv_target_imgref deck)
[[ "$got" == "ghcr.io/powback/powos:deck" ]] \
    && ok "target imgref is the registry ref for later upgrades" \
    || bad "target imgref is the registry ref" "got '$got'"

if pv_source_imgref bogus >/dev/null 2>&1; then
    bad "source imgref for an absent variant must fail"
else
    ok "source imgref for an absent variant fails (no bogus oci: ref)"
fi

# A fork/mirror must be able to retarget without patching code.
POWOS_VARIANTS_REPO="registry.example.com/team/powos"
got=$(pv_target_imgref main)
[[ "$got" == "registry.example.com/team/powos:main" ]] \
    && ok "target repo is overridable for forks/mirrors" \
    || bad "target repo is overridable" "got '$got'"
POWOS_VARIANTS_REPO="ghcr.io/powback/powos"

# A directory with no index.json is not a layout.
export POWOS_VARIANTS_DIR="$TMP/not-a-layout"; mkdir -p "$POWOS_VARIANTS_DIR"
if pv_variants_dir >/dev/null 2>&1; then
    bad "a directory without index.json must not count as a layout"
else
    ok "a directory without index.json is rejected"
fi
export POWOS_VARIANTS_DIR="$LAYOUT"

echo ""
echo "== install-system emits the offline flags =="

# Minimal shadows so isv_install_whole_disk can run its dry-run plan.
export POWOS_LIB="$ROOT/lib"
# shellcheck source=/dev/null
source "$ROOT/lib/install-system.sh" 2>/dev/null || { echo "cannot source install-system.sh"; exit 1; }

bootc() {
    if [[ "$*" == *"--help"* ]]; then echo "      --root-size <ROOT_SIZE>"; return 0; fi
    echo "BOOTC-RAN $*"; return 0
}
lsblk()  { echo "512000"; }
parted() { return 0; }
blkid()  { echo ""; }
findmnt() { echo ""; }

run_variant_plan() {
    ISV_DRY_RUN=1
    ISV_TARGET=/dev/sdz
    ISV_FS=btrfs
    ISV_SHARED_GB=0
    ISV_WINDOWS_GB=0
    ISV_VARIANT="$1"
    isv_install_whole_disk 2>&1
}

out=$(run_variant_plan deck)
echo "$out" | grep -q -- "--source-imgref oci:$LAYOUT:deck" \
    && ok "variant on media → --source-imgref reads from the stick" \
    || bad "--source-imgref emitted" "$(echo "$out" | grep -i imgref | head -2)"

echo "$out" | grep -q -- "--target-imgref ghcr.io/powback/powos:deck" \
    && ok "variant on media → --target-imgref records the registry ref" \
    || bad "--target-imgref emitted" "$(echo "$out" | grep -i imgref | head -2)"

echo "$out" | grep -q -- "--target-transport registry" \
    && ok "target transport is registry (so bootc upgrade works later)" \
    || bad "target transport emitted"

# Absent variant: install the running image, never reach for the network.
out=$(run_variant_plan nvidia-closed-nonexistent)
if echo "$out" | grep -q -- "--source-imgref"; then
    bad "absent variant must not emit a source-imgref" "$(echo "$out" | grep -i imgref | head -2)"
else
    ok "variant absent from media → no imgref flags, installs the running image"
fi
echo "$out" | grep -qi "not on this media" \
    && ok "absent variant is reported honestly, not silently ignored" \
    || bad "absent variant reported"

# No variant requested at all → byte-identical to the classic arg line.
out=$(run_variant_plan "")
if echo "$out" | grep -q -- "--source-imgref\|--target-imgref"; then
    bad "no variant requested must not change the bootc args"
else
    ok "no variant requested → classic bootc args unchanged"
fi

echo ""
echo "== flavor→variant map parity (wizard vs firstboot) =="

# Two copies of this mapping exist by necessity: the wizard runs from the lib,
# firstboot from a standalone script on the installed system. They must agree.
( # subshell: both files define same-named helpers
  # shellcheck source=/dev/null
  source "$ROOT/lib/install-wizard.sh" 2>/dev/null
  iwz_is_steam_deck() { return 1; }
  # EMPTY is a stand-in for the empty flavor: bash rejects "" as an
  # associative-array subscript, and the empty case is exactly the one worth
  # checking (an unrecorded flavor must still map somewhere sane).
  FLAVORS=(nvidia-open nvidia amd intel main deck EMPTY garbage)
  unmarshal() { [[ "$1" == EMPTY ]] && echo "" || echo "$1"; }
  declare -A wiz=()
  for f in "${FLAVORS[@]}"; do
      wiz["$f"]=$(iwz_variant_for_flavor "$(unmarshal "$f")")
  done
  # shellcheck source=/dev/null
  source "$ROOT/bin/powos-firstboot-apply" 2>/dev/null
  fb_is_steam_deck() { return 1; }
  drift=""
  for f in "${FLAVORS[@]}"; do
      got=$(fb_variant_for_flavor "$(unmarshal "$f")")
      [[ "${wiz[$f]}" == "$got" ]] || drift="$drift '$f'(wizard=${wiz[$f]} firstboot=$got)"
  done
  if [[ -z "$drift" ]]; then
      echo "  ok   - wizard and firstboot map every flavor identically"
      exit 0
  else
      echo "  FAIL - wizard and firstboot maps drifted:$drift"
      exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
