#!/bin/bash
# The mock home's OWL trees, evaluated from the real widgets by the OWL engine off the phone (`owl trees`, as
# shell/dev/preview.sh does), at the size each one has on the mock home (bridge.ts's items, on the cover screen's
# cells), against the preview's mock data (shell/dev/preview/data/<id>.json) - once per theme, in that theme's
# palette (the APK's own Omarchy themes, targets/android/app/app/src/main/assets/themes/<theme>.toml):
#   shell/dev/sample-trees.sh [theme...]     default: the themes shots.mjs renders (gruvbox kanagawa flexoki-light)
# Out: shell/dev/sample-trees/<theme>.json, each tree set with "_theme": what dev/shots.mjs serves a render in that
# theme (and refuses to render with trees of another: their colours are that theme's, and owl.tsx maps a colour to a
# token only within its own theme - a gruvbox grey in a kanagawa render measured 4.0:1 that the phone doesn't have).
# shell/dev/sample-trees.json is gruvbox's, the plain mock's (a browser on dev/, the gate's pages).
# A tree captured once and kept goes stale (the mock's 3x2 drew a tree laid out for a wider tile): run this after
# changing one of these widgets or adding a theme to shots.mjs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$here/../.." && pwd)
jar=$REPO/targets/android/app/owl/build/cli/owl.jar
[ -f "$jar" ] || { echo "sample-trees: no owl.jar - run shell/dev/preview.sh once (it builds it)" >&2; exit 1; }
A=$REPO/targets/android/app/app/src/main/assets/widgets
TH=$REPO/targets/android/app/app/src/main/assets/themes
D=$here/preview/data
themes=("$@"); [ ${#themes[@]} -gt 0 ] || themes=(gruvbox kanagawa flexoki-light)
W=$(mktemp -d "$HOME/.cache/sample-trees.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$here/sample-trees"
# mock key | widget file | cols rows on the mock home (bridge.ts) | its Canvas's measured size, if it draws one
# (element id w h: the page reports it on the phone; without it a Canvas is evaluated at 100 x 100).
specs='clock.owl 10-today.owl 6 2 -
weather.owl 55-performance.owl 3 2 -
monitor.owl examples/83-owl.owl 4 3 r.0.0:229:162'
jobs=""
for t in "${themes[@]}"; do
  [ -f "$TH/$t.toml" ] || { echo "sample-trees: no theme $t ($TH/$t.toml)" >&2; exit 1; }
  cp "$TH/$t.toml" "$W/$t.toml"
  while read -r key file c r cv; do
    id=$(basename "$file" .owl)
    cp "$A/$file" "$W/$id.owl"
    data=null; [ -f "$D/$id.json" ] && cp "$D/$id.json" "$W/$id.json" && data="\"$W/$id.json\""
    w=$(python3 -c "print(round($c * 63.33 - 8, 1))"); h=$(python3 -c "print(round($r * 68.1 - 8, 1))")
    canvas="{}"; [ "$cv" != "-" ] && canvas="{\"${cv%%:*}\":[$(echo "$cv" | cut -d: -f2),$(echo "$cv" | cut -d: -f3)]}"
    jobs+="${jobs:+,}{\"file\":\"$W/$id.owl\",\"theme\":\"$W/$t.toml\",\"data\":$data,\"live\":false,\"out\":\"$W/$t.$key.json\",\"variants\":[{\"id\":\"$key\",\"cols\":$c,\"rows\":$r,\"w\":$w,\"h\":$h,\"screen\":null,\"canvas\":$canvas}]}"
  done <<< "$specs"
done
echo "[$jobs]" > "$W/batch.json"
docker run --rm -v "$W:$W" -v "$jar:/owl.jar:ro" --entrypoint java "${PREVIEW_JVM_IMAGE:-android-app-dev-android-builder:latest}" \
  -jar /owl.jar trees --batch "$W/batch.json" >/dev/null
python3 - "$W" "$here" "${themes[@]}" <<'PY'
import json, sys, glob, os
w, here, themes = sys.argv[1], sys.argv[2], sys.argv[3:]
for t in themes:
    trees = {"_theme": t}
    for f in sorted(glob.glob(os.path.join(w, f"{t}.*.owl.json"))):
        key = os.path.basename(f)[len(t) + 1 : -len(".json")]
        d = json.load(open(f))
        if d.get("errors"): print(f"sample-trees: {t} {key}: {d['errors']}", file=sys.stderr)
        if d.get(key): trees[key] = d[key]
    out = os.path.join(here, "sample-trees", f"{t}.json")
    json.dump(trees, open(out, "w"), separators=(", ", ": "))
    if t == "gruvbox": json.dump(trees, open(os.path.join(here, "sample-trees.json"), "w"), separators=(", ", ": "))
    print(f"sample-trees: {t}: {', '.join(k for k in trees if k != '_theme')} -> {out}")
PY
