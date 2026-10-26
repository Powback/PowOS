#!/bin/bash
# test-appdata-guard.sh - nothing in the tree wipes the PowOS app's data unbacked (docs/APP-DATA-BACKUP.md).
#
# `pm uninstall-system-updates com.powos.app` deletes /data/data/com.powos.app with the /data APK. On 2026-10-20 a
# runner did that at night and the home layout, widgets, installed apps, chat and mail were gone with no copy. The
# only code allowed to run it is targets/android/rooted/powos-appdata.sh (`rebase`: backup, refuse without one,
# restore after). Same for `pm clear` of the app. Comments and docs may mention them; commands may not.
#
# Usage:  bash test/tier1/test-appdata-guard.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
GUARD=targets/android/rooted/powos-appdata.sh

if ! git rev-parse --git-dir >/dev/null 2>&1; then echo "  skip - not a git checkout"; exit 0; fi

# Code lines (not comments, not docs) that run an app-data-wiping pm command.
hits=$(git grep -nE 'uninstall-system-updates|pm clear( |$)' -- ':!*.md' ':!*.html' ':!*.txt' ':!test/tier1/test-appdata-guard.sh' \
  ":!$GUARD" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//|\*)' || true)
if [ -z "$hits" ]; then ok "no uninstall-system-updates / pm clear outside $GUARD"
else bad "app-data-wiping pm command outside $GUARD (use powos-appdata.sh rebase):"; echo "$hits" | sed 's/^/         /'; fi

grep -q 'pm uninstall-system-updates' "$GUARD" && ok "$GUARD does the re-base" || bad "$GUARD lost its rebase"
# rebase: the backup comes before the uninstall, and a failed/unusable backup refuses (exit 3).
awk '/^rebase\(\)/,/^}/' "$GUARD" > /tmp/appdata-rebase.$$
b=$(grep -n 'backup rebase' /tmp/appdata-rebase.$$ | head -1 | cut -d: -f1)
u=$(grep -n 'pm uninstall-system-updates' /tmp/appdata-rebase.$$ | head -1 | cut -d: -f1)
[ -n "$b" ] && [ -n "$u" ] && [ "$b" -lt "$u" ] && ok "rebase backs up before uninstalling" || bad "rebase must back up before uninstalling"
grep -q 'REFUSED.*3$' /tmp/appdata-rebase.$$ && ok "rebase refuses (exit 3) without a good backup" || bad "rebase must refuse without a backup"
grep -q 'restore "\$t"' /tmp/appdata-rebase.$$ && ok "rebase restores after the reinstall" || bad "rebase must restore the backup"
rm -f /tmp/appdata-rebase.$$

R=targets/android/rooted/powos-idle-sysupdate.sh
grep -q 'powos-appdata.sh' "$R" && grep -q 'exit 3' "$R" && ok "the idle runner goes through powos-appdata.sh and refuses without it" ||
  bad "$R must re-base only through powos-appdata.sh and refuse without it"
grep -q 'powos-appdata.sh' targets/android/rooted/powos-deploy.sh && ok "powos-deploy.sh installs powos-appdata.sh" ||
  bad "powos-deploy.sh must install powos-appdata.sh"
grep -q 'powos-appdata.sh watch' targets/android/rooted/powos-start.sh && ok "powos-start.sh starts the hourly light backup" ||
  bad "powos-start.sh must start powos-appdata.sh watch"
for f in "$GUARD" "$R"; do sh -n "$f" && ok "$f parses" || bad "$f has a syntax error"; done

echo ""; echo "test-appdata-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
