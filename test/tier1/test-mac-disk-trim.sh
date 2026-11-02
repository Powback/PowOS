#!/bin/bash
# test-mac-disk-trim.sh - the Mac's Colima trim unit (tools/agents/mac-disk-trim.sh, units/mac/mac-disk-trim-mac.json).
#
# User rules this guards: never the Docker build cache, images, volumes or user files; autosleep's stopped (hibernated)
# compose containers must survive (removing one breaks its wake); the deploy removes ONLY the crontab line it replaces.
# Runs with fake colima/docker/df/crontab/launchctl/plutil on PATH, so nothing on the host is touched.
#
# Usage:  bash test/tier1/test-mac-disk-trim.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "    $2"; FAIL=$((FAIL+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
CALLS=$T/calls

old=$(date -u -d '@'$(( $(date +%s) - 30*86400 )) '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -r $(( $(date +%s) - 30*86400 )) '+%Y-%m-%dT%H:%M:%S')
new=$(date -u '+%Y-%m-%dT%H:%M:%S')
# id -> name|compose project|autosleep|finished|created
cat > "$T/containers" <<EOF
aaa|/loose-old|||${old}.0Z|${old}.0Z
bbb|/compose-slept|myproj|on|${old}.0Z|${old}.0Z
ccc|/autosleep-only||on|${old}.0Z|${old}.0Z
ddd|/loose-recent|||${new}.0Z|${new}.0Z
eee|/created-old|||0001-01-01T00:00:00Z|${old}.0Z
EOF
cat > "$T/bin/docker" <<EOF
#!/bin/bash
echo "docker \$*" >> "$CALLS"
case "\$1" in
  ps) cut -d'|' -f1 "$T/containers" ;;
  inspect) grep "^\${@: -1}|" "$T/containers" | cut -d'|' -f2- ;;
esac
exit 0
EOF
cat > "$T/bin/colima" <<EOF
#!/bin/bash
echo "colima \$*" >> "$CALLS"
[ "\$1" = ssh ] && echo "/mnt/lima-colima: 1 GiB trimmed"
exit 0
EOF
printf '#!/bin/bash\necho "Filesystem 1G-blocks Used Available"; echo "/dev/x 900 700 42"\n' > "$T/bin/df"
for c in launchctl plutil; do printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$c" "$CALLS" > "$T/bin/$c"; done
cat > "$T/bin/crontab" <<EOF
#!/bin/bash
if [ "\$1" = -l ]; then cat "$T/crontab"; else cat > "$T/crontab.new"; cp "$T/crontab.new" "$T/crontab"; fi
EOF
chmod +x "$T"/bin/*
run() { HOME=$T/home PATH="$T/bin:$PATH" bash "$ROOT/tools/agents/$1" "${@:2}"; }

echo "== mac-disk-trim =="
SCRIPT=$ROOT/tools/agents/mac-disk-trim.sh
code=$(grep -v '^\s*#' "$SCRIPT")
if echo "$code" | grep -qE 'builder +prune|system +prune|image +prune|volume +prune|rmi|docker rm +-[a-z]*v|rm +-rf'; then
  bad "the script never prunes build cache/images/volumes or deletes files" "$(echo "$code" | grep -nE 'builder +prune|system +prune|image +prune|volume +prune|rmi|rm -[a-z]*v|rm +-rf')"
else ok "the script has no build-cache/image/volume prune, no docker rm -v, no rm -rf"; fi

: > "$CALLS"; out=$(run mac-disk-trim.sh --dry-run)
if grep -q 'docker rm' "$CALLS"; then bad "dry-run removed nothing" "$(cat "$CALLS")"; else ok "dry-run removes nothing"; fi
grep -q 'fstrim -nv' "$CALLS" && ! grep -q 'fstrim -v' "$CALLS" && ok "dry-run trims with -n only" || bad "dry-run fstrim not -n" "$(cat "$CALLS")"
echo "$out" | grep -q 'would remove loose-old' && echo "$out" | grep -q 'would remove created-old' && ok "dry-run lists the long-dead loose containers" || bad "dry-run candidates" "$out"
echo "$out" | grep -qE 'would remove (compose-slept|autosleep-only|loose-recent)' && bad "dry-run would remove a kept container" "$out" || ok "compose, autosleep and recently stopped containers are kept"
[ -f "$T/home/.cache/powos-mac-disk-trim/last-prune" ] && bad "dry-run started the weekly clock" || ok "dry-run leaves the weekly clock alone"

: > "$CALLS"; run mac-disk-trim.sh
rmline=$(grep '^docker rm' "$CALLS")
[ "$rmline" = "docker rm aaa eee" ] && ok "a real pass removes exactly the long-dead loose containers (no -v)" || bad "real pass docker rm" "$rmline"
grep -q 'fstrim -v /mnt/lima-colima' "$CALLS" && ok "a real pass trims /mnt/lima-colima" || bad "real pass fstrim" "$(cat "$CALLS")"
: > "$CALLS"; run mac-disk-trim.sh
grep -q '^docker' "$CALLS" && bad "the prune is weekly, not every pass" "$(cat "$CALLS")" || ok "the container prune waits a week; the trim still runs"

echo "== mac-disk-trim-deploy =="
cat > "$T/crontab" <<'EOF'
*/10 * * * * /bin/bash /x/disk-watchdog.sh # com.powstation.disk-watchdog
*/20 * * * * PATH=/opt/homebrew/bin:/usr/local/bin:$PATH colima ssh -- sudo fstrim /mnt/lima-colima >/tmp/colima-fstrim.log 2>&1 # powos manager: return freed VM space to macOS
*/5 * * * * $HOME/.powos-disk-guard.sh # powos manager: pause stickman training below 3 GB free
EOF
: > "$CALLS"; run mac-disk-trim-deploy.sh install >/dev/null
P=$T/home/Library/LaunchAgents/com.powos.mac-disk-trim.plist
[ -f "$P" ] && ! grep -q '@HOME@\|@BIN@' "$P" && grep -q "$T/home/.local/share/powos/mac-disk-trim/mac-disk-trim.sh" "$P" \
  && ok "install writes the plist with its paths filled in" || bad "install plist" "$(cat "$P" 2>/dev/null | head -20)"
[ -x "$T/home/.local/share/powos/mac-disk-trim/mac-disk-trim.sh" ] && ok "install copies the script" || bad "install copy"
grep -q 'launchctl bootstrap' "$CALLS" && ok "install loads the agent" || bad "install launchctl" "$(cat "$CALLS")"
if ! grep -q 'fstrim' "$T/crontab" && grep -q 'disk-watchdog' "$T/crontab" && grep -q 'powos-disk-guard' "$T/crontab" && [ "$(wc -l < "$T/crontab")" -eq 2 ]; then
  ok "install removes only the crontab fstrim line it replaces"
else bad "crontab after install" "$(cat "$T/crontab")"; fi

echo "== unit =="
U=$ROOT/units/mac/mac-disk-trim-mac.json
python3 - "$U" <<'PY' && ok "units/mac/mac-disk-trim-mac.json claims the plist, the copy and the state dir; has owner, limits, a way out" || bad "unit manifest"
import json, sys
u = json.load(open(sys.argv[1]))
f = u["files"]
assert u["id"] == "mac-disk-trim-mac" and u["host"] == "mac" and u["owner"] and u["unbounded"], u
assert "~/Library/LaunchAgents/com.powos.mac-disk-trim.plist" in f and "~/.local/share/powos/mac-disk-trim" in f and "~/.cache/powos-mac-disk-trim" in f, f
assert u["remove"]["commands"] == ["tools/agents/mac-disk-trim-deploy.sh remove"], u["remove"]
assert "build cache" in u["purpose"]
PY

echo; echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
