#!/usr/bin/env bash
# The phone's pull updates (docs/PHONE-UPDATES.md): lib/phone-update.sh's decisions with pacman stubbed, and
# tools/phone-files.sh's map of the session files powos-core packages.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
ok() { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

# 1. The session map: every file install-powos-android.sh installs from session/, shims/, play/ - and each exists.
map=$("$ROOT/targets/android/tools/phone-files.sh")
n=$(printf '%s\n' "$map" | grep -c .)
[ "$n" -ge 30 ] && ok "phone-files.sh maps $n files" || bad "phone-files.sh maps only $n files"
miss=$(printf '%s\n' "$map" | while read -r m src dest; do [ -f "$ROOT/targets/android/$src" ] || echo "$src"; case "$dest" in /*) ;; *) echo "relative $dest" ;; esac; done)
[ -z "$miss" ] && ok "every mapped source exists, every destination is absolute" || bad "map: $miss"
printf '%s\n' "$map" | grep -q '^755 session/powos-open-task /usr/local/bin/powos-open-task$' && ok "powos-open-task mapped" || bad "powos-open-task not mapped"
# The Claude endpoint shell file and its unit (repo files outside targets/android) reach installed phones via powos-core,
# not only a fresh base (11-11: the razr's base predates them and a new base is for fresh installs only).
printf '%s\n' "$map" | grep -q '^644 \.\./\.\./config/etc/profile.d/45-powos-claude-endpoint.sh /etc/profile.d/45-powos-claude-endpoint.sh$' \
  && ok "claude endpoint profile.d mapped" || bad "claude endpoint profile.d not in powos-core"
printf '%s\n' "$map" | grep -q '^644 \.\./\.\./units/phone/claude-code.json /etc/powos/units.d/claude-code.json$' \
  && ok "claude-code unit mapped" || bad "claude-code unit not in powos-core"
# Every ../../ source lies under a path build-powos-core.sh archives, or makepkg can't find it.
paths=$(sed -n '/^PATHS=(/,/)/p' "$ROOT/targets/android/build-powos-core.sh" | tr -d '()' | sed 's/^PATHS=//')
unarch=$(printf '%s\n' "$map" | awk '$2 ~ /^\.\.\/\.\.\//{print substr($2,7)}' | while read -r s; do
  hit=""; for p in $paths; do case "$s" in "$p"|"$p"/*) hit=1 ;; esac; done; [ -n "$hit" ] || echo "$s"; done)
[ -z "$unarch" ] && ok "every repo-root source is archived" || bad "not in PATHS: $unarch"

# 2. phone-update.sh with pacman, pgrep and vercmp stubbed.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/pacman" <<'S'
#!/bin/sh
echo "pacman $*" >> "$LOG"
case "$*" in
  "-Q powos-core") [ -n "${HAVE:-}" ] && echo "powos-core $HAVE" && exit 0; exit 1 ;;
  *"-Si powos-core"*) echo "Version         : ${REPO:-}"; [ -n "${REPO:-}" ] ;;
  *) exit 0 ;;
esac
S
cat > "$T/bin/pgrep" <<'S'
#!/bin/sh
case "$*" in "-x pacman") [ -n "${PACMAN_RUNS:-}" ] ;; *) [ -n "${GAME:-}" ] ;; esac
S
cat > "$T/bin/vercmp" <<'S'
#!/bin/sh
[ "$1" = "$2" ] && { echo 0; exit; }; [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && echo 1 || echo -1
S
chmod +x "$T/bin/"*
printf '[options]\n\n[powos]\nServer = http://x\n' > "$T/conf"
run() { : > "$T/log"; env PATH="$T/bin:$PATH" LOG="$T/log" TMPDIR="$T" POWOS_UPDATE_CONF="$T/conf" POWOS_PACMAN_LOCK="$T/db.lck" "$@" sh "$ROOT/lib/phone-update.sh" ${ARGS:-}; }

: > "$T/db.lck"; out=$(run HAVE=3500.gaaa-1 REPO=3517.gbbb-1)
[ ! -e "$T/db.lck" ] && ok "a stale pacman lock is removed" || bad "stale lock left"
grep -q -- "-Syu --noconfirm --ignore powos-core" "$T/log" && ok "upgrades from [powos]" || bad "no -Syu: $(cat "$T/log")"
grep -q -- "-S --noconfirm --overwrite \* powos-core" "$T/log" && ok "a newer powos-core is installed" || bad "newer powos-core not installed: $(cat "$T/log")"
echo "$out" | grep -q '^#done ok$' && ok "#done ok" || bad "no #done ok: $out"

: > "$T/db.lck"; run PACMAN_RUNS=1 HAVE=1-1 REPO=1-1 >/dev/null
[ -e "$T/db.lck" ] && ok "a live pacman's lock stays" || bad "removed a live pacman's lock"
rm -f "$T/db.lck"
grep -q -- "--overwrite" "$T/log" && bad "reinstalled an equal powos-core" || ok "an equal powos-core stays"

run HAVE=3517.gbbb-2 REPO=3517.gbbb-1 >/dev/null
grep -q -- "--overwrite" "$T/log" && bad "downgraded powos-core" || ok "never a downgrade"

run REPO=3517.gbbb-1 >/dev/null
grep -q -- "-S --noconfirm --overwrite \* powos-core" "$T/log" && ok "a missing powos-core is installed" || bad "missing powos-core not installed"

out=$(run GAME=1 REPO=2-1)
{ echo "$out" | grep -q '^#done game$' && [ ! -s "$T/log" ]; } && ok "nothing while a game runs" || bad "updated under a game: $out / $(cat "$T/log")"
out=$(ARGS=--force run GAME=1 REPO=2-1)
grep -q -- "-Syu" "$T/log" && ok "--force updates anyway" || bad "--force didn't"

out=$(ARGS=--check run HAVE=1-1 REPO=2-1)
{ grep -q -- "--dbpath" "$T/log" && ! grep -q -- "-Syu\|--overwrite" "$T/log"; } && ok "--check uses a private database copy only" || bad "--check: $(cat "$T/log")"

ARGS=--system run HAVE=1-1 REPO=1-1 >/dev/null
grep -q -- "--config $T/powos-full-pacman.conf -Syu" "$T/log" && ok "--system: the full config" || bad "--system: $(cat "$T/log")"

# Off the LAN on the VPN (issue #2): android.pow doesn't resolve -> pacman downloads with the name pinned to the hub.
cat > "$T/bin/getent" <<'S'
#!/bin/sh
[ -n "${RESOLVES:-}" ]
S
printf '#!/bin/sh\nexit 0\n' > "$T/bin/curl"; chmod +x "$T/bin/getent" "$T/bin/curl"
printf '[options]\n\n[powos]\nServer = http://android.pow/apk/repo\n' > "$T/conf"
out=$(run REPO=1-1 HAVE=1-1)
{ grep -q -- "--config $T/powos-pinned-pacman.conf -Syu" "$T/log" && grep -q '^XferCommand = .*--resolve android.pow:80:192.168.50.100 ' "$T/powos-pinned-pacman.conf"; } &&
  ok "unresolvable store: pacman via the hub's address" || bad "no hub fallback: $out / $(cat "$T/log")"
rm -f "$T/powos-pinned-pacman.conf"; run RESOLVES=1 REPO=1-1 HAVE=1-1 >/dev/null
grep -q -- "--config $T/conf -Syu" "$T/log" && ok "a resolving store: the plain config" || bad "pinned while it resolves: $(cat "$T/log")"
printf '[options]\n\n[powos]\nServer = http://x\n' > "$T/conf"

# 3. `powos update` on a phone goes to it.
grep -q 'phone-update.sh" --check' "$ROOT/bin/powos" && ok "powos update check -> phone-update.sh" || bad "bin/powos doesn't route the phone"
exit $fail
