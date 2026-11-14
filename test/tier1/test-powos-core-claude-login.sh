#!/usr/bin/env bash
# powos-core carries claude-login (razr 11-14: "claude-login isn't installed"): a phone whose base image predates
# claude-login gets it only from the powos-core package update, so the package itself must hold the /usr/bin wrapper
# and /usr/lib/claude-login's module. Builds the PKGBUILD + sources (POWOS_CORE_STAGE) and runs its package() the way
# makepkg does, then looks at the result.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { echo "  PASS: $*"; pass=$((pass+1)); }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# A claude-login checkout stand-in: dist/ holds its two ES modules.
mkdir -p "$T/cl/dist"; echo 'console.log("cli")' > "$T/cl/dist/cli.js"; echo 'export {}' > "$T/cl/dist/index.js"

out=$(CLAUDE_LOGIN_DIR="$T/cl" CLAUDE_LOGIN_NO_CLONE=1 POWOS_CORE_STAGE="$T/w" "$ROOT/targets/android/build-powos-core.sh" 2>&1) \
  && ok "staged" || bad "build-powos-core.sh didn't stage: $out"

# makepkg: sources extracted into srcdir, package() into pkgdir.
mkdir -p "$T/srcdir" "$T/pkgdir"
tar -C "$T/srcdir" -xf "$T/w/powos-src.tar" 2>/dev/null
[ -f "$T/w/claude-login.tar" ] && tar -C "$T/srcdir" -xf "$T/w/claude-login.tar"
cp "$T/w/phone-files.sh" "$T/srcdir/" 2>/dev/null
# install -Dm ... -t: GNU install (the job image's), as makepkg's.
( srcdir=$T/srcdir pkgdir=$T/pkgdir; . "$T/w/PKGBUILD" && package ) > "$T/pkg.log" 2>&1 || bad "package() failed: $(tail -5 "$T/pkg.log")"

P=$T/pkgdir
[ -x "$P/usr/bin/claude-login" ] && ok "powos-core has /usr/bin/claude-login" || bad "powos-core has no /usr/bin/claude-login"
[ -s "$P/usr/lib/claude-login/cli.js" ] && cmp -s "$P/usr/lib/claude-login/cli.js" "$T/cl/dist/cli.js" \
  && ok "powos-core has /usr/lib/claude-login/cli.js (claude-login's dist)" || bad "powos-core lacks /usr/lib/claude-login/cli.js"
[ -s "$P/usr/lib/claude-login/index.js" ] && ok "powos-core has /usr/lib/claude-login/index.js" || bad "powos-core lacks index.js"
# The wrapper runs the packaged module (node or bun), and says what's wrong when the module is missing.
grep -q '/usr/lib/claude-login/cli.js' "$P/usr/bin/claude-login" 2>/dev/null && ok "wrapper runs /usr/lib/claude-login/cli.js" \
  || bad "wrapper doesn't run /usr/lib/claude-login/cli.js"
grep -q '/usr/lib/powos/ai/manager/fleet_login.py' <(cd "$P" && find . -name fleet_login.py | sed 's@^\.@@') \
  && ok "fleet_login.py (claude-login's caller) is in the same package" || bad "fleet_login.py not packaged"

# No claude-login -> no package (a powos-core without it silently left installed phones without the sign-in).
out=$(CLAUDE_LOGIN_DIR="$T/none" CLAUDE_LOGIN_NO_CLONE=1 POWOS_CORE_STAGE="$T/w2" "$ROOT/targets/android/build-powos-core.sh" 2>&1) \
  && bad "built without claude-login" || ok "refuses to build without claude-login"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
