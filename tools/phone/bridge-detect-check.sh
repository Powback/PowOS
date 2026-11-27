#!/bin/bash
# f307 guard: a shell change can go live before the APK it needs (the shell ships in seconds, the APK waits for a
# locked screen). Flags every bridge method shell/bridge.ts calls that the INSTALLED APK's ShellBridge.kt doesn't
# dispatch, unless its line in bridge.ts says `// detect` (its callers feature-detect: catch the "no such call"
# rejection and fall back). An unmarked new method makes the old APK reject it for every user action.
#   tools/phone/bridge-detect-check.sh [TIP_REF [INSTALLED_REF]]
#     TIP_REF        the shell to check (default HEAD)
#     INSTALLED_REF  the installed APK's commit (default ~/.cache/powos-installed-commit; none = nothing to compare, ok)
# Exit 0: ok. 1: unmarked methods (listed with the fix). 2: the check itself broke (never read as "ok"). Run by the ship service before each shell push (it mails
# the coder and still ships unless SHIP_BRIDGE_STRICT=1 - a flagged push is a bug to fix, not a reason to stall).
set -uo pipefail
tip=${1:-HEAD}; inst=${2:-$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)}
[ -n "$inst" ] && git cat-file -e "$inst^{commit}" 2>/dev/null || { echo "bridge-detect: no installed APK commit - nothing to compare"; exit 0; }
# Every dotted string literal in the installed APK's Kotlin (the dispatcher, and the areas it hands a whole prefix to:
# "glasses.", "remote.") - a method counts as present when it, or its area's "area." prefix, is there.
have=$(git archive "$inst" targets/android/app/app/src/main/kotlin 2>/dev/null | tar -xO 2>/dev/null | grep -oE '"[a-zA-Z]+\.([a-zA-Z.]*)"' | tr -d '"' | sort -u)
[ -n "$have" ] || { echo "bridge-detect: the installed APK's Kotlin has no methods (moved?) - skipped"; exit 0; }
# One awk pass with the APK's methods as a set. Never a per-method `printf "$have" | grep -qx` (11-27): grep -q exits
# on its first match, the writer (bash 3.2's printf flushes in chunks) takes SIGPIPE, and under pipefail the pipeline
# returns 141 - methods the APK has (chrome.ready, apps.list, theme.get ...) were reported missing at random.
# Per call line in bridge.ts: its first ("area.method" literal; present when it, or its "area." prefix, is in the APK;
# `// detect` (callers feature-detect) and `// host: panel` (only the Qt desktop host, powos-shell, serves it) skip.
bad=$(git show "$tip:shell/bridge.ts" 2>/dev/null | awk '
  NR == FNR { ok[$0] = 1; next }   # first file: the APK methods, one per line
  /call/ && match($0, /\("[a-zA-Z]+\.[a-zA-Z.]+"/) {
    m = substr($0, RSTART + 2, RLENGTH - 3); area = m; sub(/\..*/, ".", area)
    if ((m in ok) || (area in ok) || index($0, "// detect") || index($0, "// host: panel")) next
    print "  " m
  }' <(printf '%s\n' "$have") -) || { echo "bridge-detect: the check itself failed (awk/git) - fix tools/phone/bridge-detect-check.sh" >&2; exit 2; }
[ -z "$bad" ] || bad="$bad"$'\n'
if [ -n "$bad" ]; then
  printf 'bridge-detect: shell/bridge.ts calls methods the installed APK (%s) lacks, without a feature-detect:\n%s' "${inst:0:9}" "$bad" >&2
  echo "  fix: guard every caller (.catch the rejection / check capability) and put \`// detect\` on that call line in bridge.ts" >&2
  exit 1
fi
echo "bridge-detect: ok (every bridge method is in the installed APK or marked // detect)"
