#!/bin/bash
# Fails when the Containerfile's `staging` stage copies a source that targets/android/layer.list
# neither copies (+) nor excludes (-), or when layer.list names a source that no longer exists there.
# Keeps the phone build in step with the desktop/Deck image without touching the Containerfile.
set -euo pipefail
cd "$(dirname "$0")/../.."

# COPY sources of the staging stage: from "FROM scratch AS staging" to the next FROM.
staging=$(awk '/^FROM scratch AS staging/{s=1;next} s&&/^FROM /{exit} s&&/^COPY /{print $2}' Containerfile | sort -u)
listed=$(awk '/^[+-] /{print $2}' targets/android/layer.list | sort -u)

missing=$(comm -23 <(echo "$staging") <(echo "$listed"))
stale=$(comm -13 <(echo "$staging") <(echo "$listed"))
rc=0
if [ -n "$missing" ]; then
  echo "layer.list does not account for these Containerfile staging sources (add as + or - with a reason):"
  echo "$missing" | sed 's/^/  /'
  rc=1
fi
if [ -n "$stale" ]; then
  echo "layer.list names sources the Containerfile staging stage no longer copies:"
  echo "$stale" | sed 's/^/  /'
  rc=1
fi
[ $rc = 0 ] && echo "layer.list in step with Containerfile staging ($(echo "$staging" | wc -l | tr -d ' ') sources)"

# Packages: every package the desktop image installs (dnf in the Containerfiles) must be mapped in
# packages.list (+ installed / ~ provided another way / - left out with a reason).
# The extractor's tokens "qt", "|" and "terra-release{...}" are shell/brace artefacts, not packages.
desktop=$(python3 targets/android/tools/desktop-packages.py . | cut -f1 | grep -vE '^(qt|\||terra-release.*)$' | sort -u)
mapped=$(awk '/^[+~-] / && $2 !~ /^flatpak:/ {print $2}' targets/android/packages.list | sort -u)
pmissing=$(comm -23 <(echo "$desktop") <(echo "$mapped"))
pstale=$(comm -13 <(echo "$desktop") <(echo "$mapped"))
if [ -n "$pmissing" ]; then
  echo "packages.list does not account for these desktop packages (add as +, ~ or - with a reason):"
  echo "$pmissing" | sed 's/^/  /'
  rc=1
fi
if [ -n "$pstale" ]; then
  echo "packages.list maps packages the desktop image no longer installs:"
  echo "$pstale" | sed 's/^/  /'
  rc=1
fi
[ -z "$pmissing$pstale" ] && echo "packages.list in step with the desktop image ($(echo "$desktop" | wc -l | tr -d ' ') packages)"

# Bazzite's default Flatpaks (vendored snapshot, upstream/bazzite-kde-flatpaks.txt; "//branch" dropped).
fp_upstream=$(grep -v '^#' targets/android/upstream/bazzite-kde-flatpaks.txt | sed 's|//.*||' | grep . | sort -u)
fp_mapped=$(awk '/^[+~F-] / && $2 ~ /^flatpak:/ {sub(/^flatpak:/, "", $2); print $2}' targets/android/packages.list | sort -u)
fmissing=$(comm -23 <(echo "$fp_upstream") <(echo "$fp_mapped"))
fstale=$(comm -13 <(echo "$fp_upstream") <(echo "$fp_mapped"))
if [ -n "$fmissing" ]; then
  echo "packages.list does not account for these Bazzite default Flatpaks:"
  echo "$fmissing" | sed 's/^/  /'
  rc=1
fi
if [ -n "$fstale" ]; then
  echo "packages.list maps Flatpaks that are no longer Bazzite defaults:"
  echo "$fstale" | sed 's/^/  /'
  rc=1
fi
[ -z "$fmissing$fstale" ] && echo "packages.list in step with Bazzite's default Flatpaks ($(echo "$fp_upstream" | wc -l | tr -d ' ') apps)"
exit $rc
