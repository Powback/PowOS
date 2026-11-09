#!/bin/bash
# Publishes this tree's web shell (shell/, as the APK ships it: build.gradle.kts copyShell's excludes) to the PowApps
# store as a pull update for phones that no adb reaches (docs/PHONE-UPDATES.md): android-app-dev's output/ is served at
# http://android.pow/apk/ (LAN, or the WireGuard VPN with Pi-hole's DNS; never a public route), so the app finds
#   powos-shell.json         {"stamp":"<commit time> <commit>","file":"powos-shell/<sha12>.zip","sha256":..,"size":..,"apk":N}
#   powos-shell/<sha12>.zip  the shell's files
# and applies it as a push would (dev.omalauncher.upgrade.PowosUpdates -> ShellSource's layer). "apk" is the store's
# APK version at publish time: a phone on an older APK takes that APK first (the shell may call its new native parts).
#
# Usage: targets/android/publish-shell.sh [store-dir]   (default: ~/Projects/android-app-dev/output)
# Only origin's history: a commit not on origin/worktree-powos-multiplatform (an agent's branch) is never published,
# and never one older than what the store has (the commit time decides, as ShellSource's does). Run by build-app.sh
# after each APK it publishes and by the ship service after a shell ship (tools/phone/ship.sh).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
STORE=${1:-${PUBLISH_STORE:-$HOME/Projects/android-app-dev/output}}
BASE=${POWOS_BASE_BRANCH:-worktree-powos-multiplatform}
[ -d "$STORE" ] || { echo "publish-shell: no store at $STORE" >&2; exit 2; }
rev=$(git -C "$ROOT" rev-parse HEAD)
if [ -z "${PUBLISH_ANY_COMMIT:-}" ] && ! git -C "$ROOT" merge-base --is-ancestor HEAD "origin/$BASE" 2>/dev/null; then
  echo "publish-shell: skipped - ${rev:0:9} isn't on origin/$BASE (only origin's history reaches phones)"
  exit 0
fi
ct=$(git -C "$ROOT" log -1 --format=%ct HEAD)
manifest=$STORE/powos-shell.json
have=$( { sed -n 's/.*"stamp":"\([0-9]*\) .*/\1/p' "$manifest" 2>/dev/null || true; } | head -1)
if [ -n "$have" ] && [ "$have" -ge "$ct" ]; then
  echo "publish-shell: the store's shell ($have) is as new as ${rev:0:9} ($ct) - nothing to do"
  exit 0
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/powos-shell.XXXXXX")
trap 'rm -rf "$W"' EXIT
# The committed files only (git archive): exactly the commit the stamp names.
mkdir -p "$W/src" && git -C "$ROOT" archive HEAD shell | tar -x -C "$W/src"
# Links in shell/ (fonts/nerd_symbols.ttf -> the app's res/font) as the files they point at, as Gradle's copy has them.
for l in $(cd "$W/src" && find shell -type l); do
  t=$(cd "$ROOT/$(dirname "$l")" && git ls-files --full-name -- "$(git -C "$ROOT" show "HEAD:$l")" 2>/dev/null)
  [ -n "$t" ] || { echo "publish-shell: $l points outside the tree" >&2; exit 1; }
  rm "$W/src/$l" && git -C "$ROOT" show "HEAD:$t" > "$W/src/$l"
done
mv "$W/src/shell" "$W/shell"
(cd "$W/shell" && rm -rf DESIGN.md dev push.sh node_modules package.json package-lock.json tsconfig.json .gitignore)
name=${rev:0:12}.zip
mkdir -p "$STORE/powos-shell"
(cd "$W/shell" && find . -exec touch -t 202601010000 {} + && find . -type f | LC_ALL=C sort | zip -qX -@ "$W/$name")
sum=$(shasum -a 256 "$W/$name" | cut -d' ' -f1)
size=$(wc -c < "$W/$name" | tr -d ' ')
apk=$(tr -dc '0-9' < "$STORE/powos.ver" 2>/dev/null || true)
mv "$W/$name" "$STORE/powos-shell/$name.part" && mv "$STORE/powos-shell/$name.part" "$STORE/powos-shell/$name"
printf '{"stamp":"%s %s","file":"powos-shell/%s","sha256":"%s","size":%s,"apk":%s}\n' "$ct" "$rev" "$name" "$sum" "$size" "${apk:-0}" > "$manifest.part"
mv "$manifest.part" "$manifest"
# The three newest bundles stay (a phone mid-download keeps its file); older ones go.
ls -t "$STORE/powos-shell/"*.zip 2>/dev/null | tail -n +4 | xargs rm -f
echo "published: http://android.pow/apk/powos-shell.json (${rev:0:9}, $size bytes, needs APK ${apk:-any})"
