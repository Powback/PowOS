#!/bin/bash
# test-adb-key-heal.sh - the Mac adb key self-heal (targets/android/rooted/adb-key-heal.sh, unit adb-mac-key-heal),
# run against temp files: missing -> restored once, present -> no-op, other keys untouched (order and bytes), and
# idempotent. The script's /data paths are pointed at a temp dir; chown/chcon/restorecon are stand-ins.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S=$ROOT/targets/android/rooted/adb-key-heal.sh
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   - $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL - $1"; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/misc"
for c in chown chmod chcon restorecon; do printf '#!/bin/sh\necho "%s $*" >> %s/perm\n' "$c" "$t" > "$t/bin/$c"; chmod +x "$t/bin/$c"; done
sed -e "s|/data/misc/adb|$t/misc|g" -e "s|/data/powos/state|$t/state|g" "$S" > "$t/heal.sh"
grep -q '/data/' "$t/heal.sh" && bad "a /data path left in the test copy" || ok "test copy writes only under the temp dir"
mat=$(sed -n "s/^MAC_KEY='\([^ ]*\) .*/\1/p" "$S")
[ -n "$mat" ] && ok "the script names exactly one key" || bad "no MAC_KEY in the script"
[ "$(grep -c '^MAC_KEY=' "$S")" = 1 ] || bad "more than one MAC_KEY line"
run() { PATH="$t/bin:$PATH" sh "$t/heal.sh"; }
K=$t/misc/adb_keys
printf 'AAAAotherkey1 a@b\nAAAAotherkey2 c@d\n' > "$K"; cp "$K" "$t/before"
run; rc=$?
[ $rc = 0 ] && ok "missing: exit 0" || bad "missing: rc $rc"
[ "$(grep -cF "$mat" "$K")" = 1 ] && ok "missing: the Mac key restored once" || bad "missing: Mac key count $(grep -cF "$mat" "$K")"
[ "$(head -2 "$K")" = "$(cat "$t/before")" ] && ok "other keys untouched, in order" || bad "other keys changed"
[ "$(wc -l < "$K")" = 3 ] && ok "append-only (3 lines)" || bad "lines: $(wc -l < "$K")"
grep -q "chown system:shell $K" "$t/perm" && grep -q "chmod 0640 $K" "$t/perm" && grep -q "chcon u:object_r:adb_keys_file:s0 $K" "$t/perm" \
  && ok "owner system:shell, 0640, adb_keys_file context" || bad "perms: $(cat "$t/perm")"
grep -q 'restored Mac adb key' "$t/state/adb-key-heal.log" && ok "restore logged" || bad "no log line"
cp "$K" "$t/after1"; rm -f "$t/perm"
run; run
cmp -s "$K" "$t/after1" && ok "present: no-op (twice)" || bad "present: file changed"
[ ! -e "$t/perm" ] && ok "present: no chown/chmod/chcon" || bad "present: touched perms"
[ "$(grep -c restored "$t/state/adb-key-heal.log")" = 1 ] && ok "present: not logged again" || bad "logged again"
# A differing comment still counts as present (key material only).
printf 'AAAAotherkey1 a@b\n%s someone-else@host\n' "$mat" > "$K"; cp "$K" "$t/c"; run
cmp -s "$K" "$t/c" && ok "present with another comment: no-op" || bad "comment variant duplicated"
# No keys file at all: created with just the Mac key.
rm -f "$K"; run
[ "$(wc -l < "$K")" = 1 ] && grep -qF "$mat" "$K" && ok "no file: created with the Mac key only" || bad "no file: $(cat "$K")"
# The repo copy is what the deploy installs and the periodic loop runs.
grep -q 'install -m 755 $T/adb-key-heal.sh /data/powos/adb-key-heal.sh' "$ROOT/targets/android/rooted/powos-deploy.sh" \
  && grep -q 'install -m 755 $T/powos-adbkey-heal.sh /data/adb/service.d/powos-adbkey-heal.sh' "$ROOT/targets/android/rooted/powos-deploy.sh" \
  && ok "powos-deploy installs the heal + its boot hook" || bad "powos-deploy lacks the heal"
grep -q 'adb-key-heal.sh powos-adbkey-heal.sh; do' "$ROOT/targets/android/rooted/rooted.sh" && ok "rooted.sh pushes both" || bad "rooted.sh does not push them"
grep -q 'sh /data/powos/adb-key-heal.sh' "$ROOT/targets/android/rooted/powos-periodic.sh" && ok "powos-periodic runs it" || bad "periodic lacks it"
echo "test-adb-key-heal: $pass passed, $fail failed"
[ $fail = 0 ]
