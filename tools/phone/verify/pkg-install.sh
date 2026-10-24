#!/bin/bash
# lanes: phone
# pkg-install.sh <pkg.tar.xz|name>...: (Mac side; queue it: queue.sh add <board-task> pkg-install.sh <abs path>)
# installs rootfs packages built by targets/android/build-pkgs.sh into PowOS with pacman -U, each with a rollback
# tar of the files the installed version had (/var/cache/powos/<name>-<old version>-files.tar: `tar -xf` it as
# root to go back). Packages only: no session restart, no game touched. Prints "<name> <old> -> <new>"; FAIL when
# pacman refuses.
#   A bare name with no "/" (e.g. "kwin", not a path) resolves to the newest <name>-*.pkg.tar.* in the shared
#   build-inputs cache (tools/agents/build-inputs-cache.sh; build-pkgs.sh lands every build there) - so a package
#   stays installable after the worktree that built it is removed (friction f87/f116).
set -uo pipefail
# Scripts for root.sh/user.sh go under $HOME: adb.sh mounts the pushed file's directory into its container, and a
# mktemp in /var/folders "cannot stat" (every pkg-install FAILed, 2026-10-23 05:29).
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"; R="$here/../root.sh"
CACHE=${POWOS_BUILD_INPUTS_CACHE:-$HOME/.cache/powos-build-inputs}
[ $# -gt 0 ] || { echo "usage: pkg-install.sh <pkg.tar.xz|name>..."; exit 2; }
rc=0
for p in "$@"; do
  if [ ! -e "$p" ] && [ "${p#*/}" = "$p" ]; then   # a bare name (no "/"), not an existing relative path
    found=$(ls -t "$CACHE"/pkgs/"$p"-*.pkg.tar.* 2>/dev/null | head -1)
    [ -n "$found" ] && p=$found || { echo "FAIL install: no file $p, and nothing cached as $CACHE/pkgs/$p-*.pkg.tar.*"; rc=1; continue; }
  fi
  p=$(cd "$(dirname "$p")" && pwd)/$(basename "$p")   # adb.sh mounts the dirname: no ".." (skill: powos-games)
  [ -f "$p" ] || { echo "FAIL install: no file $p"; rc=1; continue; }
  b=$(basename "$p"); name=${b%-*-*-*.pkg.tar.*}
  "$A" push "$p" "/data/local/tmp/$b" >/dev/null && "$A" shell "su -c 'mv /data/local/tmp/$b /data/powos/root/var/tmp/$b'" \
    || { echo "FAIL install: can't push $b"; rc=1; continue; }
  s=$(mkdir -p "$HOME/.cache/powos-verify" && mktemp "$HOME/.cache/powos-verify/install.XXXXXX"); cat > "$s" <<SH
set -e
old=\$(pacman -Q $name 2>/dev/null | cut -d' ' -f2 || true)
if [ -n "\$old" ]; then mkdir -p /var/cache/powos
  pacman -Qlq $name | while read -r f; do [ -f "\$f" ] && echo "\$f"; done | tar -cf /var/cache/powos/$name-\$old-files.tar -T - 2>/dev/null; fi
pacman -U --noconfirm /var/tmp/$b >/dev/null
rm -f /var/tmp/$b
echo "$name \${old:-none} -> \$(pacman -Q $name | cut -d' ' -f2) (rollback: /var/cache/powos/$name-\${old:-none}-files.tar)"
SH
  out=$("$R" "$s" 2>&1); rm -f "$s"
  echo "$out" | tail -3
  echo "$out" | grep -q " -> " || { echo "FAIL install: $b"; rc=1; }
done
exit $rc
