#!/bin/bash
# Report-only preflight of the ship service's MODULE FIRST rule (tools/phone/ship.sh modules_first, 11-01 f391): which
# vendored apps' modules must be published on the phone BEFORE this branch's shell can go live there.
#   tools/phone/module-first-check.sh [--device] [REV]     REV: default HEAD
# History: a vendored app (shell/vendor/VERSIONS "generated") whose apps/<app>/module changed since the ship service's
# last apps ship (<queue>/apps-live, else the installed APK's commit) and whose shell/vendor/<db>.js differs from the
# phone's shell (<queue>/live) - "needs module publish first: <app>". --device: also the phone's LIVE module schemas
# against this checkout's bindings (tools/phone/bindings-check.sh --needs; one read-only adb call). Never publishes; always exit 0.
# Run by tools/agents/land.sh (report-only).
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT" || exit 0
dev=; [ "${1:-}" = --device ] && { dev=1; shift; }
rev=$(git rev-parse "${1:-HEAD}" 2>/dev/null) || exit 0
Q=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}
inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
abase=$(cat "$Q/apps-live" 2>/dev/null || true); abase=${abase:-$inst}
live=$(cat "$Q/live" 2>/dev/null || true); live=${live:-$inst}
need=
if [ -n "$abase" ] && git cat-file -e "$abase^{commit}" 2>/dev/null && [ -x apps/vendor.sh ]; then
  while read -r app db; do [ -n "$app" ] || continue
    { [ -n "$live" ] && git cat-file -e "$live^{commit}" 2>/dev/null && git diff --quiet "$live" "$rev" -- "shell/vendor/$db.js"; } && continue
    echo "needs module publish first: $app (apps/$app/module changed since the last apps ship; shell/vendor/$db.js differs from the phone's shell) - the ship service publishes it before the shell"
    need="$need $app"
  done < <(apps/vendor.sh --changed "$abase" "$rev" 2>/dev/null)
fi
if [ -n "$dev" ]; then
  tools/phone/bindings-check.sh --needs --vendor shell/vendor 2>&1 | while read -r w app db what; do
    [ "$w" = needs ] || continue
    case " $need " in *" $app "*) continue ;; esac
    echo "needs module publish first: $app (the phone's $db lacks $what)"
  done
fi
exit 0
