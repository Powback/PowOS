#!/bin/bash
# test-xwayland-install.sh: tools/phone/verify/xwayland-install.sh judges an Xwayland install by Xwayland, not KWin
# (11-03: it copied kwin-install's "a new KWin pid" test and FAILed + rolled back a good 24.1.13-4 install - session
# 759 -> 760, kwin=31069 kept, as KWin outlives the session since the reattach work). PASS = a new Xwayland pid whose
# /proc exe is the package's file AND an X client (xwininfo -root, which starts the lazy Xwayland) works; the old
# Xwayland outliving the session gets SIGTERM; a real failure still FAILs with the rollback command. A fake
# adb.sh/root.sh/user.sh (XW_TOOLS) stands in for the phone: $T/xw = "<pid> <exe>" or "-", $T/sess = session starts.
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/xw-install-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }
F=/usr/local/bin/Xwayland
mkdir -p "$T/tools" "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"   # the script's waits, instant
cat > "$T/tools/adb.sh" <<EOF2
#!/bin/bash
echo "\$*" >> "$T/adb.log"
c=\$*; read -r p _ < "$T/xw"
case "\$c" in
  *session.log*) cat "$T/sess" ;;
  *"[ -d /proc/"*) n=\${c#*/proc/}; n=\${n%% *}; [ "\$n" = "\$p" ] && echo y ;;
  *"kill "*) n=\${c#*kill }; n=\${n%%\'*}; [ "\$n" = "\$p" ] && [ ! -e "$T/unkillable" ] && echo - > "$T/xw" ;;
esac
exit 0
EOF2
cat > "$T/tools/root.sh" <<EOF2
#!/bin/bash
s=\$(cat "\$1"); read -r p e < "$T/xw"
case "\$s" in
  *vercmp*) echo 0 ;;
  *"pgrep -x Xwayland"*) [ "\$p" = - ] && echo "xwayland=- xwayland_new=0 exe=- pkgfile=$F" \
      || { n=0; [ "\$e" = $F ] && n=1; echo "xwayland=\$p xwayland_new=\$n exe=\$e pkgfile=$F"; } ;;
  *"pacman -Q xwayland-kgsl"*) echo 24.1.13-4 ;;
esac
EOF2
cat > "$T/tools/user.sh" <<EOF2
#!/bin/bash
s=\$(cat "\$1"); read -r p _ < "$T/xw"
echo "\$s" | head -1 >> "$T/user.log"
case "\$s" in
  *"power logout"*) echo \$((\$(cat "$T/sess") + 1)) > "$T/sess"; [ -e "$T/kwin-restarts" ] && echo - > "$T/xw" ;;
  *xwininfo*) [ -e "$T/nodisplay" ] && { echo "display=fail xwininfo: unable to open display"; exit 0; }
    [ "\$p" = - ] && echo "\$(cat "$T/next")" > "$T/xw"; echo "display=ok Width: 2268 Height: 2440 " ;;
esac
EOF2
chmod +x "$T/tools/"*.sh "$T/bin/sleep"

run() {   # run "<xw>" "<next xw>" [flag files]: -> rc, out
  rm -f "$T"/{unkillable,nodisplay,kwin-restarts,adb.log,user.log}; echo "$1" > "$T/xw"; echo "$2" > "$T/next"; echo 759 > "$T/sess"
  shift 2; for f in "$@"; do touch "$T/$f"; done
  out=$(PATH="$T/bin:$PATH" XW_TOOLS=$T/tools LOCK_HELD=1 XWAYLAND_PKG=/none/xwayland-kgsl-24.1.13-4-1-aarch64.pkg.tar.xz \
    perl -e "alarm 60; exec @ARGV" bash "$src/tools/phone/verify/xwayland-install.sh" 24.1.13-4 "$T/out" 2>&1); rc=$?
}

# 1. the 11-03 case: the replaced Xwayland, KWin (and so Xwayland) outlive the logout -> SIGTERM, the X client starts the new one
run "500 ${F}_(deleted)" "501 $F"
if [ $rc = 0 ] && grep -q '^PASS: xwayland-kgsl 24.1.13-4 installed, its Xwayland serves the session (xwayland=501 xwayland_new=1' <<<"$out" \
   && grep -q 'kill 500' "$T/adb.log" && grep -q 'session restarted: yes (759 -> 760)' <<<"$out"; then
  ok "stale Xwayland, KWin outlives the session: old Xwayland SIGTERMed, new pid on the package's file serves DISPLAY -> PASS"
else bad "stale Xwayland, KWin outlives the session -> PASS" "rc=$rc"$'\n'"$out"; fi
grep -qi 'kwin' <<<"$(grep -E '^(PASS|FAIL)' <<<"$out")" && bad "the verdict never hinges on KWin" "$out" || ok "the verdict never hinges on KWin"
grep -qiE 'steam|broforce' "$T/user.log" "$T/adb.log" && bad "never starts Steam or a game" || ok "never starts Steam or a game"

# 2. the session restart takes Xwayland with it (KWin restarted too): no SIGTERM needed
run "500 ${F}_(deleted)" "502 $F" kwin-restarts
[ $rc = 0 ] && ! grep -q 'kill 500' "$T/adb.log" && grep -q 'xwayland=502 xwayland_new=1' <<<"$out" \
  && ok "Xwayland gone with the session: no SIGTERM, the new one PASSes" || bad "Xwayland gone with the session -> PASS" "rc=$rc"$'\n'"$out"

# 3. no Xwayland yet (lazy) and the package current: no session restart, the X client starts it -> PASS
run "-" "503 $F"
[ $rc = 0 ] && ! grep -q 'power logout' "$T/user.log" && grep -q 'xwayland=503 xwayland_new=1' <<<"$out" \
  && ok "lazy Xwayland not started yet: the trivial X client starts it, no session restart -> PASS" \
  || bad "lazy Xwayland not started -> PASS" "rc=$rc"$'\n'"$out"$'\n'"$(cat "$T/user.log")"

# 4. real failures keep the rollback: the old one won't die / no display / the display served by a non-package binary
run "500 ${F}_(deleted)" "501 $F" unkillable
[ $rc = 1 ] && grep -q '^FAIL: .*still running 10 s after SIGTERM.*(rollback: tar -xf /var/cache/powos/xwayland-kgsl-24.1.13-4-files.tar -C /)' <<<"$out" \
  && ok "old Xwayland won't go: FAIL with the rollback" || bad "old Xwayland won't go: FAIL + rollback" "rc=$rc"$'\n'"$out"
run "500 ${F}_(deleted)" "501 $F" nodisplay
[ $rc = 1 ] && grep -q '^FAIL: no X client works on the display.*(rollback: ' <<<"$out" \
  && ok "no X client works after the install: FAIL with the rollback" || bad "no display: FAIL + rollback" "rc=$rc"$'\n'"$out"
run "500 ${F}_(deleted)" "501 ${F}_(deleted)"
[ $rc = 1 ] && grep -q "^FAIL: the Xwayland serving the display isn't the installed 24.1.13-4 binary.*(rollback: " <<<"$out" \
  && ok "the new Xwayland still a deleted binary: FAIL with the rollback" || bad "deleted binary after restart: FAIL" "rc=$rc"$'\n'"$out"

[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
