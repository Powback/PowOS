#!/usr/bin/env bash
# export-base-rootfs.sh - produce build/output/base-<variant>/ rootfs trees
# from PUBLISHED images, so a live USB can boot into any variant.
#
# WHY THIS EXISTS
# The initramfs picks a live base from layers/base-<variant>/ on POWOS-DATA
# (see powos_select_base_variant in lib/dracut/90powos-ramboot/ramboot-setup.sh
# — GPU auto-detect, rd.powos.variant= override, persistent default). The only
# way to produce those trees was `build/build-iso.sh variants`, which rebuilds
# every variant locally from the Containerfile: hours of work to reproduce
# images CI has already built and published.
#
# This extracts them from the published images instead. No compiling.
#
# NOTE ON SIZE — this is the UNCOMPRESSED rootfs, ~13.5GB per variant, because
# an overlayfs lower layer must be a real directory tree. That is a different
# and much larger number than the ~5.7GB compressed cost of the same variant in
# the offline INSTALL store (build/fetch-variants.sh). A stick that both
# live-boots and installs every variant needs room for both.
#
# Usage:
#   ./build/export-base-rootfs.sh [VARIANT...]        # default: main nvidia-open
#
#   POWOS_IMAGE=ghcr.io/powback/powos   source repository
#   OUT_DIR=build/output                where base-<v>/ trees are written
#
# Then write them to an already-flashed USB with:
#   sudo ./build/install-to-usb.sh --variants /dev/sdX

set -euo pipefail

cd "$(dirname "$0")/.."

VARIANTS=("$@")
if [[ ${#VARIANTS[@]} -eq 0 ]]; then
    # Deliberately NOT all three by default: each is ~13.5GB unpacked, and the
    # Deck image is normally flashed directly to a Deck rather than carried
    # around for live boot. Pass it explicitly if you want it.
    VARIANTS=(main nvidia-open)
fi
IMAGE="${POWOS_IMAGE:-ghcr.io/powback/powos}"
OUT_DIR="${OUT_DIR:-build/output}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
log()  { echo -e "${CYAN}[base-rootfs]${NC} $*"; }
ok()   { echo -e "${GREEN}[base-rootfs]${NC} $*"; }
warn() { echo -e "${YELLOW}[base-rootfs]${NC} $*" >&2; }
err()  { echo -e "${RED}[base-rootfs]${NC} $*" >&2; }

command -v podman >/dev/null 2>&1 || { err "podman is required."; exit 1; }

mkdir -p "$OUT_DIR"

# Rough free-space guard: each variant needs ~14GB, and running out halfway
# leaves a TRUNCATED rootfs that would look complete and boot into a broken
# system. Refuse up front instead.
need_gb=$(( ${#VARIANTS[@]} * 14 ))
avail_gb=$(df -BG --output=avail "$OUT_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$avail_gb" && "$avail_gb" -lt "$need_gb" ]]; then
    err "need ~${need_gb}GB free for ${#VARIANTS[@]} variant(s); $OUT_DIR has ${avail_gb}GB."
    exit 1
fi

exported=()
for v in "${VARIANTS[@]}"; do
    dest="$OUT_DIR/base-$v"
    log "pulling $IMAGE:$v ..."
    podman pull "$IMAGE:$v" >/dev/null || { warn "pull failed for $v — skipping"; continue; }

    log "exporting rootfs → $dest"
    rm -rf "$dest"; mkdir -p "$dest"
    cid=$(podman create "$IMAGE:$v") || { warn "create failed for $v"; continue; }
    if podman export "$cid" | tar -x -C "$dest"; then
        podman rm "$cid" >/dev/null 2>&1 || true
    else
        warn "export failed for $v"
        podman rm "$cid" >/dev/null 2>&1 || true
        rm -rf "$dest"
        continue
    fi

    # A rootfs missing these is not bootable as an overlay lower layer, and the
    # failure would only show up at boot. Check now, while it is cheap.
    missing=""
    for p in usr/bin/bash usr/lib/systemd/systemd etc; do
        [[ -e "$dest/$p" ]] || missing="$missing $p"
    done
    if [[ -n "$missing" ]]; then
        err "exported rootfs for '$v' is missing:$missing — discarding it."
        rm -rf "$dest"
        continue
    fi

    exported+=("$v")
    ok "base-$v ready ($(du -sh "$dest" 2>/dev/null | cut -f1))"
done

if [[ ${#exported[@]} -eq 0 ]]; then
    err "no variants exported."
    exit 1
fi

echo ""
ok "exported: ${exported[*]}"
echo "  total: $(du -sch "$OUT_DIR"/base-* 2>/dev/null | tail -1 | cut -f1)"
echo ""
echo "Write them onto an already-flashed USB with:"
echo "  sudo ./build/install-to-usb.sh --variants /dev/sdX"
echo ""
echo "At boot the initramfs picks one by GPU auto-detect; the boot menu also"
echo "offers each variant explicitly (rd.powos.variant=<name>)."
