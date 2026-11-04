#!/bin/bash
# Publishes our built packages (build-pkgs.sh: out/pkgs) as the [powos] pacman repo in the PowApps store, next
# to the APK and the rootfs: android-app-dev's output/ is served at http://android.pow/apk/, so the repo is at
# http://android.pow/apk/repo (LAN, or the WireGuard VPN with Pi-hole's DNS). The phone's session installs and
# updates them from there on each start (SessionService, step 0b) - no adb, no rootfs rebuild.
#
# Usage: targets/android/publish-repo.sh [store-dir]   (default: ~/Projects/android-app-dev/output)
#        targets/android/publish-repo.sh --remove <name>...   take packages out (files kept in <store>/repo-held)
#        PUBLISH_PKGS=<dir> ...   publish that directory's packages instead of this tree's out/pkgs
# ADDS this tree's packages to the repo (tools/repo-merge.sh): newer versions replace older ones, nothing else in the
# repo is touched, never a downgrade. It used to replace the whole repo with out/pkgs - one agent worktree's
# publish then wiped every package that tree hadn't built (2026-11-04).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" = --remove ]; then
  shift
  STORE=${PUBLISH_STORE:-$HOME/Projects/android-app-dev/output}
  exec docker run --rm --platform linux/arm64 -v "$HERE/tools/repo-merge.sh:/repo-merge.sh:ro" -v "$STORE:/store" \
    menci/archlinuxarm:latest bash /repo-merge.sh /store/repo --remove "$@"
fi
STORE=${1:-$HOME/Projects/android-app-dev/output}
PKGS=$(cd "${PUBLISH_PKGS:-$HERE/out/pkgs}" && pwd)
# Colima shares only $HOME with Docker: a PUBLISH_PKGS under /tmp mounts as an empty dir and published nothing,
# silently ("repo: N packages", 2026-11-04).
case $PKGS/ in "$HOME"/*) ;; *) echo "publish-repo: $PKGS is outside $HOME - Docker (Colima) can't see it; use a dir under $HOME" >&2; exit 2 ;; esac
REPO=$STORE/repo
mkdir -p "$REPO"
docker run --rm --platform linux/arm64 -v "$PKGS:/pkgs:ro" -v "$HERE/tools/repo-merge.sh:/repo-merge.sh:ro" \
  -v "$REPO:/repo" menci/archlinuxarm:latest bash /repo-merge.sh /repo /pkgs
echo "published: $REPO (http://android.pow/apk/repo)"
