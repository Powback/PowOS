#!/usr/bin/env bash
# vendor-bazzite.sh — fetch upstream ublue-os/bazzite into ./bazzite so the
# Containerfile's `COPY bazzite/system_files/` step has its source.
#
# Why this exists: bazzite/ is an EXTERNAL repo (gitignored, not committed).
# The image build copies `bazzite/system_files/` and the handheld device
# overlays (sources/device-{steamdeck,rog-ally,legion-go}) read udev rules from
# /tmp/bazzite/system_files/. Without this, a fresh checkout can't build.
#
# Idempotent — safe to run repeatedly, locally or in CI.
#
#   BAZZITE_REPO  upstream URL           (default: https://github.com/ublue-os/bazzite)
#   BAZZITE_REF   branch or tag to vendor (default: main)
set -euo pipefail

REPO="${BAZZITE_REPO:-https://github.com/ublue-os/bazzite}"
REF="${BAZZITE_REF:-main}"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bazzite"

if [[ -d "$DEST/.git" ]]; then
    echo "[vendor-bazzite] updating $DEST -> $REF"
    git -C "$DEST" fetch --depth 1 origin "$REF"
    git -C "$DEST" checkout --force FETCH_HEAD
else
    echo "[vendor-bazzite] cloning $REPO@$REF -> $DEST"
    rm -rf "$DEST"
    git clone --depth 1 --branch "$REF" "$REPO" "$DEST"
fi

# The Containerfile COPYs this exact path — fail loudly if it's absent.
if [[ ! -d "$DEST/system_files" ]]; then
    echo "[vendor-bazzite] ERROR: $DEST/system_files missing after vendor" >&2
    exit 1
fi

echo "[vendor-bazzite] ready: $(git -C "$DEST" rev-parse --short HEAD) ($REF)"
