#!/bin/bash
# A PowOS app's sources on the phone (~/Projects/<name> inside PowOS), from the Mac:
#   tools/phone/app-src.sh pull <name> [DIR]          copy them to DIR (default ~/.cache/powos-apps/<name>) - edit and
#                                                     preview there (shell/dev/preview/build-app-ui.sh, preview.sh)
#   tools/phone/app-src.sh push <name> DIR --note "what changed, for the user" <file>...
#                                                     put those files (paths relative to the app, e.g.
#                                                     ui/widgets/main.tsx) back, owner kept, then `powos app ui .`
#                                                     as the user: the shell hot-reloads it (module untouched).
# push refuses a file the phone changed since the pull (DIR/.phone.md5 keeps what was pulled): pull again and merge.
# push changes the phone (no input injected, so no idle wait) and `powos app ui` posts the quiet "update applied" note.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
adb() { "$here/adb.sh" "$@"; }
cmd=${1:-}; name=${2:-}
[[ "$cmd" =~ ^(pull|push)$ && -n "$name" && "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { sed -n 2,10p "$0"; exit 2; }
P=/data/powos/root/home/powos/Projects/$name
if [ "$cmd" = pull ]; then
  D=${3:-$HOME/.cache/powos-apps/$name}
  mkdir -p "$D"
  adb exec-out "su -c 'cd $P && tar -cf - --exclude=out --exclude=target --exclude=node_modules .'" | tar -xf - -C "$D"
  adb shell "su -c 'cd $P && find . -type f ! -path \"./out/*\" ! -path \"./target/*\" ! -path \"*/node_modules/*\" -exec md5sum {} +'" \
    | tr -d '\r' > "$D/.phone.md5"
  echo "pulled $name -> $D ($(wc -l < "$D/.phone.md5") files)"
  exit 0
fi
D=$(cd "${3:?push: DIR}" && pwd); shift 3
[ "${1:-}" = --note ] && [ -n "${2:-}" ] || { echo "push: --note \"...\" first" >&2; exit 2; }
note=$2; shift 2
[ $# -gt 0 ] || { echo "push: which files?" >&2; exit 2; }
now=$(adb shell "su -c 'cd $P && md5sum $*'" | tr -d '\r' || true)
for f in "$@"; do
  [ -f "$D/$f" ] || { echo "push: no $D/$f" >&2; exit 1; }
  was=$(grep "  \./$f\$" "$D/.phone.md5" 2>/dev/null | cut -d' ' -f1 || true)
  cur=$(echo "$now" | grep "  $f\$" | cut -d' ' -f1 || true)
  if [ -n "$cur" ] && [ "$cur" != "$was" ]; then echo "push: $f changed on the phone since the pull - pull again and merge" >&2; exit 1; fi
done
T=$(mktemp -d "$HOME/.cache/app-src.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/p"
for f in "$@"; do mkdir -p "$T/p/$(dirname "$f")"; cp "$D/$f" "$T/p/$f"; done
printf 'cd ~/Projects/%s && powos app ui . --note %q 2>&1 | tail -5\n' "$name" "$note" > "$T/p/.inst.sh"
tmp=/data/local/tmp/app-src-$$
adb shell "rm -rf $tmp" >/dev/null
adb push "$T/p" "$tmp" >/dev/null   # a fresh folder: adb push into an existing one nests it
adb shell "su -c 'set -e; o=\$(stat -c %u:%g $P); cd $tmp; for f in $*; do mkdir -p $P/\$(dirname \$f); cp \$f $P/\$f; chown \$o $P/\$f; done;
  cp .inst.sh /data/powos/root/tmp/app-src-$$.sh; chmod 755 /data/powos/root/tmp/app-src-$$.sh;
  sh /data/powos/powos-run.sh \"bash /tmp/app-src-$$.sh\"; rm -f /data/powos/root/tmp/app-src-$$.sh; rm -rf $tmp'"
for f in "$@"; do (cd "$D" && md5 -r "$f" 2>/dev/null || md5sum "$f"); done | sed 's/^/local /'
after=$(adb shell "su -c 'cd $P && md5sum $*'" | tr -d '\r')
echo "$after" | sed 's/^/phone /'
# What the phone has now is this push's: a second push of the same files isn't "changed on the phone since the pull".
for f in "$@"; do
  sum=$(echo "$after" | grep "  $f\$" | cut -d' ' -f1 || true)
  [ -n "$sum" ] || continue
  { grep -v "  \./$f\$" "$D/.phone.md5" 2>/dev/null || true; echo "$sum  ./$f"; } > "$D/.phone.md5.new" && mv "$D/.phone.md5.new" "$D/.phone.md5"
done
