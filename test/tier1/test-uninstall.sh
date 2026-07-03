#!/bin/bash
# test-uninstall.sh - unit tests for `powos remove` pure logic (probe matching,
# arg handling, dry-run, not-found exit). Backend probes that need podman/
# flatpak/brew are stubbed; real removal is I/O and needs a VM.

set -uo pipefail

LIB="/usr/lib/powos/uninstall.sh"
[[ -f "$LIB" ]] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/uninstall.sh"
# shellcheck disable=SC1090
source "$LIB"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1 (got: ${2:-})"; FAIL=$((FAIL+1)); }

echo "== flatpak app-id matching (stubbed flatpak) =="
flatpak() {  # stub: two installed apps
    printf 'md.obsidian.Obsidian\ncom.valvesoftware.Steam\n'
}
r=$(probe_flatpak obsidian); [[ "$r" == "md.obsidian.Obsidian" ]] && ok "matches by last id component" || bad "obsidian" "$r"
r=$(probe_flatpak OBSIDIAN); [[ "$r" == "md.obsidian.Obsidian" ]] && ok "case-insensitive" || bad "case" "$r"
r=$(probe_flatpak steam); [[ "$r" == "com.valvesoftware.Steam" ]] && ok "second app matches" || bad "steam" "$r"
r=$(probe_flatpak valvesoftware); [[ -z "$r" ]] && ok "middle component does NOT match" || bad "middle" "$r"
r=$(probe_flatpak gimp); [[ -z "$r" ]] && ok "absent app → empty" || bad "absent" "$r"
unset -f flatpak

echo "== host-layer probe (stubbed rpm-ostree json) =="
rpm-ostree() {
    cat <<'EOF'
{"deployments":[
  {"booted":false,"requested-packages":["stale-pkg"]},
  {"booted":true,"requested-packages":["lm_sensors","htop"]}
]}
EOF
}
r=$(probe_host_layer htop); [[ "$r" == "htop" ]] && ok "finds layered pkg on booted deployment" || bad "layered" "$r"
r=$(probe_host_layer stale-pkg); [[ -z "$r" ]] && ok "ignores non-booted deployment" || bad "non-booted" "$r"
r=$(probe_host_layer nope); [[ -z "$r" ]] && ok "absent pkg → empty" || bad "absent pkg" "$r"
unset -f rpm-ostree

echo "== cmd_remove arg handling =="
out=$(cmd_remove 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "no args → nonzero exit" || bad "no args rc" "$rc"
grep -qi usage <<<"$out" && ok "no args prints usage" || bad "usage" "$out"

echo "== dry-run: reports but never removes (all probes stubbed) =="
flatpak() { printf 'org.example.Thing\n'; }
brew() { case "$1" in list) echo thing ;; esac; }
podman() { return 1; }        # no sandbox container
rpm-ostree() { echo '{}'; }
remove_flatpak() { echo "REMOVED-FLATPAK"; }   # would fail the test if called
remove_brew()    { echo "REMOVED-BREW"; }
out=$(cmd_remove --dry thing 2>&1); rc=$?
grep -q "REMOVED" <<<"$out" && bad "dry-run must not remove" "$out" || ok "dry-run removes nothing"
grep -q "flatpak" <<<"$out" && ok "dry-run reports flatpak hit" || bad "report flatpak" "$out"
grep -q "brew" <<<"$out" && ok "dry-run reports brew hit" || bad "report brew" "$out"
[[ $rc -eq 0 ]] && ok "found things → exit 0" || bad "dry rc" "$rc"

echo "== not-found exit code =="
flatpak() { :; }; brew() { :; }
out=$(cmd_remove --dry absent-thing 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "nothing found → nonzero exit" || bad "notfound rc" "$rc"
grep -q "containers list" <<<"$out" && ok "hints at other containers" || bad "hint" "$out"
unset -f flatpak brew podman rpm-ostree remove_flatpak remove_brew

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
