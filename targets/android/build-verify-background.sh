#!/bin/bash
# Existing android-app-dev pipeline: versions/signs the standalone verification APK, never installs it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
project=$AAD/projects/powos-verify-background
if [ -e "$project" ] || [ -L "$project" ]; then
  [ "$(readlink "$project")" = "$HERE/verify-background" ] || { echo "Refusing to replace existing project $project" >&2; exit 1; }
else
  ln -s "$HERE/verify-background" "$project"
fi
# Not a public PowApps listing: output remains in the builder's owned private output subtree.
export APK_OUT=${APK_OUT:-$AAD/output/verification}
make -C "$AAD" build PROJECT=powos-verify-background
