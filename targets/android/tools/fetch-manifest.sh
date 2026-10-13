#!/bin/bash
# Fetch the PowOS phone manifest (published by .github/workflows/phone-manifest.yml from the PowOS Deck image):
# a few MB, never the image itself.   Usage: tools/fetch-manifest.sh <outdir> [ref]
set -euo pipefail
out=$1 ref=${2:-ghcr.io/powback/powos-phone:deck}
mkdir -p "$out"
docker run --rm -v "$out:/out" -w /out ghcr.io/oras-project/oras:v1.2.3 pull "$ref" >/dev/null
echo "manifest of $(cat "$out/image.txt"): $(wc -l < "$out/leaves.tsv") top-level packages, $(wc -l < "$out/content.list") content files"
