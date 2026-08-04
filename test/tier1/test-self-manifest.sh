#!/usr/bin/env bash
# test-self-manifest.sh — `powos update self` must live-apply EXACTLY what the
# image ships. Both derive their file map from the Containerfile staging COPY
# lines (self_copy_manifest in lib/self.sh), so they can never drift. This test
# enforces that: every staging COPY is in the manifest, every mapped source
# exists, and the paths that were historically un-live-appliable are covered.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CF="$ROOT/Containerfile"
[ -f "$CF" ] || { echo "FAIL: no Containerfile at $CF"; exit 1; }

# Load just the manifest parser (self.sh is safe to source; it only resolves
# some path vars at top level).
SELF_SRC="$ROOT"
# shellcheck disable=SC1091
source "$ROOT/lib/self.sh" 2>/dev/null || { echo "FAIL: cannot source lib/self.sh"; exit 1; }
declare -f self_copy_manifest >/dev/null || { echo "FAIL: self_copy_manifest not defined"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

echo "== update-self manifest =="

manifest="$(self_copy_manifest "$CF")"
[ -n "$manifest" ] && ok "manifest is non-empty" || bad "manifest is empty"

# 1. Every source in the manifest exists in the tree.
missing=0
while IFS=$'\t' read -r src dst; do
    [ -n "$src" ] || continue
    [ -e "$ROOT/${src%/}" ] || { echo "     missing source: $src"; missing=$((missing+1)); }
done <<< "$manifest"
[ "$missing" -eq 0 ] && ok "every mapped source exists" || bad "$missing mapped source(s) missing"

# 2. Independently extract the staging COPY destinations and confirm the
#    manifest covers each (excluding the deliberately-skipped .snapshot & /tmp).
#    This is the drift guard: a new COPY line that the parser fails to emit fails
#    here.
raw_dsts="$(awk '
    /^FROM[[:space:]]+scratch[[:space:]]+AS[[:space:]]+staging/ { s=1; next }
    /^FROM[[:space:]]/ { s=0 }
    s && /^COPY[[:space:]]/ {
        n=0; delete a
        for (i=2;i<=NF;i++){ if($i ~ /^--/) continue; a[++n]=$i }
        if (n<2) next
        dst=a[n]
        if (dst ~ /^\/tmp\//) next          # build-stage input
        only_snap=1
        for (i=1;i<n;i++) if (a[i] !~ /^\.snapshot/) only_snap=0
        if (only_snap) next                 # source snapshot, intentionally skipped
        print dst
    }' "$CF" | sort -u)"
man_dsts="$(printf '%s\n' "$manifest" | cut -f2 | sort -u)"
uncovered="$(comm -23 <(printf '%s\n' "$raw_dsts") <(printf '%s\n' "$man_dsts"))"
if [ -z "$uncovered" ]; then
    ok "every staging COPY destination is in the manifest"
else
    bad "staging COPY destinations NOT covered by manifest:"; printf '       %s\n' $uncovered
fi

# 3. The regressions that motivated this: these must be live-appliable.
for want in "/etc/profile.d/" "/usr/share/konsole/" "/usr/share/ublue-os/motd/bazzite.md" \
            "/usr/share/plasma/plasmoids/" "/usr/bin/" "/usr/lib/powos/"; do
    if printf '%s\n' "$man_dsts" | grep -qxF "$want"; then ok "covers $want"
    else bad "does NOT cover $want"; fi
done

# 4. Build-only entries must be excluded.
printf '%s\n' "$manifest" | grep -q '\.snapshot' && bad ".snapshot leaked into manifest" || ok ".snapshot excluded"
printf '%s\n' "$manifest" | cut -f2 | grep -q '^/tmp/' && bad "/tmp build path leaked into manifest" || ok "/tmp build paths excluded"

echo
echo "self-manifest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
