#!/bin/bash
# The mock home's OWL trees (shell/dev/sample-trees.json, which the mock bridge serves for its widgets: bridge.ts
# mockWidgets), evaluated again from the real widgets by the OWL engine off the phone (`owl trees`, as
# shell/dev/preview.sh does), at the size each one has on the mock home (bridge.ts's items, on the cover screen's
# cells), against the preview's mock data (shell/dev/preview/data/<id>.json), in the user's theme (gruvbox).
#   shell/dev/sample-trees.sh            rewrites shell/dev/sample-trees.json
# A tree captured once and kept goes stale: the mock's 3x2 drew a tree laid out for a wider tile, its labels on top of
# each other (and design QA measured them against the wallpaper). Run this after changing one of these widgets.
# The rest of the file is kept as it is: monitor.owl (83-owl) draws a Canvas whose ops need the measured size, which
# only the preview's measure pass gives (a tree evaluated here draws it at a default 100 px).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$here/../.." && pwd)
jar=$REPO/targets/android/app/owl/build/cli/owl.jar
[ -f "$jar" ] || { echo "sample-trees: no owl.jar - run shell/dev/preview.sh once (it builds it)" >&2; exit 1; }
A=$REPO/targets/android/app/app/src/main/assets/widgets
D=$here/preview/data
W=$(mktemp -d "$HOME/.cache/sample-trees.XXXXXX"); trap 'rm -rf "$W"' EXIT
cp "$here/preview/themes/gruvbox.toml" "$W/theme.toml"
# mock key | widget file | cols x rows on the mock home (bridge.ts) - the cover's cell is 63.33 x 68.1 px less 8 gap.
jobs=""
while read -r key file c r; do
  id=$(basename "$file" .owl)
  cp "$A/$file" "$W/$id.owl"
  data=null; [ -f "$D/$id.json" ] && cp "$D/$id.json" "$W/$id.json" && data="\"$W/$id.json\""
  w=$(python3 -c "print(round($c * 63.33 - 8, 1))"); h=$(python3 -c "print(round($r * 68.1 - 8, 1))")
  jobs+="${jobs:+,}{\"file\":\"$W/$id.owl\",\"theme\":\"$W/theme.toml\",\"data\":$data,\"live\":false,\"out\":\"$W/$key.json\",\"variants\":[{\"id\":\"$key\",\"cols\":$c,\"rows\":$r,\"w\":$w,\"h\":$h,\"screen\":null,\"canvas\":{}}]}"
done <<'EOF'
clock.owl 10-today.owl 6 2
weather.owl 55-performance.owl 3 2
EOF
echo "[$jobs]" > "$W/batch.json"
docker run --rm -v "$W:$W" -v "$jar:/owl.jar:ro" --entrypoint java "${PREVIEW_JVM_IMAGE:-android-app-dev-android-builder:latest}" \
  -jar /owl.jar trees --batch "$W/batch.json" >/dev/null
python3 - "$W" "$here/sample-trees.json" <<'PY'
import json, sys, glob, os
w, out = sys.argv[1], sys.argv[2]
trees = json.load(open(out)) if os.path.exists(out) else {}
for f in sorted(glob.glob(os.path.join(w, "*.owl.json"))):
    key = os.path.basename(f)[: -len(".json")]
    d = json.load(open(f))
    if d.get("errors"): print(f"sample-trees: {key}: {d['errors']}", file=sys.stderr)
    if d.get(key): trees[key] = d[key]
json.dump(trees, open(out, "w"), separators=(", ", ": "))
print(f"sample-trees: {', '.join(trees)} -> {out}")
PY
