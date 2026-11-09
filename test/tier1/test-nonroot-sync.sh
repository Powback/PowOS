#!/bin/bash
# test-nonroot-sync.sh - the ship service's non-root phones (tools/phone/nonroot-sync.sh): against a fake adb and a temp
# repo - the device found by its mDNS prefix, an older APK replaced by the service's copy (screen off; never while the
# user is on it, never a downgrade), the overrides reset on a new APK, then exactly the shell delta from that APK to the
# live tip pushed through run-as (added/changed pushed, deleted removed, dev/test never), and nothing on a second pass.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   - $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL - $1"; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
R=$t/repo Q=$t/q; mkdir -p "$R/shell/ui" "$R/shell/dev" "$Q" "$t/bin" "$t/home"
cp "$ROOT/shell/push.sh" "$R/shell/push.sh"
g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
g init -q
echo a1 > "$R/shell/ui/a.ts"; echo b1 > "$R/shell/ui/b.ts"; echo d1 > "$R/shell/dev/x.ts"
g add -A; g commit -qm one; C1=$(g rev-parse HEAD)
echo a2 > "$R/shell/ui/a.ts"; rm "$R/shell/ui/b.ts"; echo c2 > "$R/shell/ui/c.ts"; echo d2 > "$R/shell/dev/x.ts"
g add -A; g commit -qm two; C2=$(g rev-parse HEAD)
mkapk() { python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("assets/shell/shell-build.txt","1 "+sys.argv[2]+"\n"); z.close()' "$1" "$2"; }
mkdir -p "$Q/nonroot"; mkapk "$Q/nonroot/powos.apk" "$C2"; echo "$C2" > "$Q/nonroot/powos.apk.commit"
echo "$C2" > "$Q/live"
echo "$C1" > "$t/stamp"   # the device's installed APK
cat > "$t/bin/adb" <<EOF
#!/bin/bash
echo "\$*" >> $t/adb.log
[ "\$1" = -s ] && shift 2
case "\$1 \${2:-}" in
  "mdns services") printf 'List of discovered mdns services\nadb-OTHER-x\t_adb-tls-connect._tcp\t10.0.0.9:1111\nadb-ZY22-abc\t_adb-tls-connect._tcp\t10.0.0.5:4242\n' ;;
  "devices "*) echo "List of devices attached" ;;
  "connect "*) echo "connected" ;;
  "get-state "*) echo device ;;
  "install -r") python3 -c 'import sys,zipfile; print(zipfile.ZipFile(sys.argv[1]).read("assets/shell/shell-build.txt").decode().split()[1])' "\$3" > $t/stamp; echo Success ;;
  "push "*) cp "\$3" $t/pushed.tar ;;
  "shell "*) shift; c="\$*"
    case "\$c" in
      *unzip*shell-build*) echo "1 \$(cat $t/stamp)" ;;
      "dumpsys power") echo "  mWakefulness=\$(cat $t/screen)" ;;
      *su\ *) exit 1 ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$t/bin/adb"
cat > "$t/conf" <<'EOF'
# test
razr adb-ZY22
EOF
run() { HOME=$t/home SHIP_DIR=$Q NONROOT_ADB=$t/bin/adb NONROOT_CONF=$t/conf NONROOT_REPO=$R bash "$ROOT/tools/phone/nonroot-sync.sh" "$@"; }

# The user is on it: no install, but the shell still follows (from the device's own APK).
echo Awake > "$t/screen"; : > "$t/adb.log"
run
grep -q -- '-s 10.0.0.5:4242 ' "$t/adb.log" && ok "device found by its mDNS prefix" || bad "no call to 10.0.0.5:4242: $(head -3 "$t/adb.log")"
grep -q 'install' "$t/adb.log" && bad "installed while the screen was on" || ok "no install while the user is on it"
grep -q 'waits for the screen off' "$Q/nonroot/log" && ok "the wait is logged" || bad "no wait line: $(cat "$Q/nonroot/log")"
[ "$(cat "$Q/nonroot/razr/live" 2>/dev/null)" = "$C2" ] && ok "shell live recorded" || bad "live: $(cat "$Q/nonroot/razr/live" 2>/dev/null)"
tar -tf "$t/pushed.tar" 2>/dev/null | sort > "$t/files"
[ "$(paste -sd' ' "$t/files")" = "ui/a.ts ui/c.ts" ] && ok "pushed exactly the delta (no dev/)" || bad "pushed: $(paste -sd' ' "$t/files")"
grep -q 'run-as com.powos.app.*rm -f files/shell/ui/b.ts' "$t/adb.log" && ok "deleted file removed from the overrides" || bad "b.ts not reset"
grep -E '(^|[ "])su ' "$t/adb.log" | grep -v 'comms notify' | grep -q . && bad "used su" || ok "no su writes (run-as only)"
grep -q "shell-layer.txt" "$t/adb.log" && grep -q "$C2" "$t/adb.log" && ok "layer stamped with the live tip" || bad "no layer stamp"

# A second pass: nothing to do.
: > "$t/adb.log"; rm -f "$t/pushed.tar"
run
[ -e "$t/pushed.tar" ] && bad "pushed again with nothing new" || ok "second pass pushes nothing"

# Screen off: the newer APK goes on, the overrides reset, then nothing left to push (the APK is the tip).
echo Asleep > "$t/screen"; : > "$t/adb.log"
run
grep -q 'install -r' "$t/adb.log" && ok "APK installed with the screen off" || bad "no install: $(cat "$t/adb.log" | head -5)"
[ "$(cat "$t/stamp")" = "$C2" ] && ok "device now on the service's APK" || bad "stamp $(cat "$t/stamp")"
grep -q 'find . -mindepth 1' "$t/adb.log" && ok "overrides reset after the new APK" || bad "no reset after install"
[ -e "$t/pushed.tar" ] && bad "pushed files the APK already has" || ok "nothing pushed over the APK's own shell"

# Never a downgrade: a device newer than the service's APK keeps its APK.
echo "$C2" > "$Q/nonroot/powos.apk.commit"; mkapk "$Q/nonroot/powos.apk" "$C1"; echo "$C1" > "$Q/nonroot/powos.apk.commit"
: > "$t/adb.log"; run
grep -q 'install' "$t/adb.log" && bad "downgraded the APK" || ok "no downgrade"

# --dry-run changes nothing.
: > "$t/adb.log"; out=$(run --dry-run)
echo "$out" | grep -q '^razr: ' && ok "dry run reports the device" || bad "dry run: $out"
grep -qE 'install|push |run-as com.powos.app sh' "$t/adb.log" && bad "dry run changed the device" || ok "dry run is read-only"

echo "nonroot-sync: $pass passed, $fail failed"
[ "$fail" = 0 ]
