#!/bin/bash
# Publishes our built packages (build-pkgs.sh: out/pkgs) as the [powos] pacman repo in the PowApps store, next
# to the APK and the rootfs: android-app-dev's output/ is served at http://android.pow/apk/, so the repo is at
# http://android.pow/apk/repo (LAN, or the WireGuard VPN with Pi-hole's DNS). The phone's session installs and
# updates them from there on each start (SessionService, step 0b) - no adb, no rootfs rebuild.
#
# Usage: targets/android/publish-repo.sh [store-dir]   (default: ~/Projects/android-app-dev/output)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
STORE=${1:-$HOME/Projects/android-app-dev/output}
REPO=$STORE/repo
mkdir -p "$REPO"
# Only the newest build of each package: out/pkgs keeps earlier ones (kwin 3.2 next to 3.3).
docker run --rm --platform linux/arm64 -v "$HERE/out/pkgs:/pkgs:ro" -v "$HERE/tools/newest-pkgs.sh:/newest-pkgs.sh:ro" -v "$REPO:/repo" menci/archlinuxarm:latest bash -c '
  set -euo pipefail
  rm -f /repo/*.pkg.tar.* /repo/powos.*
  /newest-pkgs.sh /pkgs | while read -r f; do cp "$f" /repo/; done
  repo-add -q /repo/powos.db.tar.gz /repo/*.pkg.tar.*
  # nginx serves symlinks as their target only when it can follow them; plain copies are safer.
  for l in powos.db powos.files; do rm -f /repo/$l; cp /repo/$l.tar.gz /repo/$l; done
  ls /repo | wc -l'
echo "published: $REPO (http://android.pow/apk/repo)"
