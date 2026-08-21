#!/usr/bin/env bash
# fetch-variants.sh - stage every published PowOS variant into ONE OCI layout,
# so an install USB can install any of them with no network.
#
# WHY
# `bootc install --source-imgref oci:<dir>:<tag>` reads an image's bytes from a
# local OCI layout. Put that layout on the USB's POWOS-DATA partition and the
# installer can lay down the NVIDIA image on an NVIDIA machine and the Deck
# image on a Deck, from the same stick, on a machine with no working network
# driver.
#
# WHY ONE LAYOUT AND NOT THREE DIRECTORIES
# An OCI layout addresses blobs by digest under blobs/sha256/, so layers that
# appear in more than one variant are stored ONCE. The variants share every
# PowOS layer (they differ only in their bazzite base), so the total is well
# under the sum of the parts.
#
# Usage:
#   ./build/fetch-variants.sh [OUT_DIR] [VARIANT...]
#
#   OUT_DIR   default build/output/variants
#   VARIANT   default: deck main nvidia-open
#
#   POWOS_IMAGE=ghcr.io/powback/powos   source repository
#
# Then write it to a USB with:
#   sudo ./build/install-to-usb.sh --with-variants build/output/variants /dev/sdX

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-build/output/variants}"
shift || true
VARIANTS=("$@")
if [[ ${#VARIANTS[@]} -eq 0 ]]; then
    VARIANTS=(deck main nvidia-open)
fi
IMAGE="${POWOS_IMAGE:-ghcr.io/powback/powos}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
log()  { echo -e "${CYAN}[variants]${NC} $*"; }
ok()   { echo -e "${GREEN}[variants]${NC} $*"; }
warn() { echo -e "${YELLOW}[variants]${NC} $*" >&2; }
err()  { echo -e "${RED}[variants]${NC} $*" >&2; }

copier=""
if command -v skopeo >/dev/null 2>&1; then
    copier=skopeo
elif command -v podman >/dev/null 2>&1; then
    copier=podman
else
    err "need skopeo (preferred) or podman to fetch images."
    exit 1
fi
log "using $copier"

mkdir -p "$OUT_DIR"

fetched=()
failed=()
for v in "${VARIANTS[@]}"; do
    log "fetching $IMAGE:$v → oci:$OUT_DIR:$v"
    if [[ "$copier" == skopeo ]]; then
        # skopeo writes straight into a shared OCI layout, reusing blobs it
        # already has there — this is what makes the dedup happen.
        if skopeo copy --preserve-digests \
             "docker://$IMAGE:$v" "oci:$OUT_DIR:$v"; then
            fetched+=("$v")
        else
            warn "failed to fetch $v"; failed+=("$v")
        fi
    else
        # podman has no direct registry→oci-layout copy, so stage through
        # local storage. Slower and uses more scratch space, hence the
        # preference for skopeo above.
        if podman pull "$IMAGE:$v" >/dev/null && \
           podman push "$IMAGE:$v" "oci:$OUT_DIR:$v"; then
            fetched+=("$v")
        else
            warn "failed to fetch $v"; failed+=("$v")
        fi
    fi
done

if [[ ${#fetched[@]} -eq 0 ]]; then
    err "no variants fetched — refusing to leave an empty layout at $OUT_DIR"
    exit 1
fi

# The installer identifies variants by the ref.name annotation in index.json;
# if that is missing the layout is unusable to it, so verify rather than assume.
log "verifying the layout is readable the way the installer reads it..."
present=$(python3 - "$OUT_DIR/index.json" <<'PY' || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for m in d.get("manifests", []):
    ref = (m.get("annotations") or {}).get("org.opencontainers.image.ref.name")
    if ref:
        print(ref)
PY
)
if [[ -z "$present" ]]; then
    err "index.json has no ref.name annotations — the installer could not select a variant."
    exit 1
fi

echo ""
ok "staged variants: $(echo "$present" | tr '\n' ' ')"
[[ ${#failed[@]} -gt 0 ]] && warn "NOT staged: ${failed[*]}"
echo "  layout: $OUT_DIR"
echo "  size:   $(du -sh "$OUT_DIR" 2>/dev/null | cut -f1)"
echo ""
echo "Write it to a USB with:"
echo "  sudo ./build/install-to-usb.sh --with-variants $OUT_DIR /dev/sdX"
