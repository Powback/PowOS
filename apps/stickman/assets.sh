#!/bin/bash
# The stickman's assets, into ui/ for apps/build.sh to ship with the app (so the widget runs offline):
#   ui/mujoco/   MuJoCo's WebAssembly build (npm @mujoco/mujoco, pinned: the version robotsupremacy's page runs)
#   ui/data/     the model (stickman.xml, meta.json), the brain (brain.json + brain.bin, float32) and the parkour
#                lessons (parkour.json) - from robotsupremacy's export, as http://robotsupremacy.pow/stickman serves it
# A newer brain or courses: run apps/build.sh stickman && apps/install.sh stickman ui again.
#   STICKMAN_SRC   where the export is served (default http://robotsupremacy.pow/stickman)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${STICKMAN_SRC:-http://robotsupremacy.pow/stickman}
MUJOCO=3.16.0
mkdir -p "$HERE/ui/data" "$HERE/ui/mujoco"
# Under the app dir, not mktemp: Docker (Colima) only sees the home folder.
STAGE=$HERE/.stage; rm -rf "$STAGE"; mkdir -p "$STAGE"; trap 'rm -rf "$STAGE"' EXIT
for f in meta.json stickman.xml policy.json lessons.json; do
  curl -fsS --max-time 60 -o "$STAGE/$f" "$SRC/$f" || { echo "assets.sh: can't fetch $SRC/$f" >&2; exit 1; }
done
# The npm tarball (cached in the apps' volume) and the conversion, in node (the build's own container image).
docker run --rm -v powos-apps-cargo:/cache -v "$HERE:/app" -v "$STAGE:/stage" -e MUJOCO=$MUJOCO -e HOST_UID="$(id -u)" node:22 bash -c '
  set -euo pipefail
  P=/cache/npm-mujoco-$MUJOCO
  [ -f $P/package/mujoco.wasm ] || (mkdir -p $P && cd $P && npm pack -s @mujoco/mujoco@$MUJOCO >/dev/null && tar xzf mujoco-mujoco-$MUJOCO.tgz)
  cp $P/package/mujoco.js $P/package/mujoco.wasm /app/ui/mujoco/
  node /app/assets.mjs /stage /app/ui/data
  chown -R $HOST_UID /app/ui/data /app/ui/mujoco'
ls -la "$HERE/ui/data" "$HERE/ui/mujoco"
