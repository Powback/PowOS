#!/bin/bash
# The complexity lint for the Kotlin app (targets/android/app: app/src, owl, engine): detekt with only the complexity
# rules (app/config/detekt-complexity.yml) - per function cyclomatic 10, cognitive 10, nesting depth 3, 60 lines,
# 4 parameters, the same limits as the shell's TypeScript.
#
# Runs inside android-app-dev's builder image (its Java), with detekt's CLI jar fetched once into
# ~/.cache/powos-lint (pinned version, sha256-checked) - nothing installed on the host. The CLI rather than the Gradle
# plugin: detekt 1.23's plugin refuses Kotlin 2.4 on the build's classpath; the CLI only parses the sources.
#
# Old debt: app/config/detekt-baseline.xml (detekt's own baseline, one id per function). It only shrinks:
#   - a function over the limits that isn't in it fails;
#   - an id no longer needed fails until --prune rewrites the file (commit it with the refactor);
#   - an id not in HEAD's baseline fails (no re-baselining past the limits; tier-1 checks history too).
#
#   targets/android/lint-complexity.sh [--prune] [--report N] [--only a.kt,b.kt]
# --only: just those files (paths relative to targets/android/app; ~4 s instead of ~10), stale ids only theirs - the
# pre-push hook's mode (tools/git-hooks/pre-push).
# Exit 0 clean, 1 findings or couldn't run (fail closed), 2 only when skipped on purpose (GATE_LINT=0).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$HERE/app
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
VER=1.23.8
SHA=3afe89a11120303c73c9bdda3d8fe558dd9070a6937d27819ddc04b275381245
IMAGE=${LINT_IMAGE:-android-app-dev-android-builder:latest}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/powos-lint
JAR=$CACHE/detekt-cli-$VER-all.jar
CFG=config/detekt-complexity.yml
BASE=config/detekt-baseline.xml
prune="" report="" only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prune) prune=1; shift ;;
    --report) report=$2; shift 2 ;;
    --only) only=$2; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
done
# Fail closed: a missing tool fails the lint; only GATE_LINT=0 skips it (exit 2), explicitly.
if [ "${GATE_LINT:-1}" = 0 ]; then echo "     kotlin complexity: skipped (GATE_LINT=0)"; exit 2; fi
command -v docker >/dev/null || { echo "FAIL kotlin complexity: no docker (GATE_LINT=0 skips it explicitly)"; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "FAIL kotlin complexity: no $IMAGE (build android-app-dev's builder; GATE_LINT=0 skips)"; exit 1; }
if [ ! -f "$JAR" ]; then
  mkdir -p "$CACHE"
  # DETEKT_MIRROR: another Maven repo (tier-1 points it at nothing to prove a failed fetch fails the lint).
  curl -sfL --max-time 120 -o "$JAR.part" "${DETEKT_MIRROR:-https://repo1.maven.org/maven2}/io/gitlab/arturbosch/detekt/detekt-cli/$VER/detekt-cli-$VER-all.jar" \
    || { echo "FAIL kotlin complexity: couldn't fetch detekt $VER (GATE_LINT=0 skips it explicitly)"; exit 1; }
  [ "$(shasum -a 256 "$JAR.part" | cut -d' ' -f1)" = "$SHA" ] || { rm -f "$JAR.part"; echo "FAIL kotlin complexity: detekt jar checksum mismatch"; exit 1; }
  mv "$JAR.part" "$JAR"
fi
out=$(mktemp -d "$CACHE/run.XXXXXX"); trap 'rm -rf "$out"' EXIT
inputs=app/src/main,owl/src/main
[ -d "$APP/engine" ] && inputs+=,engine
# --only paths may be relative to targets/android/app (the hook's form), repo-relative, or absolute (f294: only the
# first form matched, the others said "nothing to lint"): normalize all to app-relative.
if [ -n "$only" ]; then
  norm=""
  for f in $(echo "$only" | tr ',' ' '); do
    f=${f#"$APP"/}; f=${f#"$ROOT"/}; f=${f#targets/android/app/}; f=${f#./}
    norm+="${norm:+,}$f"
  done
  only=$norm; inputs=$only
fi
detekt() {
  docker run --rm -v "$CACHE:/lint:ro" -v "$APP:/src:ro" -v "$out:/out" -w /src --entrypoint java "$IMAGE" \
    -jar "/lint/$(basename "$JAR")" --input "$inputs" --config "$CFG" --excludes '**/build/**,**/test/**' "$@"
}

if [ -n "$report" ]; then
  detekt --report txt:/out/r.txt >/dev/null 2>&1
  python3 - "$out/r.txt" "$report" <<'PY'
import re, sys
rows, by = {}, {}
for l in open(sys.argv[1]):
    m = re.match(r"(\w+) - (\d+)/\d+ - \[([^\]]+)\] at /src/(\S+?):(\d+)", l)
    if not m: continue
    rule, n, fn, path, line = m.group(1), int(m.group(2)), m.group(3), m.group(4), m.group(5)
    by[rule] = by.get(rule, 0) + 1
    e = rows.setdefault((path, fn), {"cog": 0, "cc": 0, "line": line})
    if rule == "CognitiveComplexMethod": e["cog"] = n
    if rule == "CyclomaticComplexMethod": e["cc"] = n
print(f"functions over a limit: {len(rows)}  (" + ", ".join(f"{k} {v}" for k, v in sorted(by.items())) + ")")
for (p, fn), e in sorted(rows.items(), key=lambda kv: (-kv[1]["cog"], -kv[1]["cc"]))[:int(sys.argv[2])]:
    print(f"{e['cog']:4} {e['cc']:4} targets/android/app/{p}:{e['line']} {fn}")
PY
  exit 0
fi

# 1. The baseline never gains an id over HEAD's.
if git -C "$ROOT" cat-file -e "HEAD:targets/android/app/$BASE" 2>/dev/null && [ -f "$APP/$BASE" ]; then
  ids() { sed -n 's|.*<ID>\(.*\)</ID>.*|\1|p' | sort -u; }
  grew=$(comm -13 <(git -C "$ROOT" show "HEAD:targets/android/app/$BASE" | ids) <(ids < "$APP/$BASE"))
  [ -z "$grew" ] || { echo "$grew" | head -20 | sed 's/^/FAIL kotlin complexity baseline grew (it only shrinks): /'; exit 1; }
fi
# 2. detekt against the baseline. Stale ids: detekt doesn't report them, so compare with a fresh baseline.
rc=0; detekt --create-baseline --baseline /out/now.xml >"$out/run.log" 2>&1 || rc=$?
# --only on files with no finding at all: detekt ran fine but writes no baseline.
[ -n "$only" ] && [ $rc = 0 ] && [ ! -s "$out/now.xml" ] && grep -q 'number of kt files' "$out/run.log" && echo '<SmellBaseline/>' >"$out/now.xml"
[ -s "$out/now.xml" ] || { echo "FAIL kotlin complexity: detekt didn't run"; tail -5 "$out/run.log"; exit 1; }
ids() { sed -n 's|.*<ID>\(.*\)</ID>.*|\1|p' | sort -u; }
new=$(comm -13 <(ids < "$APP/$BASE") <(ids < "$out/now.xml"))
stale=$(comm -23 <(ids < "$APP/$BASE") <(ids < "$out/now.xml"))
# --only: an id is stale only if it names one of the linted files (Rule:File.kt$...); the rest weren't looked at.
if [ -n "$only" ] && [ -n "$stale" ]; then
  names=$(echo "$only" | tr ',' '\n' | sed 's|.*/||')
  stale=$(echo "$stale" | awk -F'[:$]' 'NR==FNR{n[$0]=1; next} ($2 in n)' <(echo "$names") -)
fi
if [ -n "$prune" ] && [ -n "$stale" ]; then
  python3 - "$APP/$BASE" "$stale" <<'PY'
import sys
path, stale = sys.argv[1], set(sys.argv[2].split("\n"))
lines = [l for l in open(path) if not any(f"<ID>{s}</ID>" in l for s in stale if s)]
open(path, "w").writelines(lines)
PY
  echo "     kotlin complexity: pruned $(echo "$stale" | grep -c .) baseline id(s) - commit $BASE"
  stale=""
fi
[ -z "$new$stale" ] && { echo "ok   kotlin complexity lint"; exit 0; }
[ -n "$new" ] && echo "$new" | head -30 | sed 's/^/FAIL kotlin complexity (new): /'
[ -n "$stale" ] && echo "$stale" | head -20 | sed 's/^/FAIL kotlin complexity (paid off - prune it): /'
echo "FAIL kotlin complexity: limits per function - cyclomatic 10, cognitive 10, depth 3, 60 lines, 4 params ($CFG)."
echo "FAIL kotlin complexity: split the function; paid-off debt: targets/android/lint-complexity.sh --prune, commit the baseline."
exit 1
