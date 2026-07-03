#!/bin/bash
# test-config.sh - unit tests for `powos config` pure logic (registry parsing,
# validation, file-backed get, name→function mapping). No sudo/systemd writes —
# setters that mutate the system are I/O and need a VM.

set -uo pipefail

LIB="/usr/lib/powos/config.sh"
[[ -f "$LIB" ]] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/config.sh"
# shellcheck disable=SC1090
source "$LIB"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1 (got: ${2:-})"; FAIL=$((FAIL+1)); }

echo "== registry integrity =="
n=$(cfg_registry | wc -l)
[[ "$n" -ge 7 ]] && ok "registry has $n settings" || bad "registry size" "$n"
while IFS='|' read -r name values applies desc; do
    [[ -n "$name" && -n "$values" && -n "$applies" && -n "$desc" ]] \
        && ok "entry '$name' has all 4 fields" || bad "entry '$name' fields"
    declare -f "$(cfg_fn get "$name")" >/dev/null \
        && ok "get_${name//-/_}() exists" || bad "getter for $name missing"
    if [[ "$values" == "custom" ]]; then
        declare -f "$(cfg_fn validate "$name")" >/dev/null \
            && ok "validate_${name//-/_}() exists" || bad "validator for $name missing"
    fi
done < <(cfg_registry)

echo "== name→function mapping (dashes → underscores) =="
[[ "$(cfg_fn get sync-interval)" == "get_sync_interval" ]] && ok "get fn for dashed name" || bad "cfg_fn get"
[[ "$(cfg_fn set auto-update)" == "set_auto_update" ]] && ok "set fn for dashed name" || bad "cfg_fn set"

echo "== validators =="
validate_ramsize "8G"  && ok "ramsize accepts 8G"  || bad "ramsize 8G"
validate_ramsize "24g" && ok "ramsize accepts 24g" || bad "ramsize 24g"
validate_ramsize "banana" && bad "ramsize should reject banana" || ok "ramsize rejects banana"
validate_ramsize "8"      && bad "ramsize should reject bare number" || ok "ramsize rejects bare 8"
validate_sync_interval "60" && ok "interval accepts 60" || bad "interval 60"
validate_sync_interval "5"  && bad "interval should reject <10" || ok "interval rejects 5"
validate_sync_interval "abc" && bad "interval should reject abc" || ok "interval rejects abc"

echo "== choice-list rejection via cmd_config =="
out=$(cmd_config driver bogus 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "driver bogus → nonzero exit" || bad "driver bogus rc" "$rc"
grep -q "stable,testing" <<<"$out" && ok "error names the valid choices" || bad "choice list in error" "$out"
out=$(cmd_config nosuchsetting 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "unknown setting → nonzero exit" || bad "unknown rc" "$rc"

echo "== file-backed get (isolated conf file) =="
tmp="$(mktemp -d)"
POWOS_CONF="$tmp/config"
printf 'POWOS_SYNC_INTERVAL=45\nPOWOS_CACHEFS_ENABLED=true\n' > "$POWOS_CONF"
[[ "$(cfg_file_get POWOS_SYNC_INTERVAL)" == "45" ]] && ok "reads value" || bad "file get"
[[ "$(get_sync_interval)" == "45" ]] && ok "sync-interval getter honors file" || bad "interval getter"
[[ "$(get_cachefs)" == "on" ]] && ok "cachefs true → on" || bad "cachefs on"
printf 'POWOS_SYNC_INTERVAL=45\nPOWOS_SYNC_INTERVAL=90\n' > "$POWOS_CONF"
[[ "$(cfg_file_get POWOS_SYNC_INTERVAL)" == "90" ]] && ok "last assignment wins" || bad "last wins"
POWOS_CONF="$tmp/absent"
[[ -z "$(cfg_file_get POWOS_SYNC_INTERVAL)" ]] && ok "absent file → empty" || bad "absent file"
[[ "$(get_sync_interval)" == "60" ]] && ok "default 60 when unset" || bad "default"
rm -rf "$tmp"

echo "== --json is machine-readable =="
if command -v python3 >/dev/null; then
    cfg_list --json | python3 -m json.tool >/dev/null 2>&1 && ok "valid JSON" || bad "json parse"
fi

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
