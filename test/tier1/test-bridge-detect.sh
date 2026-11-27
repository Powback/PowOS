#!/bin/bash
# test-bridge-detect.sh - runs tools/phone/bridge-detect-check.sh against a throwaway repo: an "installed APK" commit
# whose ShellBridge.kt dispatches methods in every form the real one uses, and a tip whose shell/bridge.ts calls them.
#
# The bug (11-27): the check reported methods the APK DOES handle (chrome.ready, `"chrome.ready" ->
# requireNotNull(chrome) { ... }.ready()`; then apps.list, theme.get, ... at random) as missing. Cause: the lookup
# was `printf "$have" | grep -qx` under pipefail - grep -q exits on its first match, the writer takes SIGPIPE, the
# pipeline returns 141. So this test makes the APK's method list large (thousands of literals) and runs the check
# several times: a present method must never be flagged, a genuinely missing one must always be.
#
# Usage:  bash test/tier1/test-bridge-detect.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHECK="${BRIDGE_DETECT_CHECK:-$ROOT/tools/phone/bridge-detect-check.sh}"   # override: run it against another copy

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/bridge-detect-test.XXXXXX"); trap '[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig
mkdir -p "$HOME"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
cd "$T" && git init -q repo && cd repo || exit 1

K=targets/android/app/app/src/main/kotlin/dev/omalauncher/shell
mkdir -p "$K" shell
W='function w(n,  s, i) { s = ""; for (i = 1; i <= length(n); i++) s = s substr("abcdefghij", substr(n, i, 1) + 1, 1); return s }'
{
  cat <<'EOF'
package dev.omalauncher.shell
class ShellBridge {
    fun dispatch(method: String, args: JSONArray): Any? = when (method) {
            "apps.list" -> apps()
            "chrome.ready" -> requireNotNull(chrome) { "not a chrome page" }.ready()
            "theme.get" -> theme()
            "term.pasteText", "term.paste" -> term.pasteText(args.getString(0), args.getString(1))
            else -> when {
                method.startsWith("glasses.") -> glasses.call(method, args)
                else -> throw IllegalArgumentException("no such call: $method")
            }
    }
EOF
  # Thousands of other methods, so the list the check builds is far bigger than one pipe write. Letters only (digits
  # spelled a-j): the check, like the real bridge, only reads [a-zA-Z] method names.
  seq 1 3000 | awk '{ print "            \"area" w($1) ".method" w($1) "\" -> x()" } '"$W"
  echo '}'
} > "$K/ShellBridge.kt"
echo 'export const x = 1' > shell/bridge.ts
git add -A && git commit -qm installed && inst=$(git rev-parse HEAD)

cat > shell/bridge.ts <<'EOF'
export const bridge = {
  apps: { list: () => call<App[]>("apps.list") },
  chrome: { ready: () => call("chrome.ready") },
  theme: { get: () => call<ThemeColors>("theme.get") },
  term: { pasteText: (id, text) => call("term.pasteText", id, text) },
  glasses: { forget: () => call<GlassesState>("glasses.forget") },
  early: { m: () => call("areab.methodb") },
  late: { m: () => call("areadaaa.methoddaaa") },
  probe: { m: () => call("newarea.probe") }, // detect
  panel: { m: () => call("panel.taskbar") }, // host: panel
};
EOF
# ...and hundreds of handled calls: the old lookup failed ~1 in 5 lookups, so this flags something on nearly every run.
seq 1 3000 | awk 'NR % 10 == 1 { print "export const a" $1 " = () => call(\"area" w($1) ".method" w($1) "\");" } '"$W" >> shell/bridge.ts
git add -A && git commit -qm tip

# 1. Every method the APK handles (each dispatch form, an area prefix, a // detect, a // host: panel): ok, every run.
flaky=0
for i in 1 2 3 4 5 6 7 8; do
  out=$(bash "$CHECK" HEAD "$inst" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { flaky=1; break; }
done
if [ "$flaky" -eq 0 ]; then ok "handled methods (incl. requireNotNull-bodied chrome.ready) pass on 8/8 runs"
else bad "handled methods flagged on run $i (rc=$rc)" "$(echo "$out" | tr '\n' ' ')"; fi

# 2. A genuinely missing, unmarked method is caught - and is the only one listed.
echo 'export const missing = () => call("apps.notThere");' >> shell/bridge.ts
git commit -qam missing
for i in 1 2 3 4 5; do
  out=$(bash "$CHECK" HEAD "$inst" 2>&1); rc=$?
  listed=$(echo "$out" | grep -E '^  [a-zA-Z]+\.' | tr -d ' ' | tr '\n' ' ')
  [ "$rc" -eq 1 ] && [ "$listed" = "apps.notThere " ] || break
done
if [ "$rc" -eq 1 ] && [ "$listed" = "apps.notThere " ]; then ok "missing apps.notThere is flagged, alone, on 5/5 runs"
else bad "missing method: rc=$rc, listed='$listed'" "$(echo "$out" | tr '\n' ' ')"; fi

# 3. No installed commit known: nothing to compare, ok.
out=$(bash "$CHECK" HEAD "" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "no installed APK commit -> ok" || bad "no installed commit: rc=$rc" "$out"

echo "bridge-detect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
