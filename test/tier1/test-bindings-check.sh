#!/bin/bash
# test-bindings-check.sh - tools/phone/bindings-check.sh against fake phone schemas (no phone): the shell's vendored
# bindings matching, AHEAD of the module (published when this commit's module builds them, else refused with the fix),
# and of another shape (refused). Home couldn't decode local-pet's rows twice on 2026-10-21 (overlay, goto_*): the
# shell shipped bindings the phone's module didn't have.
# Usage:  bash test/tier1/test-bindings-check.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK=$ROOT/tools/phone/bindings-check.sh
PASS=0; FAIL=0
ok()  { echo "ok   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && echo "     $2"; FAIL=$((FAIL+1)); }
command -v node >/dev/null || { echo "skip: no node"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# The phone's schemas as the bindings describe them (the server's JSON shape: tables + typespace), through the same SDK.
sed 's/from"spacetimedb"/from".\/spacetimedb.js"/g' "$ROOT/shell/vendor/local-pet.js" > "$T/local-pet.mjs"
cp "$ROOT/shell/vendor/spacetimedb.js" "$T/"
fake() { # fake <out> <js transforming `cols` of table pet>
  (cd "$T" && node --input-type=module -e "
    const dbs = $(sed -n 's|^\([a-z0-9-]*\)\.js  *generated .*|\1|p' "$ROOT/shell/vendor/VERSIONS" | sed 's/.*/"&"/' | paste -sd, - | sed 's/^/[/; s/$/]/');
    const { DbConnection } = await import('./local-pet.mjs');
    const types = [], tables = [];
    for (const t of Object.values(DbConnection.builder().remoteModule.tables)) {
      let cols = Object.entries(t.columns).map(([k, c]) => c.columnMetadata?.name ?? k);
      if (t.sourceName === 'pet') cols = ($2)(cols);
      tables.push({ name: t.sourceName, product_type_ref: types.length });
      types.push({ Product: { elements: cols.map((n) => ({ name: { some: n }, algebraic_type: { String: [] } })) } });
    }
    let out = '';
    for (const d of dbs) out += '@@' + d + '\n' + (d === 'local-pet' ? JSON.stringify({ typespace: { types }, tables }) : '\`' + d + '\` not found') + '\n';
    process.stdout.write(out);" > "$1")
}
# The other databases come back "not found" (absent: not checked), so each case is about local-pet alone.
fake "$T/same" "(c) => c"
fake "$T/ahead" "(c) => c.slice(0, -1)"
fake "$T/differs" "(c) => [...c, 'extra']"
export BINDINGS_PUBLISH="$T/publish" BINDINGS_ADB=false
printf '#!/bin/bash\necho "$@" > %s/published\n' "$T" > "$T/publish"; chmod +x "$T/publish"
printf '#!/bin/bash\ncp %s "$3"\n' "$ROOT/shell/vendor/local-pet.js" > "$T/vendor-same"
printf '#!/bin/bash\necho "// another build" > "$3"\n' > "$T/vendor-other"
chmod +x "$T/vendor-same" "$T/vendor-other"

out=$("$CHECK" --schemas "$T/same" 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q "local-pet matches the phone" && ok "matching bindings pass" || bad "matching bindings pass" "rc=$rc $out"

rm -f "$T/published"
out=$(BINDINGS_VENDOR="$T/vendor-same" "$CHECK" --schemas "$T/ahead" 2>&1); rc=$?
[ $rc = 0 ] && grep -q "^pet publish" "$T/published" 2>/dev/null && ok "ahead + this commit's module builds them: published" ||
  bad "ahead + this commit's module builds them: published" "rc=$rc $out"

rm -f "$T/published"
out=$(BINDINGS_VENDOR="$T/vendor-other" "$CHECK" --schemas "$T/ahead" 2>&1); rc=$?
[ $rc = 1 ] && [ ! -f "$T/published" ] && echo "$out" | grep -q "fix: apps/vendor.sh pet" && ok "ahead + the module builds other bindings: refused with the fix" ||
  bad "ahead + the module builds other bindings: refused with the fix" "rc=$rc $out"

rm -f "$T/published"
out=$(BINDINGS_VENDOR="$T/vendor-same" "$CHECK" --schemas "$T/ahead" --no-publish 2>&1); rc=$?
[ $rc = 1 ] && [ ! -f "$T/published" ] && echo "$out" | grep -q "fix: apps/install.sh pet publish" && ok "--no-publish: refused with the publish command" ||
  bad "--no-publish: refused with the publish command" "rc=$rc $out"

rm -f "$T/published"
out=$(BINDINGS_VENDOR="$T/vendor-same" "$CHECK" --schemas "$T/differs" 2>&1); rc=$?
[ $rc = 1 ] && [ ! -f "$T/published" ] && echo "$out" | grep -q "pet: bindings .*; phone .*extra" && ok "another shape (the phone's module newer): refused, never published" ||
  bad "another shape (the phone's module newer): refused, never published" "rc=$rc $out"

echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
