#!/bin/bash
# test-app-api-args.sh - the App API's root helpers (targets/android/rooted/app-ca.sh, app-frida.sh) and their Mac
# wrapper (rooted.sh app-ca / app-frida), hermetically: every verb's --help does nothing (11-10: `app-ca remove
# --help` used to delete the trust module), remove --dry-run changes nothing, unknown flags are refused, rooted.sh
# forwards every arg (and only plain tokens) to the phone (fake adb on PATH), `gen` hands openssl only chroot-valid
# paths and leaves the key 0600 (11-10: it wrote to /data/powos/app-api, which the chroot can't see), and app-frida
# refuses a hook-server binary that isn't the pinned 16.6.6. The scripts' /data paths point at a temp dir.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RD=$ROOT/targets/android/rooted
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   - $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL - $1"; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/root/usr/bin" "$t/root/root" "$t/modules" "$t/tmp"
# Stand-ins: root id, a logging rm (then the real one), chown no-op, and a chroot that runs the real openssl but only
# with paths valid INSIDE the chroot (/root/...), mapped under $t/root - an Android-side path fails as on the phone.
printf '#!/bin/sh\n[ "$1" = -u ] && echo 0 || /usr/bin/id "$@"\n' > "$t/bin/id"
printf '#!/bin/sh\necho "rm $*" >> %s/rm.log\nexec /bin/rm "$@"\n' "$t" > "$t/bin/rm"
printf '#!/bin/sh\nexit 0\n' > "$t/bin/chown"
cat > "$t/bin/chroot" <<'CH'
#!/bin/bash
r=$1; shift
while [ $# -gt 0 ] && [ "$1" != /usr/bin/openssl ]; do shift; done; shift
a=()
for x in "$@"; do
  case "$x" in
    /root/*) x=$r$x ;;
    "$APPCA_T"/*) echo "chroot: $x: No such file or directory (an Android-side path)" >&2; exit 1 ;;
  esac
  a+=("$x")
done
exec openssl "${a[@]}"
CH
chmod +x "$t/bin/"*; : > "$t/root/usr/bin/openssl"; chmod +x "$t/root/usr/bin/openssl"
fix() { sed -e "s|/data/powos/root|$t/root|g" -e "s|/data/powos/app-api|$t/app-api|g" -e "s|/data/adb/modules|$t/modules|g" \
            -e "s|/data/local/tmp|$t/tmp|g" "$RD/$1" > "$t/$1"; }
fix app-ca.sh; fix app-frida.sh
grep -v '/data/adb/powos/appca-trust' "$t/app-ca.sh" "$t/app-frida.sh" | grep -q '/data/' && bad "a /data path left in the test copies" || ok "test copies touch only the temp dir"
export APPCA_T=$t
ca() { PATH="$t/bin:$PATH" sh "$t/app-ca.sh" "$@"; }
fr() { PATH="$t/bin:$PATH" sh "$t/app-frida.sh" "$@"; }

# --help on every verb: exit 0, usage printed, nothing removed or created.
mkdir -p "$t/modules/powos-appca"; : > "$t/rm.log"
for v in gen install status remove; do
  out=$(ca $v --help 2>&1); rc=$?
  [ $rc = 0 ] && echo "$out" | grep -q "usage: app-ca.sh $v" && ok "app-ca $v --help: usage, rc 0" || bad "app-ca $v --help: rc $rc '$out'"
done
out=$(ca --help); [ $? = 0 ] && echo "$out" | grep -q 'remove \[--dry-run\]' && ok "app-ca --help" || bad "app-ca --help: $out"
ca remove --wipe-key -h >/dev/null; [ $? = 0 ] || bad "remove --wipe-key -h rc"
[ -d "$t/modules/powos-appca" ] && [ ! -s "$t/rm.log" ] && [ ! -e "$t/app-api" ] && ok "app-ca --help removed/created nothing" \
  || bad "app-ca --help had side effects: $(cat "$t/rm.log")"
out=$(ca remove --dry-run --wipe-key); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'would remove the trust module' && echo "$out" | grep -q 'would wipe' \
  && [ -d "$t/modules/powos-appca" ] && [ ! -s "$t/rm.log" ] && ok "app-ca remove --dry-run: says what, changes nothing" || bad "dry run: rc $rc '$out'"
ca remove --bogus >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && [ -d "$t/modules/powos-appca" ] && ok "app-ca remove --bogus: refused (rc 2), nothing removed" || bad "remove --bogus rc $rc"
ca gen --force >/dev/null 2>&1; [ $? = 2 ] && [ ! -e "$t/app-api" ] && ok "app-ca gen --force: refused" || bad "gen with an unknown flag ran"
ca frobnicate >/dev/null 2>&1; [ $? = 2 ] && ok "app-ca unknown verb: rc 2" || bad "unknown verb rc"
ca remove >/dev/null; [ ! -d "$t/modules/powos-appca" ] && ok "app-ca remove (real) removes the module" || bad "remove left the module"

# gen: openssl gets chroot paths only; key 0600 + cert end up in app-api; key never printed; idempotent.
if command -v openssl >/dev/null; then
  out=$(ca gen 2>&1); rc=$?
  if [ $rc = 0 ] && [ -s "$t/app-api/ca.key" ] && [ -s "$t/app-api/ca.crt" ]; then ok "gen: key + cert in app-api (chroot-only paths)"; else bad "gen: rc $rc '$out'"; fi
  [ "$(stat -c %a "$t/app-api/ca.key" 2>/dev/null)" = 600 ] && ok "gen: key 0600" || bad "gen: key mode $(stat -c %a "$t/app-api/ca.key" 2>/dev/null)"
  [ "$(stat -c %a "$t/app-api" 2>/dev/null)" = 700 ] && ok "gen: app-api 0700" || bad "gen: dir mode"
  [ ! -e "$t/root/root/.powos-appca-gen" ] && ok "gen: no scratch left in the chroot" || bad "gen: scratch dir left"
  echo "$out" | grep -q 'PRIVATE KEY' && bad "gen printed the key" || ok "gen: key not printed"
  fp=$(openssl x509 -in "$t/app-api/ca.crt" -noout -fingerprint -sha256 | sed 's/.*=//')
  echo "$out" | grep -qF "SHA-256  $fp" && ok "gen: prints the public fingerprint" || bad "gen: fingerprint missing: $out"
  k1=$(cksum < "$t/app-api/ca.key"); ca gen >/dev/null 2>&1
  [ "$(cksum < "$t/app-api/ca.key")" = "$k1" ] && ok "gen: idempotent (key kept)" || bad "gen replaced the key"
else
  echo "  skip - no openssl here: gen not exercised"
fi

# app-frida: --help on every verb, remove --dry-run, version pin.
for v in install start stop status remove; do
  out=$(fr $v --help 2>&1); rc=$?
  [ $rc = 0 ] && echo "$out" | grep -q "usage: app-frida.sh $v" && ok "app-frida $v --help" || bad "app-frida $v --help: rc $rc '$out'"
done
grep -q '^FRIDA_VERSION=16\.6\.6$' "$RD/app-frida.sh" && ok "frida pinned to 16.6.6" || bad "frida pin missing"
printf '#!/bin/sh\n[ "$1" = --version ] && echo 16.6.6\n' > "$t/good"; printf '#!/bin/sh\n[ "$1" = --version ] && echo 17.0.1\n' > "$t/old"
out=$(fr install "$t/old" 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q REFUSED && [ ! -e "$t/tmp/frida-server" ] && ok "install: wrong version refused, not staged" || bad "wrong version: rc $rc '$out'"
out=$(fr install "$t/good" 2>&1); rc=$?
[ $rc = 0 ] && [ "$(stat -c %a "$t/tmp/frida-server")" = 700 ] && ok "install: 16.6.6 staged 0700" || bad "good install: rc $rc '$out'"
: > "$t/rm.log"; out=$(fr remove --dry-run); [ $? = 0 ] && [ -e "$t/tmp/frida-server" ] && echo "$out" | grep -q 'would stop' \
  && ok "app-frida remove --dry-run: nothing deleted" || bad "frida dry run: $out"
fr remove --help >/dev/null; [ -e "$t/tmp/frida-server" ] && ok "app-frida remove --help: nothing deleted" || bad "remove --help deleted"
fr remove --bogus >/dev/null 2>&1; [ $? = 2 ] && [ -e "$t/tmp/frida-server" ] && ok "app-frida remove --bogus refused" || bad "remove --bogus"
fr remove >/dev/null; [ ! -e "$t/tmp/frida-server" ] && ok "app-frida remove deletes the binary" || bad "remove kept it"

# rooted.sh: fake adb records what reaches the phone.
cat > "$t/bin/adb" <<A
#!/bin/bash
echo "adb \$*" >> $t/adb.log
case "\$*" in "shell command -v su"*) echo /debug_ramdisk/su ;; esac
exit 0
A
chmod +x "$t/bin/adb"
rs() { : > "$t/adb.log"; PATH="$t/bin:$PATH" bash "$RD/rooted.sh" "$@" >/dev/null 2>&1; }
rs app-ca remove --help; grep -q "app-ca.sh remove --help;" "$t/adb.log" && ok "rooted.sh app-ca remove --help forwards --help" || bad "forward: $(cat "$t/adb.log")"
rs app-ca remove --dry-run --wipe-key; grep -q "app-ca.sh remove --dry-run --wipe-key;" "$t/adb.log" && ok "rooted.sh forwards every arg" || bad "args dropped: $(cat "$t/adb.log")"
rs app-ca; grep -q "app-ca.sh status;" "$t/adb.log" && ok "rooted.sh app-ca defaults to status" || bad "default: $(cat "$t/adb.log")"
rs app-ca "remove;reboot"; rc=$?
[ $rc = 2 ] && ! grep -q 'app-ca.sh' "$t/adb.log" && ok "rooted.sh refuses a non-token arg (nothing sent)" || bad "injection: rc $rc $(cat "$t/adb.log")"
rs app-frida remove --dry-run; grep -q "app-frida.sh remove --dry-run;" "$t/adb.log" && ok "rooted.sh app-frida forwards --dry-run" || bad "frida fwd"
rs app-frida install "$t/good"; grep -q "push -q $t/good /data/local/tmp/frida-server-staged" "$t/adb.log" && ok "rooted.sh app-frida install pushes BIN" || bad "frida push: $(cat "$t/adb.log")"

echo "Results: $pass passed, $fail failed"
[ $fail = 0 ]
